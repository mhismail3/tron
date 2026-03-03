import Foundation
import AVFoundation

// MARK: - Audio Capture Buffer

/// Thread-safe buffer for accumulating PCM audio from the audio engine's tap callback.
/// Tap callback (audio thread) appends chunks; main actor drains after engine stops.
final class AudioCaptureBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var chunks: [Data] = []

    func append(_ data: Data) {
        lock.withLock { chunks.append(data) }
    }

    func drain() -> Data {
        lock.withLock {
            defer { chunks = [] }
            var combined = Data()
            for chunk in chunks { combined.append(chunk) }
            return combined
        }
    }

    func discard() {
        lock.withLock { chunks = [] }
    }
}

// MARK: - Audio Recorder

private let log = TronLogger.shared

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

    /// Session options shared with AudioAvailabilityMonitor to prevent mismatches.
    nonisolated static let sessionOptions: AVAudioSession.CategoryOptions = [.defaultToSpeaker, .mixWithOthers]

    private var engine: AVAudioEngine?
    private let captureBuffer = AudioCaptureBuffer()
    private var sampleRate: Double = 44_100
    private var autoStopTask: Task<Void, Never>?

    // MARK: - Permission

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

    // MARK: - Recording

    func startRecording(maxDuration: TimeInterval) async throws {
        if isRecording { return }

        guard await requestPermission() else {
            throw RecorderError.permissionDenied
        }

        AudioAvailabilityMonitor.shared.isRecordingInProgress = true

        // Configure audio session
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: Self.sessionOptions)
            try session.setPreferredSampleRate(44_100)
            try session.setActive(true, options: [])
        } catch {
            AudioAvailabilityMonitor.shared.isRecordingInProgress = false
            throw RecorderError.startFailed("Failed to configure audio session: \(error.localizedDescription)")
        }

        sampleRate = session.sampleRate
        log.info("[AudioRecorder] session activated — sampleRate=\(sampleRate)Hz", category: .audio)

        // Set up AVAudioEngine with input tap.
        // Pass nil format to installTap — lets the engine deliver buffers in the hardware's
        // native format without conversion. Passing an explicit format can trigger an
        // Objective-C exception (NSException) if CoreAudio considers it invalid, which
        // Swift's do/catch cannot intercept.
        let audioEngine = AVAudioEngine()
        let inputNode = audioEngine.inputNode
        let hwFormat = inputNode.outputFormat(forBus: 0)

        guard hwFormat.channelCount > 0, hwFormat.sampleRate > 0 else {
            AudioAvailabilityMonitor.shared.isRecordingInProgress = false
            try? session.setActive(false, options: [.notifyOthersOnDeactivation])
            throw RecorderError.startFailed("No audio input available (channels=\(hwFormat.channelCount), rate=\(hwFormat.sampleRate))")
        }

        log.info("[AudioRecorder] input format — channels=\(hwFormat.channelCount), rate=\(hwFormat.sampleRate)Hz", category: .audio)

        // Install tap via nonisolated helper. AVAudioNodeTapBlock is not @Sendable,
        // so a closure created in this @MainActor function inherits @MainActor isolation.
        // The audio thread then fails dispatch_assert_queue(main) when calling the tap.
        // Building the closure in a nonisolated context avoids the inherited isolation.
        Self.installInputTap(on: inputNode, buffer: captureBuffer)

        do {
            try audioEngine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            AudioAvailabilityMonitor.shared.isRecordingInProgress = false
            try? session.setActive(false, options: [.notifyOthersOnDeactivation])
            throw RecorderError.startFailed("Failed to start audio engine: \(error.localizedDescription)")
        }

        engine = audioEngine
        isRecording = true
        log.info("[AudioRecorder] RECORDING STARTED", category: .audio)

        autoStopTask?.cancel()
        autoStopTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(maxDuration))
            guard let self else { return }
            let (url, success) = self.stopRecording()
            self.onFinish?(url, success)
        }
    }

    /// Stop recording and return the WAV file URL.
    /// Does NOT call `onFinish` — the caller is responsible for handling the result.
    /// Auto-stop task calls `onFinish` explicitly for the unattended timeout case.
    @discardableResult
    func stopRecording() -> (url: URL?, success: Bool) {
        autoStopTask?.cancel()
        autoStopTask = nil

        guard isRecording, let audioEngine = engine else { return (nil, false) }
        isRecording = false

        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        engine = nil

        let pcmData = captureBuffer.drain()
        let url = Self.writeWAVFile(pcmData: pcmData, sampleRate: sampleRate)
        let success = url != nil

        if success {
            log.info("[AudioRecorder] RECORDING STOPPED — pcmBytes=\(pcmData.count), sampleRate=\(sampleRate)", category: .audio)
        } else {
            log.warning("[AudioRecorder] recording stopped but WAV write failed — pcmBytes=\(pcmData.count)", category: .audio)
        }

        AudioAvailabilityMonitor.shared.isRecordingInProgress = false
        deactivateSession()

        return (url, success)
    }

    func cancelRecording() {
        autoStopTask?.cancel()
        autoStopTask = nil

        if let audioEngine = engine {
            audioEngine.inputNode.removeTap(onBus: 0)
            audioEngine.stop()
            engine = nil
        }

        isRecording = false
        captureBuffer.discard()
        AudioAvailabilityMonitor.shared.isRecordingInProgress = false
        deactivateSession()
        log.info("[AudioRecorder] recording cancelled", category: .audio)
    }

    // MARK: - WAV File Writing

    /// Write raw Int16 PCM data as a standard WAV file. Returns nil if pcmData is empty.
    static func writeWAVFile(pcmData: Data, sampleRate: Double) -> URL? {
        guard !pcmData.isEmpty else { return nil }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tron-recording-\(UUID().uuidString)")
            .appendingPathExtension("wav")

        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = UInt32(sampleRate) * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        let dataSize = UInt32(pcmData.count)
        let fileSize = 36 + dataSize // RIFF chunk size = total - 8

        var header = Data(capacity: 44)

        // RIFF header
        header.append(contentsOf: [0x52, 0x49, 0x46, 0x46]) // "RIFF"
        header.append(littleEndian: fileSize)
        header.append(contentsOf: [0x57, 0x41, 0x56, 0x45]) // "WAVE"

        // fmt subchunk
        header.append(contentsOf: [0x66, 0x6D, 0x74, 0x20]) // "fmt "
        header.append(littleEndian: UInt32(16))               // subchunk size
        header.append(littleEndian: UInt16(1))                // PCM format
        header.append(littleEndian: channels)
        header.append(littleEndian: UInt32(sampleRate))
        header.append(littleEndian: byteRate)
        header.append(littleEndian: blockAlign)
        header.append(littleEndian: bitsPerSample)

        // data subchunk
        header.append(contentsOf: [0x64, 0x61, 0x74, 0x61]) // "data"
        header.append(littleEndian: dataSize)

        var fileData = header
        fileData.append(pcmData)

        do {
            try fileData.write(to: url)
            return url
        } catch {
            log.error("[AudioRecorder] WAV write failed: \(error.localizedDescription)", category: .audio)
            try? FileManager.default.removeItem(at: url)
            return nil
        }
    }

    // MARK: - Private

    /// Install the input tap in a nonisolated context so the callback closure does NOT
    /// inherit @MainActor isolation. AVAudioNodeTapBlock is not @Sendable, so Swift 6
    /// would otherwise compile the closure with @MainActor isolation — causing
    /// _dispatch_assert_queue_fail when the audio render thread invokes it.
    nonisolated private static func installInputTap(on inputNode: AVAudioInputNode, buffer: AudioCaptureBuffer) {
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { pcmBuffer, _ in
            guard let floatData = pcmBuffer.floatChannelData else { return }
            let frameCount = Int(pcmBuffer.frameLength)
            let channels = Int(pcmBuffer.format.channelCount)
            guard frameCount > 0, channels > 0 else { return }

            var int16Data = Data(count: frameCount * 2)
            int16Data.withUnsafeMutableBytes { rawBuffer in
                let samples = rawBuffer.bindMemory(to: Int16.self)
                for i in 0..<frameCount {
                    var sample: Float
                    if channels > 1 {
                        sample = (floatData[0][i] + floatData[1][i]) * 0.5
                    } else {
                        sample = floatData[0][i]
                    }
                    let clamped = max(-1.0, min(1.0, sample))
                    samples[i] = Int16(clamped * 32767.0)
                }
            }
            buffer.append(int16Data)
        }
    }

    private func deactivateSession() {
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        } catch {
            log.warning("[AudioRecorder] session deactivation failed: \(error.localizedDescription)", category: .audio)
        }
    }
}

// MARK: - Data + Little-Endian Helpers

private extension Data {
    mutating func append(littleEndian value: UInt16) {
        var v = value.littleEndian
        append(Data(bytes: &v, count: 2))
    }

    mutating func append(littleEndian value: UInt32) {
        var v = value.littleEndian
        append(Data(bytes: &v, count: 4))
    }
}
