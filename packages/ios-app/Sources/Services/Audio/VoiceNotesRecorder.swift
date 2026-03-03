import Foundation
import AVFoundation

/// Recorder for voice notes with audio level metering for visualization.
/// Supports 5-minute max duration with auto-stop.
@Observable
@MainActor
final class VoiceNotesRecorder {
    enum RecorderError: LocalizedError {
        case permissionDenied
        case startFailed(String)

        var errorDescription: String? {
            switch self {
            case .permissionDenied: return "Microphone permission denied"
            case .startFailed(let reason): return reason
            }
        }
    }

    enum State: Equatable {
        case idle
        case recording
        case stopped(URL)
        case saving
    }

    private(set) var state: State = .idle
    private(set) var audioLevel: Float = 0
    private(set) var recordingDuration: TimeInterval = 0

    static let maxDuration: TimeInterval = 300

    private let engine = AudioCaptureEngine()
    private var levelTimer: Timer?
    private var durationTimer: Timer?
    private var autoStopTask: Task<Void, Never>?

    var isRecording: Bool { state == .recording }
    var hasStopped: Bool {
        if case .stopped = state { return true }
        return false
    }

    // MARK: - Pre-warming

    /// Pre-warm the audio engine so recording starts instantly.
    /// Call this when the recording sheet appears.
    func prepare() async {
        guard await engine.requestPermission() else { return }
        try? await engine.prepare()
    }

    // MARK: - Recording Control

    func startRecording() async throws {
        guard state == .idle else { return }

        guard await engine.requestPermission() else {
            throw RecorderError.permissionDenied
        }

        do {
            try await engine.start()
        } catch {
            throw RecorderError.startFailed(error.localizedDescription)
        }

        state = .recording
        recordingDuration = 0
        AudioAvailabilityMonitor.shared.isRecordingInProgress = true

        startTimers()
        scheduleAutoStop()
    }

    func stopRecording() {
        guard isRecording else { return }
        autoStopTask?.cancel()
        stopTimers()

        let url = engine.stop()
        audioLevel = 0
        AudioAvailabilityMonitor.shared.isRecordingInProgress = false

        if let url {
            state = .stopped(url)
        } else {
            state = .idle
        }
    }

    func cancelRecording() {
        autoStopTask?.cancel()
        stopTimers()
        engine.cancel()
        state = .idle
        audioLevel = 0
        recordingDuration = 0
        AudioAvailabilityMonitor.shared.isRecordingInProgress = false
    }

    func reset() {
        cancelRecording()
    }

    func getRecordingURL() -> URL? {
        if case .stopped(let url) = state {
            return url
        }
        return nil
    }

    func markSaving() {
        if case .stopped = state {
            state = .saving
        }
    }

    // MARK: - Timer Management

    private func startTimers() {
        levelTimer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateMeters()
            }
        }
        RunLoop.main.add(levelTimer!, forMode: .common)

        durationTimer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.recordingDuration += 1
            }
        }
        RunLoop.main.add(durationTimer!, forMode: .common)
    }

    private func stopTimers() {
        levelTimer?.invalidate()
        levelTimer = nil
        durationTimer?.invalidate()
        durationTimer = nil
    }

    private func updateMeters() {
        audioLevel = engine.currentAudioLevel
    }

    private func scheduleAutoStop() {
        autoStopTask = Task {
            try? await Task.sleep(for: .seconds(Self.maxDuration))
            guard !Task.isCancelled else { return }
            if self.isRecording {
                self.stopRecording()
            }
        }
    }
}
