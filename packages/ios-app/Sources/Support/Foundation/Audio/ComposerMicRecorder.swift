import Foundation

/// Bounded composer recording lifecycle around the native capture actuator.
@Observable
@MainActor
final class ComposerMicRecorder {
    private static let maxRecordingDuration: TimeInterval = 300

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
    private(set) var audioLevel: Double = 0
    var onFinish: ((URL?, Bool) -> Void)?

    private let engine = ComposerMicCaptureEngine()
    private var autoStopTask: Task<Void, Never>?
    private var meteringTask: Task<Void, Never>?
    private var levelSmoother = ComposerAudioLevelSmoother()

    deinit {
        MainActor.assumeIsolated {
            autoStopTask?.cancel()
            meteringTask?.cancel()
            engine.cancel()
        }
    }

    func startRecording() async throws {
        guard !isRecording else { return }
        try Task.checkCancellation()
        let hasPermission = await engine.requestPermission()
        try Task.checkCancellation()
        guard hasPermission else { throw RecorderError.permissionDenied }

        do {
            try await engine.start()
            try Task.checkCancellation()
        } catch is CancellationError {
            isRecording = false
            engine.cancel()
            throw CancellationError()
        } catch {
            if Task.isCancelled {
                isRecording = false
                engine.cancel()
                throw CancellationError()
            }
            throw RecorderError.startFailed(error.localizedDescription)
        }
        isRecording = true
        startMetering()

        autoStopTask?.cancel()
        autoStopTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.maxRecordingDuration))
            guard !Task.isCancelled, let self else { return }
            let (url, success) = await self.stopRecording()
            self.onFinish?(url, success)
        }

        if Task.isCancelled {
            cancelRecording()
            throw CancellationError()
        }
    }

    @discardableResult
    func stopRecording() async -> (url: URL?, success: Bool) {
        autoStopTask?.cancel()
        autoStopTask = nil
        guard isRecording else { return (nil, false) }
        isRecording = false
        stopMetering()
        let url = await engine.stop()
        return (url, url != nil)
    }

    func cancelRecording() {
        autoStopTask?.cancel()
        autoStopTask = nil
        isRecording = false
        stopMetering()
        engine.cancel()
    }

    private func startMetering() {
        stopMetering()
        meteringTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                audioLevel = levelSmoother.update(target: engine.currentLevel)
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    private func stopMetering() {
        meteringTask?.cancel()
        meteringTask = nil
        levelSmoother.reset()
        audioLevel = 0
    }
}

struct ComposerAudioLevelSmoother {
    private(set) var value: Double = 0

    mutating func update(target: Double) -> Double {
        let boundedTarget = min(max(target, 0), 1)
        let response = boundedTarget > value ? 0.58 : 0.20
        value += (boundedTarget - value) * response
        return value
    }

    mutating func reset() {
        value = 0
    }
}
