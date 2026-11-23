import AVFoundation
import Foundation
import Speech

/// Listens and turns speech into text, on the device when it can. Stops by itself after a pause.
@MainActor
final class VoiceInput: ObservableObject {
    enum State: Equatable { case idle, listening, denied(String) }

    @Published private(set) var state: State = .idle
    @Published private(set) var transcript = ""
    @Published private(set) var level: Float = 0          // 0...1, for the orb

    var onFinished: ((String) -> Void)?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-CA")) ?? SFSpeechRecognizer()
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var silence: Task<Void, Never>?
    private let pause: Duration = .milliseconds(1500)

    static func requestPermissions() async -> String? {
        let speech = await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) } }
        guard speech == .authorized else { return "Allow Speech Recognition for Katrina PA in Settings > Privacy & Security." }
        #if os(iOS)
        let mic = await AVAudioApplication.requestRecordPermission()
        #else
        let mic = await AVCaptureDevice.requestAccess(for: .audio)
        #endif
        return mic ? nil : "Allow the microphone for Katrina PA in Settings > Privacy & Security."
    }

    func start() async {
        guard state != .listening else { return }
        if let problem = await Self.requestPermissions() { state = .denied(problem); return }
        guard let recognizer, recognizer.isAvailable else { state = .denied("Speech recognition isn't available right now."); return }
        transcript = ""
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth, .duckOthers])
        try? session.setActive(true, options: .notifyOthersOnDeactivation)
        #endif
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }   // audio stays on the phone
        req.addsPunctuation = true
        request = req
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            req.append(buffer)
            let rms = VoiceInput.rms(buffer)
            Task { @MainActor in self?.level = rms }
        }
        engine.prepare()
        do { try engine.start() } catch { state = .denied("Couldn't start the microphone: \(error.localizedDescription)"); return }
        state = .listening
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let final = result?.isFinal ?? false
            Task { @MainActor in
                guard let self else { return }
                if let text { self.transcript = text; self.armSilence() }
                if final || (error != nil && !self.transcript.isEmpty) { self.finish() }
                else if error != nil { self.stop() }
            }
        }
    }

    /// Finish after a pause in speech.
    private func armSilence() {
        silence?.cancel()
        silence = Task { [weak self, pause] in
            try? await Task.sleep(for: pause)
            guard !Task.isCancelled else { return }
            self?.finish()
        }
    }

    func finish() {
        guard state == .listening else { return }
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        stop()
        if !text.isEmpty { onFinished?(text) }
    }

    func stop() {
        silence?.cancel()
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        level = 0
        if state == .listening { state = .idle }
    }

    private nonisolated static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) { sum += data[i] * data[i] }
        let value = sqrt(sum / Float(buffer.frameLength))
        return min(1, value * 12)
    }
}

/// Speaks Katrina's replies in the best English voice installed on the device.
@MainActor
final class VoiceOutput: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    static let shared = VoiceOutput()

    @Published private(set) var speaking = false
    private let synth = AVSpeechSynthesizer()
    private var done: (() -> Void)?

    override init() {
        super.init()
        synth.delegate = self
    }

    /// Premium > enhanced > default, Canadian or US English first.
    static var bestVoice: AVSpeechSynthesisVoice? {
        let preferred = UserDefaults.standard.string(forKey: "voice.id")
        if let id = preferred, let v = AVSpeechSynthesisVoice(identifier: id) { return v }
        let english = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("en") }
        func rank(_ v: AVSpeechSynthesisVoice) -> Int {
            let q = v.quality == .premium ? 300 : v.quality == .enhanced ? 200 : 100
            let lang = v.language == "en-CA" ? 30 : v.language == "en-US" ? 20 : v.language == "en-GB" ? 10 : 0
            return q + lang
        }
        return english.max { rank($0) < rank($1) } ?? AVSpeechSynthesisVoice(language: "en-US")
    }

    func speak(_ text: String, then: (() -> Void)? = nil) {
        stop()
        let clean = Self.speakable(text)
        guard !clean.isEmpty else { then?(); return }
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth, .duckOthers])
        try? session.setActive(true)
        #endif
        let u = AVSpeechUtterance(string: clean)
        u.voice = Self.bestVoice
        u.rate = AVSpeechUtteranceDefaultSpeechRate * 1.05
        u.pitchMultiplier = 1.0
        u.postUtteranceDelay = 0.1
        done = then
        speaking = true
        synth.speak(u)
    }

    func stop() {
        done = nil
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        speaking = false
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        Task { @MainActor in
            self.speaking = false
            let next = self.done
            self.done = nil
            next?()
        }
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) {
        Task { @MainActor in self.speaking = false }
    }

    /// Markdown and symbols read badly aloud: strip them.
    static func speakable(_ text: String) -> String {
        var t = text
        for (pattern, with) in [(#"\*\*|__|`|#+\s"#, ""), (#"^\s*[-•*]\s+"#, ""), (#"https?://\S+"#, "the link"), (#"\s+"#, " ")] {
            t = t.replacingOccurrences(of: pattern, with: with, options: [.regularExpression])
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
