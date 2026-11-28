import SwiftUI
import AVFoundation
import PhotosUI
import AudioToolbox

extension CameraView {
    // MARK: - Actions

    func cycleOverlayMode() {
        let all = OverlayMode.allCases
        if let idx = all.firstIndex(of: appState.overlayMode) {
            appState.overlayMode = all[(idx + 1) % all.count]
        }
    }

    func cycleAspectGuide() {
        let all = AspectGuideMode.allCases
        if let idx = all.firstIndex(of: appState.aspectGuideMode) {
            appState.aspectGuideMode = all[(idx + 1) % all.count]
        }
    }

    func cycleGridMode() {
        let all = GridMode.allCases
        if let idx = all.firstIndex(of: appState.gridMode) {
            appState.gridMode = all[(idx + 1) % all.count]
        }
    }

    func captureAndSavePhoto() async {
        do {
            let useTopShot = isBurstEnabled || (appState.pinnedPose != nil && !cameraService.isRAWEnabled && !cameraService.isHDRBracketingEnabled)
            if useTopShot {
                let thermal = ProcessInfo.processInfo.thermalState
                let frameCount = (visionService.isPowerSavingActive || thermal == .serious || thermal == .critical) ? 2 : 3
                var burstFrames: [UIImage] = []
                for idx in 0..<frameCount {
                    let frame = try await cameraService.capturePhoto()
                    burstFrames.append(frame)
                    if idx < frameCount - 1 {
                        try? await Task.sleep(for: .milliseconds(140))
                    }
                }
                if let best = await visionService.pickBestShot(from: burstFrames, targetPose: appState.pinnedPose) {
                    let baseBest = appState.autoEnhancePhotos ? PhotoEnhancerService.naturalizeAndSharpen(best) : best
                    let magicBest = isOneTapMagicEnabled
                        ? PhotoEnhancerService.applyOneTapMagic(baseBest, lumaHint: visionService.guidance.lumaScore)
                        : baseBest
                    let finalBest = PhotoEnhancerService.applyLook(selectedLook, to: magicBest)
                    let pinned = appState.pinnedPose
                    let savedID = libraryStore.saveCapturedPhoto(
                        finalBest,
                        isGeneratedReference: false,
                        poseIdea: pinned,
                        zoomFactor: Double(cameraService.zoomFactor),
                        overlayModeRaw: appState.overlayMode.rawValue,
                        rollDegrees: horizonService.rollDegrees
                    )
                    Task {
                        let quality = await visionService.evaluateShotQuality(image: finalBest, targetPose: pinned)
                        libraryStore.updateQualityScore(id: savedID, score: quality.totalScore)
                    }
                    let aesthetic = AestheticScoringService.evaluate(
                        image: finalBest,
                        poseMatchScore: visionService.guidance.poseMatchScore,
                        subjectCenter: visionService.guidance.detectedFaceBox.map { CGPoint(x: $0.midX, y: $0.midY) }
                    )
                    ShootingMetricsStore.shared.recordShot(
                        aestheticScore: aesthetic.overallScore,
                        usedMagic: isOneTapMagicEnabled,
                        poseMatchScore: visionService.guidance.poseMatchScore
                    )
                    if appState.autoSaveToApplePhotos, let latest = libraryStore.items.first {
                        _ = await libraryStore.saveToApplePhotos(latest)
                    }
                    showToast("En İyi An (göz açık & net) kaydedildi")
                }
            } else if cameraService.isHDRBracketingEnabled && !cameraService.isRAWEnabled {
                let hdrImage = try await cameraService.captureBracketedHDR()
                let pinned = appState.pinnedPose
                let savedID = libraryStore.saveCapturedPhoto(
                    hdrImage,
                    isGeneratedReference: false,
                    poseIdea: pinned,
                    zoomFactor: Double(cameraService.zoomFactor),
                    overlayModeRaw: appState.overlayMode.rawValue,
                    rollDegrees: horizonService.rollDegrees
                )
                Task {
                    let quality = await visionService.evaluateShotQuality(image: hdrImage, targetPose: pinned)
                    libraryStore.updateQualityScore(id: savedID, score: quality.totalScore)
                }
                if appState.autoSaveToApplePhotos, let latest = libraryStore.items.first {
                    _ = await libraryStore.saveToApplePhotos(latest)
                }
                showToast("HDR+ (3 Kare) kaydedildi")
            } else {
                let (image, rawDNGData) = try await cameraService.capturePhotoWithRAW(preferRAW: isProMode)
                let developedImage: UIImage
                if let rawDNGData, !cameraService.isAppleProRAWSupported, appState.autoEnhancePhotos,
                   let rawDeveloped = PhotoEnhancerService.developRAW(rawDNGData) {
                    developedImage = rawDeveloped
                } else {
                    let baseImage = appState.autoEnhancePhotos ? PhotoEnhancerService.naturalizeAndSharpen(image) : image
                    let magicImage = isOneTapMagicEnabled
                        ? PhotoEnhancerService.applyOneTapMagic(baseImage, lumaHint: visionService.guidance.lumaScore)
                        : baseImage
                    developedImage = PhotoEnhancerService.applyLook(selectedLook, to: magicImage)
                }
                let pinned = appState.pinnedPose
                let savedID = libraryStore.saveCapturedPhoto(
                    developedImage,
                    isGeneratedReference: false,
                    poseIdea: pinned,
                    zoomFactor: Double(cameraService.zoomFactor),
                    overlayModeRaw: appState.overlayMode.rawValue,
                    rollDegrees: horizonService.rollDegrees
                )
                Task {
                    let quality = await visionService.evaluateShotQuality(image: developedImage, targetPose: pinned)
                    libraryStore.updateQualityScore(id: savedID, score: quality.totalScore)
                }
                let aesthetic = AestheticScoringService.evaluate(
                    image: developedImage,
                    poseMatchScore: visionService.guidance.poseMatchScore,
                    subjectCenter: visionService.guidance.detectedFaceBox.map { CGPoint(x: $0.midX, y: $0.midY) }
                )
                ShootingMetricsStore.shared.recordShot(
                    aestheticScore: aesthetic.overallScore,
                    usedMagic: isOneTapMagicEnabled,
                    poseMatchScore: visionService.guidance.poseMatchScore
                )
                var rawSaved = false
                if let rawDNGData {
                    rawSaved = await libraryStore.saveRAWToApplePhotos(rawDNGData)
                }
                if appState.autoSaveToApplePhotos, let latest = libraryStore.items.first {
                    _ = await libraryStore.saveToApplePhotos(latest)
                }
                let rawLabel = cameraService.isAppleProRAWSupported ? "ProRAW (DNG)" : "16-bit RAW (DNG)"
                let variationHint = cameraService.zoomFactor < 1.5 ? "Şimdi 2x yakın portre dene" : "Alçak açıdan bir kare daha dene"
                showToast(rawSaved ? "\(rawLabel) kaydedildi · \(variationHint)" : "Kaydedildi · \(variationHint)")
            }
        } catch {
            showToast("Çekim başarısız")
        }
    }

    func captureAndGeneratePoses() async {
        _ = shotPackStore.consumeOnePack()
        isGeneratingPoses = true
        defer { isGeneratingPoses = false }

        do {
            let testImage = try await cameraService.capturePhoto()
            libraryStore.saveCapturedPhoto(testImage, isGeneratedReference: false)
            // Extract anonymous skeleton & scene tags on-device so zero pixels or biometric photos leave the phone
            async let extractedTask = visionService.extractPose(from: testImage)
            async let sceneTagsTask = visionService.classifySceneTags(from: testImage)
            let (extracted, sceneTags) = await (extractedTask, sceneTagsTask)
            let poses = try await poseGenerator.generatePosePack(
                from: extracted?.skeleton ?? visionService.guidance.detectedSkeleton,
                sceneTags: sceneTags,
                lighting: visionService.guidance.lighting,
                useCase: appState.preferredUseCase,
                apiKey: appState.geminiAPIKey
            )
            appState.latestGeneratedPoses = poses
            appState.isResultsSheetPresented = true
        } catch {
            showToast("Pozlar üretilemedi")
        }
    }

    func showToast(_ text: String) {
        toastMessage = text
        Task {
            try? await Task.sleep(for: .seconds(2))
            if toastMessage == text { toastMessage = nil }
        }
    }

    func evaluateAutoShutter(with guidance: LiveGuidanceState) {
        guard !isGeneratingPoses, !isVideoMode else { return }

        let poseReady = appState.isAutoShutterEnabled
            && appState.pinnedPose != nil
            && guidance.lighting == .good
            && guidance.framing == .great
            && !guidance.eyesClosed
            && (guidance.poseMatchScore ?? 0) >= appState.poseMatchThreshold

        let smileReady = appState.isSmileShutterEnabled
            && guidance.isGoodSmile
            && !guidance.eyesClosed
            && guidance.framing != .noSubject

        let isReady = poseReady || smileReady
        let cooledDown = (CFAbsoluteTimeGetCurrent() - lastAutoShotTime) >= 5.0

        if isReady && cooledDown && autoShutterTask == nil {
            let haptic = UIImpactFeedbackGenerator(style: .medium)
            haptic.impactOccurred()

            autoShutterTask = Task {
                for count in [3, 2, 1] {
                    guard !Task.isCancelled else { return }
                    autoShutterCountdown = count
                    try? await Task.sleep(for: .seconds(1))
                }
                guard !Task.isCancelled else { return }
                autoShutterCountdown = nil
                autoShutterTask = nil
                lastAutoShotTime = CFAbsoluteTimeGetCurrent()
                await captureAndSavePhoto()
            }
        } else if !isReady, autoShutterTask != nil {
            autoShutterTask?.cancel()
            autoShutterTask = nil
            autoShutterCountdown = nil
        }
    }

    func evaluateMatchHaptic(with guidance: LiveGuidanceState) {
        guard appState.isHapticsEnabled,
              appState.pinnedPose != nil,
              let score = guidance.poseMatchScore else {
            didVibrateForCurrentMatch = false
            return
        }
        if score >= appState.poseMatchThreshold && !didVibrateForCurrentMatch {
            didVibrateForCurrentMatch = true
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            if !appState.isSilentModeEnabled {
                AudioServicesPlaySystemSound(1057)
            }
        } else if score < 75 {
            didVibrateForCurrentMatch = false
        }
    }

    func importInspoPose(from item: PhotosPickerItem) async {
        defer { selectedInspoItem = nil }
        guard let data = try? await item.loadTransferable(type: Data.self),
              let uiImage = UIImage(data: data),
              let extracted = await visionService.extractPose(from: uiImage) else {
            showToast("Fotoğrafta kişi algılanamadı")
            return
        }
        let mask = await visionService.extractPersonSilhouette(from: uiImage)
        if !appState.isPoseSaved(extracted) {
            appState.toggleSavePose(extracted)
        }
        appState.pinPoseAndSwitchToCamera(extracted)
        appState.pinnedGhostMask = mask
        if mask != nil { appState.overlayMode = .ghost }
        showToast("İlham pozu (\(extracted.angleLabel)) sabitlendi!")
    }

    func startManualTimerCapture(seconds: Int) {
        autoShutterTask?.cancel()
        autoShutterTask = Task {
            for remaining in stride(from: seconds, through: 1, by: -1) {
                guard !Task.isCancelled else {
                    LiveActivityManager.shared.end()
                    return
                }
                autoShutterCountdown = remaining
                LiveActivityManager.shared.startOrUpdate(
                    modeTitle: "Zamanlayıcı",
                    detailText: "Çekime hazırlanılıyor…",
                    countdownSeconds: remaining,
                    matchScore: visionService.guidance.poseMatchScore
                )
                if remaining <= 3 && !appState.isSilentModeEnabled {
                    voiceCoach.speak("\(remaining)", fast: appState.voiceCoachFast)
                }
                try? await Task.sleep(for: .seconds(1))
            }
            guard !Task.isCancelled else {
                LiveActivityManager.shared.end()
                return
            }
            autoShutterCountdown = nil
            autoShutterTask = nil
            LiveActivityManager.shared.end()
            await captureAndSavePhoto()
        }
    }

    func toggleIntervalShooting() {
        if let existing = intervalTask {
            existing.cancel()
            intervalTask = nil
            LiveActivityManager.shared.end()
            showToast("Aralıklı çekim durduruldu (\(intervalShotsCount) kare)")
            return
        }
        intervalShotsCount = 0
        let step = intervalSeconds
        showToast("Aralıklı çekim başladı (Her \(step) sn)")
        LiveActivityManager.shared.startOrUpdate(
            modeTitle: "Aralıklı Çekim",
            detailText: "Her \(step) saniyede bir kare",
            shotCount: 0,
            matchScore: visionService.guidance.poseMatchScore
        )
        intervalTask = Task {
            while !Task.isCancelled {
                await captureAndSavePhoto()
                intervalShotsCount += 1
                LiveActivityManager.shared.startOrUpdate(
                    modeTitle: "Aralıklı Çekim",
                    detailText: "Her \(step) saniyede bir kare",
                    shotCount: intervalShotsCount,
                    matchScore: visionService.guidance.poseMatchScore
                )
                try? await Task.sleep(for: .seconds(step))
            }
        }
    }

    func recordVideoClip() async {
        cameraService.lockWhiteBalanceForVideo()
        if visionService.guidance.lighting == .tooDark {
            showToast("Loş ışık — temiz video için 24/30 fps önerilir")
        }
        recordingSeconds = 0
        recordingTimerTask?.cancel()
        recordingTimerTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { break }
                recordingSeconds += 1
            }
        }
        defer {
            recordingTimerTask?.cancel()
            recordingTimerTask = nil
            recordingSeconds = 0
        }
        do {
            let videoURL = try await cameraService.startVideoRecording()
            let saved = await libraryStore.saveVideoToApplePhotos(videoURL)
            showToast(saved ? "Video Fotoğraflar'a kaydedildi" : "Video kaydedilemedi")
        } catch {
            showToast("Video kaydı başarısız")
        }
    }
}
