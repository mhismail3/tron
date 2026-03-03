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

// MARK: - Audio Level Meter

/// Thread-safe audio level meter. Tap callback writes RMS level; main actor reads for UI.
final class AudioLevelMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var level: Float = 0

    func update(_ newLevel: Float) {
        lock.withLock { level = newLevel }
    }

    func read() -> Float {
        lock.withLock { level }
    }

    func reset() {
        lock.withLock { level = 0 }
    }
}

// MARK: - Audio Capture Engine

private let log = TronLogger.shared

/// Single source of truth for AVAudioEngine-based recording.
/// Shared by AudioRecorder (chat transcription) and VoiceNotesRecorder (voice notes).
///
/// Supports pre-warming via `prepare()` to eliminate startup latency. When prepared,
/// the engine is already running with a tap that captures audio into the buffer.
/// Calling `start()` on a prepared engine is instant — no session activation or HAL
/// startup delay, so the first word is never lost.
@MainActor
final class AudioCaptureEngine {
    private(set) var isRunning = false
    private(set) var sampleRate: Double = 44_100

    /// True when the engine is warmed up and capturing (but not yet "recording").
    /// Audio captured during this phase is kept as pre-roll so the first word is preserved.
    private(set) var isPrepared = false

    nonisolated static let sessionOptions: AVAudioSession.CategoryOptions = [.defaultToSpeaker, .mixWithOthers]

    /// Thread-safe audio level (written by tap, read by UI timers).
    var currentAudioLevel: Float { levelMeter.read() }

    private var engine: AVAudioEngine?
    private let captureBuffer = AudioCaptureBuffer()
    private let levelMeter = AudioLevelMeter()

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

    // MARK: - Pre-warming

    /// Pre-warm the audio engine so `start()` is instant.
    /// Activates the audio session, starts the engine, and begins capturing into the buffer.
    /// Audio captured during this phase becomes pre-roll — preserving the first word when
    /// the user taps record.
    func prepare() async throws {
        guard !isPrepared, !isRunning else { return }

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: Self.sessionOptions)
            try session.setPreferredSampleRate(44_100)
            try session.setActive(true, options: [])
        } catch {
            throw AudioCaptureEngineError.startFailed("Failed to configure audio session: \(error.localizedDescription)")
        }

        sampleRate = session.sampleRate
        log.info("[AudioCaptureEngine] prepare — session activated, sampleRate=\(sampleRate)Hz", category: .audio)

        let audioEngine = AVAudioEngine()
        let inputNode = audioEngine.inputNode
        let hwFormat = inputNode.outputFormat(forBus: 0)

        guard hwFormat.channelCount > 0, hwFormat.sampleRate > 0 else {
            try? session.setActive(false, options: [.notifyOthersOnDeactivation])
            throw AudioCaptureEngineError.startFailed("No audio input available (channels=\(hwFormat.channelCount), rate=\(hwFormat.sampleRate))")
        }

        Self.installInputTap(on: inputNode, buffer: captureBuffer, levelMeter: levelMeter)

        do {
            try audioEngine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            try? session.setActive(false, options: [.notifyOthersOnDeactivation])
            throw AudioCaptureEngineError.startFailed("Failed to start audio engine: \(error.localizedDescription)")
        }

        engine = audioEngine
        isPrepared = true
        log.info("[AudioCaptureEngine] PREPARED — engine running, capturing pre-roll", category: .audio)
    }

    // MARK: - Recording

    /// Start recording. If already prepared, this is instant (0ms latency).
    /// If not prepared, performs full startup (session activation + engine start).
    func start() async throws {
        guard !isRunning else { return }

        if isPrepared {
            // Engine already running — just mark as recording. Pre-roll audio in the buffer
            // is kept so the first word is captured even if the user spoke before tapping.
            isRunning = true
            log.info("[AudioCaptureEngine] RECORDING STARTED (pre-warmed, 0ms latency)", category: .audio)
            return
        }

        // Cold start — full session + engine setup
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: Self.sessionOptions)
            try session.setPreferredSampleRate(44_100)
            try session.setActive(true, options: [])
        } catch {
            throw AudioCaptureEngineError.startFailed("Failed to configure audio session: \(error.localizedDescription)")
        }

        sampleRate = session.sampleRate
        log.info("[AudioCaptureEngine] session activated — sampleRate=\(sampleRate)Hz", category: .audio)

        let audioEngine = AVAudioEngine()
        let inputNode = audioEngine.inputNode
        let hwFormat = inputNode.outputFormat(forBus: 0)

        guard hwFormat.channelCount > 0, hwFormat.sampleRate > 0 else {
            try? session.setActive(false, options: [.notifyOthersOnDeactivation])
            throw AudioCaptureEngineError.startFailed("No audio input available (channels=\(hwFormat.channelCount), rate=\(hwFormat.sampleRate))")
        }

        log.info("[AudioCaptureEngine] input format — channels=\(hwFormat.channelCount), rate=\(hwFormat.sampleRate)Hz", category: .audio)

        Self.installInputTap(on: inputNode, buffer: captureBuffer, levelMeter: levelMeter)

        do {
            try audioEngine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            try? session.setActive(false, options: [.notifyOthersOnDeactivation])
            throw AudioCaptureEngineError.startFailed("Failed to start audio engine: \(error.localizedDescription)")
        }

        engine = audioEngine
        isRunning = true
        log.info("[AudioCaptureEngine] RECORDING STARTED (cold start)", category: .audio)
    }

    /// Stop recording and return the WAV file URL. Returns nil if no data captured.
    @discardableResult
    func stop() -> URL? {
        guard isRunning || isPrepared, let audioEngine = engine else { return nil }
        isRunning = false
        isPrepared = false

        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        engine = nil
        levelMeter.reset()

        let pcmData = captureBuffer.drain()
        let url = Self.writeWAVFile(pcmData: pcmData, sampleRate: sampleRate)

        if url != nil {
            log.info("[AudioCaptureEngine] RECORDING STOPPED — pcmBytes=\(pcmData.count), sampleRate=\(sampleRate)", category: .audio)
        } else {
            log.warning("[AudioCaptureEngine] recording stopped but WAV write failed — pcmBytes=\(pcmData.count)", category: .audio)
        }

        deactivateSession()
        return url
    }

    /// Discard buffer and deactivate session without producing a file.
    func cancel() {
        if let audioEngine = engine {
            audioEngine.inputNode.removeTap(onBus: 0)
            audioEngine.stop()
            engine = nil
        }

        isRunning = false
        isPrepared = false
        captureBuffer.discard()
        levelMeter.reset()
        deactivateSession()
        log.info("[AudioCaptureEngine] recording cancelled", category: .audio)
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
        let fileSize = 36 + dataSize

        var header = Data(capacity: 44)

        header.append(contentsOf: [0x52, 0x49, 0x46, 0x46]) // "RIFF"
        header.append(littleEndian: fileSize)
        header.append(contentsOf: [0x57, 0x41, 0x56, 0x45]) // "WAVE"

        header.append(contentsOf: [0x66, 0x6D, 0x74, 0x20]) // "fmt "
        header.append(littleEndian: UInt32(16))
        header.append(littleEndian: UInt16(1))                // PCM format
        header.append(littleEndian: channels)
        header.append(littleEndian: UInt32(sampleRate))
        header.append(littleEndian: byteRate)
        header.append(littleEndian: blockAlign)
        header.append(littleEndian: bitsPerSample)

        header.append(contentsOf: [0x64, 0x61, 0x74, 0x61]) // "data"
        header.append(littleEndian: dataSize)

        var fileData = header
        fileData.append(pcmData)

        do {
            try fileData.write(to: url)
            return url
        } catch {
            log.error("[AudioCaptureEngine] WAV write failed: \(error.localizedDescription)", category: .audio)
            try? FileManager.default.removeItem(at: url)
            return nil
        }
    }

    // MARK: - Private

    /// Install the input tap in a nonisolated context so the callback closure does NOT
    /// inherit @MainActor isolation. AVAudioNodeTapBlock is not @Sendable, so Swift 6
    /// would otherwise compile the closure with @MainActor isolation — causing
    /// _dispatch_assert_queue_fail when the audio render thread invokes it.
    nonisolated private static func installInputTap(
        on inputNode: AVAudioInputNode,
        buffer: AudioCaptureBuffer,
        levelMeter: AudioLevelMeter
    ) {
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { pcmBuffer, _ in
            guard let floatData = pcmBuffer.floatChannelData else { return }
            let frameCount = Int(pcmBuffer.frameLength)
            let channels = Int(pcmBuffer.format.channelCount)
            guard frameCount > 0, channels > 0 else { return }

            // Convert Float32 to Int16 PCM
            var int16Data = Data(count: frameCount * 2)
            var sumSquares: Float = 0
            int16Data.withUnsafeMutableBytes { rawBuffer in
                let samples = rawBuffer.bindMemory(to: Int16.self)
                for i in 0..<frameCount {
                    var sample: Float
                    if channels > 1 {
                        sample = (floatData[0][i] + floatData[1][i]) * 0.5
                    } else {
                        sample = floatData[0][i]
                    }
                    sumSquares += sample * sample
                    let clamped = max(-1.0, min(1.0, sample))
                    samples[i] = Int16(clamped * 32767.0)
                }
            }
            buffer.append(int16Data)

            // Compute RMS and normalize to 0-1 with dB mapping
            let rms = sqrt(sumSquares / Float(frameCount))
            let db = rms > 0 ? 20 * log10(rms) : -160
            let normalized = max(0, min(1, (db + 50) / 50))
            levelMeter.update(normalized)
        }
    }

    private func deactivateSession() {
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        } catch {
            log.warning("[AudioCaptureEngine] session deactivation failed: \(error.localizedDescription)", category: .audio)
        }
    }
}

// MARK: - Error

enum AudioCaptureEngineError: LocalizedError {
    case startFailed(String)

    var errorDescription: String? {
        switch self {
        case .startFailed(let reason): return reason
        }
    }
}

// MARK: - Data + Little-Endian Helpers

extension Data {
    mutating func append(littleEndian value: UInt16) {
        var v = value.littleEndian
        append(Data(bytes: &v, count: 2))
    }

    mutating func append(littleEndian value: UInt32) {
        var v = value.littleEndian
        append(Data(bytes: &v, count: 4))
    }
}
