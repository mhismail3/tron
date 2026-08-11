import Foundation
@preconcurrency import AVFoundation

final class ComposerMicCaptureBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var chunks: [Data] = []
    private var normalizedLevel: Double = 0

    func append(_ data: Data, normalizedLevel: Double) {
        lock.withLock {
            chunks.append(data)
            self.normalizedLevel = normalizedLevel
        }
    }

    func currentLevel() -> Double {
        lock.withLock { normalizedLevel }
    }

    func drainChunks() -> [Data] {
        lock.withLock {
            defer {
                chunks = []
                normalizedLevel = 0
            }
            return chunks
        }
    }

    func discard() {
        lock.withLock {
            chunks = []
            normalizedLevel = 0
        }
    }
}

/// Native microphone actuator for the prompt composer.
///
/// It owns permission, a bounded mono PCM capture, metering, and WAV encoding.
/// It deliberately owns no model, transcription, cleanup, or routing policy.
@MainActor
final class ComposerMicCaptureEngine {
    nonisolated static let transcriptionSampleRate: Double = 16_000
    private(set) var isRunning = false
    private(set) var sampleRate: Double = transcriptionSampleRate

    nonisolated static let sessionOptions: AVAudioSession.CategoryOptions = [
        .defaultToSpeaker,
        .mixWithOthers,
    ]

    private var engine: AVAudioEngine?
    /// True only after this instance successfully activates the shared audio
    /// session. A never-started recorder must not deactivate process-global
    /// audio during ordinary chat teardown.
    private var ownsActiveAudioSession = false
    private let captureBuffer = ComposerMicCaptureBuffer()
    private var simulatorRecordingStartedAt: Date?

    var currentLevel: Double {
        captureBuffer.currentLevel()
    }

    nonisolated static var usesSimulatorSafeCaptureBackend: Bool {
        #if targetEnvironment(simulator)
        true
        #else
        false
        #endif
    }

    func requestPermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return true
        case .denied:
            return false
        case .undetermined:
            return await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        @unknown default:
            return false
        }
    }

    func start() async throws {
        guard !isRunning else { return }

        if Self.usesSimulatorSafeCaptureBackend {
            sampleRate = Self.transcriptionSampleRate
            captureBuffer.discard()
            isRunning = true
            simulatorRecordingStartedAt = Date()
            return
        }

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: Self.sessionOptions)
            try session.setPreferredSampleRate(Self.transcriptionSampleRate)
            try session.setActive(true, options: [])
            ownsActiveAudioSession = true
        } catch {
            throw ComposerMicCaptureError.startFailed(
                "Failed to configure audio session: \(error.localizedDescription)"
            )
        }

        let audioEngine = AVAudioEngine()
        let inputNode = audioEngine.inputNode
        let hardwareFormat = inputNode.outputFormat(forBus: 0)
        guard hardwareFormat.channelCount > 0, hardwareFormat.sampleRate > 0 else {
            try? session.setActive(false, options: [.notifyOthersOnDeactivation])
            ownsActiveAudioSession = false
            throw ComposerMicCaptureError.startFailed("No audio input available")
        }
        // The preferred session rate is advisory. The nil-format input tap
        // receives the node's actual hardware format, so the WAV header and
        // post-capture resampler must use that exact rate.
        sampleRate = hardwareFormat.sampleRate

        Self.installInputTap(on: inputNode, buffer: captureBuffer)
        do {
            try audioEngine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            try? session.setActive(false, options: [.notifyOthersOnDeactivation])
            ownsActiveAudioSession = false
            throw ComposerMicCaptureError.startFailed(
                "Failed to start audio engine: \(error.localizedDescription)"
            )
        }

        engine = audioEngine
        isRunning = true
    }

    @discardableResult
    func stop() async -> URL? {
        if Self.usesSimulatorSafeCaptureBackend {
            guard isRunning else { return nil }
            isRunning = false
            let startedAt = simulatorRecordingStartedAt
            simulatorRecordingStartedAt = nil
            let pcmData = Self.simulatorSilentPCMData(
                sampleRate: sampleRate,
                elapsed: startedAt.map { Date().timeIntervalSince($0) } ?? 0.25
            )
            return await Self.finalizeWAVFile(
                chunks: [pcmData],
                inputSampleRate: sampleRate
            )
        }

        guard isRunning, let audioEngine = engine else { return nil }
        isRunning = false
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        engine = nil

        let chunks = captureBuffer.drainChunks()
        let inputSampleRate = sampleRate
        deactivateSession()
        return await Self.finalizeWAVFile(
            chunks: chunks,
            inputSampleRate: inputSampleRate
        )
    }

    func cancel() {
        if let audioEngine = engine {
            audioEngine.inputNode.removeTap(onBus: 0)
            audioEngine.stop()
            engine = nil
        }
        isRunning = false
        simulatorRecordingStartedAt = nil
        captureBuffer.discard()
        deactivateSession()
    }

    private nonisolated static func installInputTap(
        on inputNode: AVAudioInputNode,
        buffer: ComposerMicCaptureBuffer
    ) {
        inputNode.installTap(onBus: 0, bufferSize: 4_096, format: nil) { pcmBuffer, _ in
            guard let floatData = pcmBuffer.floatChannelData else { return }
            let frameCount = Int(pcmBuffer.frameLength)
            let channels = Int(pcmBuffer.format.channelCount)
            guard frameCount > 0, channels > 0 else { return }

            var int16Data = Data(count: frameCount * 2)
            var squaredAmplitude: Float = 0
            int16Data.withUnsafeMutableBytes { rawBuffer in
                let samples = rawBuffer.bindMemory(to: Int16.self)
                for index in 0..<frameCount {
                    let sample: Float = if channels > 1 {
                        (floatData[0][index] + floatData[1][index]) * 0.5
                    } else {
                        floatData[0][index]
                    }
                    let clamped = max(-1.0, min(1.0, sample))
                    squaredAmplitude += clamped * clamped
                    samples[index] = Int16(clamped * 32_767.0)
                }
            }
            let rms = sqrt(squaredAmplitude / Float(frameCount))
            buffer.append(int16Data, normalizedLevel: normalizedMeterLevel(forRMS: rms))
        }
    }

    nonisolated static func normalizedMeterLevel(forRMS rms: Float) -> Double {
        let floorDecibels: Float = -60
        let decibels = 20 * log10(max(rms, 0.000_001))
        let linear = min(max((decibels - floorDecibels) / -floorDecibels, 0), 1)
        return Double(pow(linear, 1.35))
    }

    /// Consolidate, downsample, and encode away from the UI actor. The capture
    /// callback remains allocation-bounded while stop no longer performs a
    /// multi-megabyte reduce/write on the main thread.
    private nonisolated static func finalizeWAVFile(
        chunks: [Data],
        inputSampleRate: Double
    ) async -> URL? {
        await Task.detached(priority: .userInitiated) {
            let pcmData = chunks.reduce(into: Data()) { $0.append($1) }
            let normalized = resampleMonoPCM16(
                pcmData,
                from: inputSampleRate,
                to: transcriptionSampleRate
            )
            return writeWAVFile(
                pcmData: normalized,
                sampleRate: min(inputSampleRate, transcriptionSampleRate)
            )
        }.value
    }

    /// Area-average resampling for mono signed 16-bit PCM. Microphone hardware
    /// commonly captures at 44.1/48 kHz; Whisper consumes 16 kHz speech. The
    /// weighted interval average provides an anti-aliasing low-pass while
    /// reducing upload/base64 work by roughly two thirds.
    nonisolated static func resampleMonoPCM16(
        _ pcmData: Data,
        from inputSampleRate: Double,
        to outputSampleRate: Double
    ) -> Data {
        guard !pcmData.isEmpty,
              pcmData.count.isMultiple(of: MemoryLayout<Int16>.size),
              inputSampleRate.isFinite,
              outputSampleRate.isFinite,
              inputSampleRate > outputSampleRate,
              outputSampleRate > 0 else {
            return pcmData
        }

        let inputCount = pcmData.count / MemoryLayout<Int16>.size
        let ratio = inputSampleRate / outputSampleRate
        let outputCount = max(1, Int((Double(inputCount) / ratio).rounded(.down)))
        var output = Data(count: outputCount * MemoryLayout<Int16>.size)
        pcmData.withUnsafeBytes { inputRaw in
            output.withUnsafeMutableBytes { outputRaw in
                let input = inputRaw.bindMemory(to: Int16.self)
                let samples = outputRaw.bindMemory(to: Int16.self)
                for outputIndex in 0..<outputCount {
                    let start = Double(outputIndex) * ratio
                    let end = min(Double(inputCount), start + ratio)
                    let firstInput = Int(start.rounded(.down))
                    let lastInput = min(inputCount, Int(end.rounded(.up)))
                    var weightedTotal = 0.0
                    var totalWeight = 0.0
                    for inputIndex in firstInput..<lastInput {
                        let lower = max(start, Double(inputIndex))
                        let upper = min(end, Double(inputIndex + 1))
                        let weight = max(0, upper - lower)
                        weightedTotal += Double(input[inputIndex]) * weight
                        totalWeight += weight
                    }
                    let averaged = totalWeight > 0 ? weightedTotal / totalWeight : 0
                    samples[outputIndex] = Int16(
                        max(Double(Int16.min), min(Double(Int16.max), averaged.rounded()))
                    )
                }
            }
        }
        return output
    }

    nonisolated static func writeWAVFile(pcmData: Data, sampleRate: Double) -> URL? {
        guard !pcmData.isEmpty else { return nil }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tron-composer-recording-\(UUID().uuidString)")
            .appendingPathExtension("wav")
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = UInt32(sampleRate) * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        let dataSize = UInt32(pcmData.count)
        let fileSize = 36 + dataSize

        var header = Data(capacity: 44)
        header.append(contentsOf: [0x52, 0x49, 0x46, 0x46])
        header.append(littleEndian: fileSize)
        header.append(contentsOf: [0x57, 0x41, 0x56, 0x45])
        header.append(contentsOf: [0x66, 0x6D, 0x74, 0x20])
        header.append(littleEndian: UInt32(16))
        header.append(littleEndian: UInt16(1))
        header.append(littleEndian: channels)
        header.append(littleEndian: UInt32(sampleRate))
        header.append(littleEndian: byteRate)
        header.append(littleEndian: blockAlign)
        header.append(littleEndian: bitsPerSample)
        header.append(contentsOf: [0x64, 0x61, 0x74, 0x61])
        header.append(littleEndian: dataSize)

        var fileData = header
        fileData.append(pcmData)
        do {
            try fileData.write(to: url)
            return url
        } catch {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
    }

    private static func simulatorSilentPCMData(
        sampleRate: Double,
        elapsed: TimeInterval
    ) -> Data {
        let boundedSeconds = min(max(elapsed, 0.25), 5.0)
        let frameCount = max(4_096, Int(sampleRate * boundedSeconds))
        return Data(count: frameCount * 2)
    }

    private func deactivateSession() {
        guard ownsActiveAudioSession else { return }
        ownsActiveAudioSession = false
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: [.notifyOthersOnDeactivation]
        )
    }
}

enum ComposerMicCaptureError: LocalizedError {
    case startFailed(String)

    var errorDescription: String? {
        switch self {
        case .startFailed(let reason): return reason
        }
    }
}

private extension Data {
    mutating func append(littleEndian value: UInt16) {
        var value = value.littleEndian
        append(Data(bytes: &value, count: 2))
    }

    mutating func append(littleEndian value: UInt32) {
        var value = value.littleEndian
        append(Data(bytes: &value, count: 4))
    }
}
