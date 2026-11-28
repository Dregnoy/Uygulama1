import Vision
import CoreImage
import Metal
import UIKit
import Foundation

/// Runs 100% on-device using Apple Vision and CoreVideo luma analysis
/// to provide zero-latency lighting, framing, and pose-match feedback.
@MainActor
@Observable
final class PoseVisionService {
    var guidance = LiveGuidanceState()
    var focusPeakingImage: UIImage? = nil
    private(set) var currentAnalysisFPS: Double = 0
    var thermalStateLabel: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "Nominal"
        case .fair: return "Ilık"
        case .serious: return "Yüksek"
        case .critical: return "Kritik"
        @unknown default: return "Bilinmiyor"
        }
    }
    var isPowerSavingActive: Bool {
        let lowBattery = UIDevice.current.batteryLevel >= 0 && UIDevice.current.batteryLevel <= 0.20
        return lowBattery || ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    let visionQueue = DispatchQueue(label: "com.superposelabs.vision", qos: .userInitiated)
    private var isProcessing = false
    private var lastProcessedTime: CFAbsoluteTime = 0
    @ObservationIgnored private var smileStreak: Int = 0
    @ObservationIgnored private var analysisTick: Int = 0
    @ObservationIgnored nonisolated static let sharedCIContext: CIContext = {
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device)
        }
        return CIContext()
    }()

    /// Adapts frame analysis rate based on device thermal state, low power mode, and <20% battery.
    private var minimumInterval: CFAbsoluteTime {
        if isPowerSavingActive { return 0.35 }
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return 0.12      // ~8 fps
        case .fair: return 0.22         // ~4.5 fps
        case .serious: return 0.38      // ~2.6 fps
        case .critical: return 0.55     // ~1.8 fps (thermal protection)
        @unknown default: return 0.15
        }
    }

    func analyzeFrame(_ pixelBuffer: CVPixelBuffer, targetPose: PoseIdea?, enableFocusPeaking: Bool = false) {
        let now = CFAbsoluteTimeGetCurrent()
        let effectiveInterval = (targetPose == nil && guidance.framing == .noSubject && !enableFocusPeaking)
            ? max(minimumInterval, 0.25)
            : minimumInterval
        guard !isProcessing, now - lastProcessedTime >= effectiveInterval else { return }

        if !enableFocusPeaking && focusPeakingImage != nil {
            focusPeakingImage = nil
        }

        isProcessing = true
        let delta = now - lastProcessedTime
        if delta > 0 && delta < 5.0 {
            let instantFPS = 1.0 / delta
            currentAnalysisFPS = currentAnalysisFPS == 0 ? instantFPS : (currentAnalysisFPS * 0.7 + instantFPS * 0.3)
        }
        lastProcessedTime = now

        let metrics = Self.estimateLightingMetrics(from: pixelBuffer)
        let lighting = Self.classifyLighting(from: metrics)
        let luma = metrics.average

        let isUpperBodyMode = (targetPose?.category == .cafe || targetPose?.category == .portrait)
        let shouldDetectPose = (targetPose != nil)
        let currentTick = analysisTick
        analysisTick &+= 1
        let thermal = ProcessInfo.processInfo.thermalState
        let thermalStride = (thermal == .critical) ? 4 : ((thermal == .serious) ? 3 : 2)
        let runRect = (currentTick % thermalStride == 0)
        let runFace = (currentTick % thermalStride == 1) || (currentTick == 0)
        let prevGuidance = guidance

        visionQueue.async { [weak self] in
            let rectRequest: VNDetectHumanRectanglesRequest? = runRect ? {
                let r = VNDetectHumanRectanglesRequest()
                r.upperBodyOnly = isUpperBodyMode
                return r
            }() : nil
            let faceRequest: VNDetectFaceLandmarksRequest? = runFace ? VNDetectFaceLandmarksRequest() : nil
            let poseRequest = shouldDetectPose ? VNDetectHumanBodyPoseRequest() : nil

            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
            do {
                var requests: [VNRequest] = []
                if let rectRequest { requests.append(rectRequest) }
                if let faceRequest { requests.append(faceRequest) }
                if let poseRequest { requests.append(poseRequest) }
                if !requests.isEmpty {
                    try handler.perform(requests)
                }
            } catch {
                Task { @MainActor [weak self] in
                    self?.isProcessing = false
                }
                return
            }

            let detectedAll = (poseRequest?.results ?? []).prefix(2).compactMap { Self.extractSkeleton(from: $0) }
            let detectedSkeleton = detectedAll.first
            let detectedSecondary = detectedAll.count > 1 ? detectedAll[1] : nil
            let framing: FramingStatus = {
                if let rectRequest {
                    return Self.evaluateFraming(
                        from: rectRequest.results?.first,
                        skeleton: detectedSkeleton,
                        upperBodyOnly: isUpperBodyMode
                    )
                }
                return prevGuidance.framing
            }()
            let eyesClosed = faceRequest.map { Self.areEyesClosed(in: $0.results) } ?? prevGuidance.eyesClosed
            let rawSmile: Bool? = faceRequest.map { !eyesClosed && Self.isSmiling(in: $0.results) }
            let faceAngleHint = faceRequest.map { Self.faceAngleHint(in: $0.results) } ?? prevGuidance.faceAngleHint
            let leadRoomHint = faceRequest.map { Self.leadRoomHint(in: $0.results) } ?? prevGuidance.leadRoomHint
            let faceBox: CGRect? = faceRequest.map { req in
                req.results?.first.map { obs in
                    let b = obs.boundingBox
                    return CGRect(x: b.minX, y: 1.0 - b.maxY, width: b.width, height: b.height)
                }
            } ?? prevGuidance.detectedFaceBox
            let couplesHint = Self.evaluateCouplesBalance(first: detectedSkeleton, second: detectedSecondary)
            let poleWarning = Self.detectVerticalLineBehindHead(in: pixelBuffer, nose: detectedSkeleton?.joints[.nose])
            let contrastDiff = abs(metrics.average - metrics.edgeAverage)
            let hazeOrFlareWarning = metrics.average > 0.62 && contrastDiff < 0.08
            let subjectContrastHint: String? = (detectedSkeleton != nil && contrastDiff < 0.06)
                ? "Arka plan karışık — Portre Bokeh dene"
                : nil
            let matchScore: Int? = {
                guard let targetPose, let detectedSkeleton else { return nil }
                let primary = Self.computePoseMatchScore(live: detectedSkeleton, target: targetPose.skeleton)
                if let targetSecond = targetPose.secondarySkeleton, let detectedSecondary {
                    let secondary = Self.computePoseMatchScore(live: detectedSecondary, target: targetSecond)
                    return (primary + secondary) / 2
                }
                return primary
            }()

            let peakingCG: CGImage? = enableFocusPeaking ? self?.renderFocusPeakingMask(from: pixelBuffer) : nil

            Task { @MainActor [weak self] in
                guard let self else { return }
                if let rawSmile {
                    self.smileStreak = rawSmile ? (self.smileStreak + 1) : 0
                }
                let isGoodSmile = self.smileStreak >= 3
                self.focusPeakingImage = peakingCG.map { UIImage(cgImage: $0) }
                self.guidance = LiveGuidanceState(
                    lighting: lighting,
                    framing: framing,
                    lumaScore: luma,
                    poseMatchScore: matchScore,
                    eyesClosed: eyesClosed,
                    isGoodSmile: isGoodSmile,
                    backgroundPoleWarning: poleWarning,
                    hazeOrFlareWarning: hazeOrFlareWarning,
                    couplesBalanceHint: couplesHint,
                    faceAngleHint: faceAngleHint,
                    leadRoomHint: leadRoomHint,
                    subjectContrastHint: subjectContrastHint,
                    detectedFaceBox: faceBox,
                    detectedSkeleton: detectedSkeleton,
                    detectedSecondarySkeleton: detectedSecondary
                )
                self.isProcessing = false
            }
        }
    }
}
