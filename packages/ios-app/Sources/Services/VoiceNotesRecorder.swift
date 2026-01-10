import Foundation
import AVFoundation

/// Recorder for voice notes with audio level metering for visualization.
/// Supports 5-minute max duration with auto-stop.
@MainActor
final class VoiceNotesRecorder: NSObject, ObservableObject, AVAudioRecorderDelegate {
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
        case stopped(URL)  // Contains the recorded file URL
        case saving
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var audioLevel: Float = 0  // Normalized 0-1 for visualization
    @Published private(set) var recordingDuration: TimeInterval = 0

    static let maxDuration: TimeInterval = 300  // 5 minutes

    private var recorder: AVAudioRecorder?
    private var currentURL: URL?
    private var levelTimer: Timer?
    private var durationTimer: Timer?
    private var autoStopTask: Task<Void, Never>?

    var isRecording: Bool { state == .recording }
    var hasStopped: Bool {
        if case .stopped = state { return true }
        return false
    }

    // MARK: - Permission

    func requestPermission() async -> Bool {
        if #available(iOS 17.0, *) {
            switch AVAudioApplication.shared.recordPermission {
            case .granted:
                return true
            case .denied:
                return false
            case .undetermined:
                return await withCheckedContinuation { continuation in
                    AVAudioApplication.requestRecordPermission { allowed in
                        DispatchQueue.main.async {
                            continuation.resume(returning: allowed)
                        }
                    }
                }
            @unknown default:
                return false
            }
        } else {
            switch AVAudioSession.sharedInstance().recordPermission {
            case .granted:
                return true
            case .denied:
                return false
            case .undetermined:
                return await withCheckedContinuation { continuation in
                    AVAudioSession.sharedInstance().requestRecordPermission { allowed in
                        DispatchQueue.main.async {
                            continuation.resume(returning: allowed)
                        }
                    }
                }
            @unknown default:
                return false
            }
        }
    }

    // MARK: - Recording Control

    func startRecording() async throws {
        guard state == .idle else { return }

        let hasPermission = await requestPermission()
        guard hasPermission else { throw RecorderError.permissionDenied }

        // Configure audio session
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try session.setActive(true)
        } catch {
            throw RecorderError.startFailed("Failed to configure audio: \(error.localizedDescription)")
        }

        // Create temp file
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-note-\(UUID().uuidString)")
            .appendingPathExtension("m4a")

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]

        do {
            let recorder = try AVAudioRecorder(url: fileURL, settings: settings)
            recorder.delegate = self
            recorder.isMeteringEnabled = true  // Enable for level visualization

            guard recorder.prepareToRecord(), recorder.record() else {
                throw RecorderError.startFailed("Failed to start recording")
            }

            self.recorder = recorder
            self.currentURL = fileURL
            self.state = .recording
            self.recordingDuration = 0

            startTimers()
            scheduleAutoStop()
        } catch let error as RecorderError {
            throw error
        } catch {
            throw RecorderError.startFailed(error.localizedDescription)
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        autoStopTask?.cancel()
        stopTimers()
        recorder?.stop()
        // State transition handled in delegate
    }

    func cancelRecording() {
        autoStopTask?.cancel()
        stopTimers()
        recorder?.stop()
        cleanupFile()
        state = .idle
        audioLevel = 0
        recordingDuration = 0
    }

    func reset() {
        cancelRecording()
    }

    /// Get the recorded file URL (only valid when state == .stopped)
    func getRecordingURL() -> URL? {
        if case .stopped(let url) = state {
            return url
        }
        return nil
    }

    /// Mark as saving (for UI state tracking)
    func markSaving() {
        if case .stopped = state {
            state = .saving
        }
    }

    // MARK: - Timer Management

    private func startTimers() {
        // Level meter update at 10Hz for smooth visualization
        levelTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateMeters()
            }
        }

        // Duration update at 1Hz
        durationTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.recordingDuration += 1
            }
        }
    }

    private func stopTimers() {
        levelTimer?.invalidate()
        levelTimer = nil
        durationTimer?.invalidate()
        durationTimer = nil
    }

    private func updateMeters() {
        recorder?.updateMeters()
        let power = recorder?.averagePower(forChannel: 0) ?? -160
        // Normalize from dB (-50 to 0 range) to 0-1
        audioLevel = max(0, min(1, (power + 50) / 50))
    }

    private func scheduleAutoStop() {
        autoStopTask = Task {
            try? await Task.sleep(for: .seconds(Self.maxDuration))
            await MainActor.run {
                if self.isRecording {
                    self.stopRecording()
                }
            }
        }
    }

    // MARK: - AVAudioRecorderDelegate

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor in
            self.handleRecorderFinished(success: flag)
        }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor in
            self.handleRecorderError()
        }
    }

    private func handleRecorderFinished(success: Bool) {
        stopTimers()
        audioLevel = 0

        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])

        if success, let url = currentURL {
            state = .stopped(url)
        } else {
            cleanupFile()
            state = .idle
        }

        recorder = nil
    }

    private func handleRecorderError() {
        stopTimers()
        audioLevel = 0
        cleanupFile()
        state = .idle
        recorder = nil

        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    private func cleanupFile() {
        if let url = currentURL {
            try? FileManager.default.removeItem(at: url)
        }
        currentURL = nil
    }
}
