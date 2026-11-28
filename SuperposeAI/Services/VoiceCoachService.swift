import AVFoundation

@MainActor
@Observable
final class VoiceCoachService {
    var isSpeaking = false

    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
    @ObservationIgnored private var lastSpokenMessage: String = ""
    @ObservationIgnored private var lastSpokenTime: CFAbsoluteTime = 0
    @ObservationIgnored private let cooldown: CFAbsoluteTime = 4.0

    private var isEnglish: Bool {
        guard let first = Locale.preferredLanguages.first?.lowercased() else { return false }
        return !first.hasPrefix("tr")
    }

    func announceIfNeeded(_ guidance: LiveGuidanceState, isEnabled: Bool, hasPinnedPose: Bool, fast: Bool = false) {
        guard isEnabled else { return }

        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastSpokenTime >= cooldown else { return }

        let message: String? = {
            if guidance.lighting == .tooDark {
                return isEnglish ? "Low light, face a brighter source." : "Işık az, daha aydınlık bir yöne dön."
            }
            if guidance.framing == .noSubject {
                if !hasPinnedPose { return nil }
                return isEnglish ? "Step into the frame, pose ready." : "Kadraja girin, poz bekleniyor."
            }
            if guidance.framing != .great {
                return localizedFraming(guidance.framing)
            }
            if let faceHint = guidance.faceAngleHint {
                return faceHint
            }
            if hasPinnedPose, let score = guidance.poseMatchScore, score >= 85 {
                return isEnglish ? "Great pose, hold still." : "Harika poz, sabit kal."
            }
            return nil
        }()

        guard let message, message != lastSpokenMessage else { return }
        speak(message, fast: fast)
        lastSpokenMessage = message
        lastSpokenTime = now
    }

    func speakCoaching(for pose: PoseIdea) {
        let subjectText = pose.coaching.subjectTips.joined(separator: ". ")
        let photoText = pose.coaching.photographerTips.joined(separator: ". ")
        let fullText = isEnglish
            ? "\(pose.title). For subject: \(subjectText). For photographer: \(photoText)"
            : "\(pose.title). Poz veren için: \(subjectText). Fotoğrafçı için: \(photoText)"
        speak(fullText)
    }

    func speak(_ text: String, fast: Bool = false) {
        configureAudioSessionForSpeech()
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = fast ? 0.56 : 0.50
        let langCode = isEnglish ? "en-US" : "tr-TR"
        utterance.voice = AVSpeechSynthesisVoice(language: langCode) ?? AVSpeechSynthesisVoice()
        synthesizer.speak(utterance)
        isSpeaking = true
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
    }

    private func configureAudioSessionForSpeech() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.mixWithOthers, .duckOthers])
        try? session.setActive(true)
    }

    private func localizedFraming(_ framing: FramingStatus) -> String {
        if isEnglish {
            switch framing {
            case .noSubject: return "Step into frame."
            case .tooClose: return "Step back slightly."
            case .tooFar: return "Step closer."
            case .moveLeft: return "Move slightly left."
            case .moveRight: return "Move slightly right."
            case .tiltDown: return "Leave less headroom."
            case .great: return "Great framing."
            }
        }
        switch framing {
        case .noSubject: return "Kadraja gir."
        case .tooClose: return "Biraz geri çekil."
        case .tooFar: return "Biraz yaklaş."
        case .moveLeft: return "Biraz sola kay."
        case .moveRight: return "Biraz sağa kay."
        case .tiltDown: return "Baş üstünde biraz daha az boşluk bırak."
        case .great: return "Harika kadraj."
        }
    }
}
