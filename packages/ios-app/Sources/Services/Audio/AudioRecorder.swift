import Foundation
import AVFoundation

// MARK: - Audio Recorder

@Observable
@MainActor
final class AudioRecorder: NSObject, AVAudioRecorderDelegate {
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

    private var recorder: AVAudioRecorder?
    private var currentURL: URL?
    private var autoStopTask: Task<Void, Never>?
    /// Whether audio session has been pre-warmed
    private var isSessionPrewarmed = false

    // MARK: - Pre-warming (Performance Optimization)

    /// Pre-warm the audio session for faster mic response on first tap.
    /// Call this when ChatView appears to eliminate first-tap latency.
    /// This configures the audio session without activating it,
    /// so the actual recording start is nearly instant.
    func prewarmAudioSession() {
        guard !isSessionPrewarmed else { return }

        Task.detached(priority: .utility) {
            let session = AVAudioSession.sharedInstance()
            do {
                // Configure the category but don't activate yet
                // This initializes the audio hardware in the background
                try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothA2DP])
                await MainActor.run {
                    self.isSessionPrewarmed = true
                }
            } catch {
                // Silently fail - will retry on actual recording start
            }
        }
    }

    func requestPermission() async -> Bool {
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
    }

    func startRecording(maxDuration: TimeInterval) async throws {
        if isRecording {
            return
        }
        let hasPermission = await requestPermission()
        guard hasPermission else {
            throw RecorderError.permissionDenied
        }

        // Prevent AudioAvailabilityMonitor from interfering with our recording
        AudioAvailabilityMonitor.shared.isRecordingInProgress = true

        let session = AVAudioSession.sharedInstance()
        do {
            do {
                try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothA2DP])
            } catch {
                // Fallback for environments that reject playAndRecord (e.g. simulator)
                try session.setCategory(.record, mode: .default, options: [])
            }
            try session.setActive(true, options: [])
        } catch {
            AudioAvailabilityMonitor.shared.isRecordingInProgress = false
            throw RecorderError.startFailed("Failed to configure audio session: \(error.localizedDescription)")
        }
        if !session.isInputAvailable {
            AudioAvailabilityMonitor.shared.isRecordingInProgress = false
            throw RecorderError.startFailed("No audio input available")
        }
        if let inputs = session.availableInputs, let builtIn = inputs.first(where: { $0.portType == .builtInMic }) {
            try? session.setPreferredInput(builtIn)
        }

        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tron-recording-\(UUID().uuidString)")
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
            recorder.isMeteringEnabled = false
            if !recorder.prepareToRecord() {
                AudioAvailabilityMonitor.shared.isRecordingInProgress = false
                throw RecorderError.startFailed("Failed to prepare recorder")
            }
            guard recorder.record() else {
                AudioAvailabilityMonitor.shared.isRecordingInProgress = false
                throw RecorderError.startFailed("Recorder refused to start")
            }
            self.recorder = recorder
            self.currentURL = fileURL
            isRecording = true
            autoStopTask?.cancel()
            autoStopTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(maxDuration))
                await MainActor.run {
                    self?.stopRecording()
                }
            }
        } catch let error as RecorderError {
            AudioAvailabilityMonitor.shared.isRecordingInProgress = false
            throw error
        } catch {
            AudioAvailabilityMonitor.shared.isRecordingInProgress = false
            throw RecorderError.startFailed("Failed to start recording: \(error.localizedDescription)")
        }
    }

    func stopRecording() {
        autoStopTask?.cancel()
        autoStopTask = nil
        recorder?.stop()
    }

    func cancelRecording() {
        autoStopTask?.cancel()
        autoStopTask = nil
        AudioAvailabilityMonitor.shared.isRecordingInProgress = false
        recorder?.stop()
        cleanupFile()
    }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            self?.handleRecorderFinished(success: flag)
        }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor [weak self] in
            self?.handleRecorderError()
        }
    }

    private func handleRecorderFinished(success: Bool) {
        autoStopTask?.cancel()
        autoStopTask = nil
        isRecording = false
        AudioAvailabilityMonitor.shared.isRecordingInProgress = false
        defer {
            recorder = nil
        }

        do {
            try AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        } catch {
            // Ignore deactivation errors
        }

        if !success {
            cleanupFile()
        }

        let finishedURL = success ? currentURL : nil
        onFinish?(finishedURL, success)
        currentURL = nil
    }

    private func handleRecorderError() {
        autoStopTask?.cancel()
        autoStopTask = nil
        isRecording = false
        AudioAvailabilityMonitor.shared.isRecordingInProgress = false
        defer {
            recorder = nil
        }

        do {
            try AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        } catch {
            // Ignore deactivation errors
        }

        cleanupFile()
        onFinish?(nil, false)
    }

    private func cleanupFile() {
        if let url = currentURL {
            try? FileManager.default.removeItem(at: url)
        }
        currentURL = nil
    }
}
