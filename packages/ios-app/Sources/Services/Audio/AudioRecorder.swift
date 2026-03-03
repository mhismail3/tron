import Foundation
import AVFoundation

// MARK: - Audio Recorder

@Observable
@MainActor
final class AudioRecorder {
    enum RecorderError: LocalizedError {
        case permissionDenied
        case startFailed(String)

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                return "Microphone permission denied"
            case .startFailed(let reason):
                return reason
            }
        }
    }

    private(set) var isRecording = false

    var onFinish: ((URL?, Bool) -> Void)?

    nonisolated static var sessionOptions: AVAudioSession.CategoryOptions { AudioCaptureEngine.sessionOptions }

    private let engine = AudioCaptureEngine()
    private var autoStopTask: Task<Void, Never>?

    // MARK: - Permission

    func requestPermission() async -> Bool {
        await engine.requestPermission()
    }

    // MARK: - Pre-warming

    /// Pre-warm the audio engine so recording starts instantly.
    /// Only call when recording is imminent (e.g. voice notes sheet onAppear).
    func prepare() async {
        guard await requestPermission() else { return }
        try? await engine.prepare()
    }

    // MARK: - Recording

    func startRecording(maxDuration: TimeInterval) async throws {
        if isRecording { return }

        guard await requestPermission() else {
            throw RecorderError.permissionDenied
        }

        AudioAvailabilityMonitor.shared.isRecordingInProgress = true

        do {
            try await engine.start()
        } catch {
            AudioAvailabilityMonitor.shared.isRecordingInProgress = false
            throw RecorderError.startFailed(error.localizedDescription)
        }

        isRecording = true

        autoStopTask?.cancel()
        autoStopTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(maxDuration))
            guard !Task.isCancelled, let self else { return }
            let (url, success) = self.stopRecording()
            self.onFinish?(url, success)
        }
    }

    @discardableResult
    func stopRecording() -> (url: URL?, success: Bool) {
        autoStopTask?.cancel()
        autoStopTask = nil

        guard isRecording else { return (nil, false) }
        isRecording = false

        let url = engine.stop()
        AudioAvailabilityMonitor.shared.isRecordingInProgress = false

        return (url, url != nil)
    }

    func cancelRecording() {
        autoStopTask?.cancel()
        autoStopTask = nil

        isRecording = false
        engine.cancel()
        AudioAvailabilityMonitor.shared.isRecordingInProgress = false
    }
}
