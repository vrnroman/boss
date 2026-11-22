import AVFoundation
import Speech
import BossCore

/// On-device partial transcripts (en-US and ru-RU) while recording, for the "→ target" chip.
/// Skipped silently when on-device recognition is unavailable or not authorised.
@MainActor
final class LivePreview {
    private var recognizers: [SFSpeechRecognizer] = []
    private var requests: [SFSpeechAudioBufferRecognitionRequest] = []
    private var tasks: [SFSpeechRecognitionTask] = []
    var onPartial: ((String) -> Void)?
    private(set) var available = false

    init() {
        recognizers = ["en-US", "ru-RU"].compactMap { SFSpeechRecognizer(locale: Locale(identifier: $0)) }
            .filter { $0.supportsOnDeviceRecognition }
        available = !recognizers.isEmpty
    }

    func ensureAuthorization() {
        if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            SFSpeechRecognizer.requestAuthorization { _ in }
        }
    }

    /// Returns a buffer sink for the audio pipe, or nil if preview is off/unavailable.
    func begin() -> (@Sendable (AVAudioPCMBuffer) -> Void)? {
        stop()
        guard available, SFSpeechRecognizer.authorizationStatus() == .authorized else { return nil }
        for r in recognizers where r.isAvailable {
            let req = SFSpeechAudioBufferRecognitionRequest()
            req.requiresOnDeviceRecognition = true
            req.shouldReportPartialResults = true
            let task = r.recognitionTask(with: req) { [weak self] result, _ in
                guard let text = result?.bestTranscription.formattedString, !text.isEmpty else { return }
                Task { @MainActor in self?.onPartial?(text) }
            }
            requests.append(req)
            tasks.append(task)
        }
        let reqs = requests
        return { buf in for r in reqs { r.append(buf) } }
    }

    func stop() {
        for r in requests { r.endAudio() }
        for t in tasks { t.cancel() }
        requests = []; tasks = []
    }
}
