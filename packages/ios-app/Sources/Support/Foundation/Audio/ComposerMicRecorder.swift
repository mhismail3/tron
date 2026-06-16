import Foundation

@Observable
@MainActor
final class ComposerMicRecorder {
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

    private let engine = ComposerMicCaptureEngine()
    private var autoStopTask: Task<Void, Never>?

    func startRecording(maxDuration: TimeInterval) async throws {
        guard !isRecording else { return }
        guard await engine.requestPermission() else {
            throw RecorderError.permissionDenied
        }

        MicAvailabilityMonitor.shared.isRecordingInProgress = true
        do {
            try await engine.start()
        } catch {
            MicAvailabilityMonitor.shared.isRecordingInProgress = false
            throw RecorderError.startFailed(error.localizedDescription)
        }
        isRecording = true

        autoStopTask?.cancel()
        autoStopTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(maxDuration))
            guard !Task.isCancelled, let self else { return }
            await MainActor.run {
                let (url, success) = self.stopRecording()
                self.onFinish?(url, success)
            }
        }
    }

    @discardableResult
    func stopRecording() -> (url: URL?, success: Bool) {
        autoStopTask?.cancel()
        autoStopTask = nil
        guard isRecording else { return (nil, false) }
        isRecording = false
        let url = engine.stop()
        MicAvailabilityMonitor.shared.isRecordingInProgress = false
        return (url, url != nil)
    }

    func cancelRecording() {
        autoStopTask?.cancel()
        autoStopTask = nil
        isRecording = false
        engine.cancel()
        MicAvailabilityMonitor.shared.isRecordingInProgress = false
    }
}
