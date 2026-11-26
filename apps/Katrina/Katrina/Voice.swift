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

    private let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-CA"))
        ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var silence: Task<Void, Never>?
    private let pause: Duration = .milliseconds(1600)
    private var onDeviceOK = true

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
        guard let recognizer else { state = .denied("Speech recognition isn't available for your language on this device."); return }
        guard recognizer.isAvailable else {
            state = .denied("Speech recognition is unavailable right now. Check that Dictation is on: Settings > General > Keyboard > Enable Dictation.")
            return
        }
        transcript = ""
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetooth, .duckOthers])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            state = .denied("The microphone is busy (a call or another app?). Try again.")
            return
        }
        #endif
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.taskHint = .dictation
        req.addsPunctuation = true
        // On-device when this phone has the offline model; otherwise Apple's server. Forcing on-device when the
        // model isn't downloaded is what made the mic silently do nothing before.
        req.requiresOnDeviceRecognition = onDeviceOK && recognizer.supportsOnDeviceRecognition
        request = req
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            stop()
            state = .denied("No microphone input is available.")
            return
        }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            req.append(buffer)
            let rms = VoiceInput.rms(buffer)
            Task { @MainActor in self?.level = rms }
        }
        engine.prepare()
        do { try engine.start() } catch { stop(); state = .denied("Couldn't start the microphone: \(error.localizedDescription)"); return }
        state = .listening
        armSilence(first: true)
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let final = result?.isFinal ?? false
            let failure = error.map { ($0 as NSError).code }
            Task { @MainActor in
                guard let self, self.state == .listening, self.request === req else { return }   // ignore a late callback from an earlier try
                if let text, !text.isEmpty { self.transcript = text; self.armSilence() }
                if final { self.finish(); return }
                guard let failure else { return }
                if !self.transcript.isEmpty { self.finish(); return }
                self.stop()
                if self.onDeviceOK && req.requiresOnDeviceRecognition {
                    self.onDeviceOK = false                     // offline model missing: retry once on the server
                    await self.start()
                } else if failure == 1110 || failure == 203 {   // no speech heard
                    self.state = .denied("I didn't hear anything. Tap the mic and speak.")
                } else {
                    self.state = .denied("Dictation didn't work (code \(failure)). Check Settings > General > Keyboard > Enable Dictation, then try again.")
                }
            }
        }
    }

    /// Finish after a pause in speech; give up after 8 seconds if nothing was said at all.
    private func armSilence(first: Bool = false) {
        silence?.cancel()
        let wait: Duration = first ? .seconds(8) : pause
        silence = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled, let self else { return }
            if self.transcript.isEmpty { self.stop(); self.state = .denied("I didn't hear anything. Tap the mic and speak.") }
            else { self.finish() }
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
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    /// Clear a previous error so the mic can be tried again.
    func reset() { if case .denied = state { state = .idle } }

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
        Self.releaseAudio()
    }

    private static func releaseAudio() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        Task { @MainActor in
            self.speaking = false
            let next = self.done
            self.done = nil
            Self.releaseAudio()          // let music and podcasts come back up; listening reactivates it
            next?()
        }
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) {
        Task { @MainActor in if !self.synth.isSpeaking { self.speaking = false } }
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
