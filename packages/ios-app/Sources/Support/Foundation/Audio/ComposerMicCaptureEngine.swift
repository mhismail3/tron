import Foundation
@preconcurrency import AVFoundation

final class ComposerMicCaptureBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var chunks: [Data] = []

    func append(_ data: Data) {
        lock.withLock { chunks.append(data) }
    }

    func drain() -> Data {
        lock.withLock {
            defer { chunks = [] }
            return chunks.reduce(into: Data()) { $0.append($1) }
        }
    }

    func discard() {
        lock.withLock { chunks = [] }
    }
}

@MainActor
final class ComposerMicCaptureEngine {
    private(set) var isRunning = false
    private(set) var sampleRate: Double = 44_100

    nonisolated static let sessionOptions: AVAudioSession.CategoryOptions = [.defaultToSpeaker, .mixWithOthers]

    private var engine: AVAudioEngine?
    private let captureBuffer = ComposerMicCaptureBuffer()
    private var simulatorRecordingStartedAt: Date?

    nonisolated static var usesSimulatorSafeCaptureBackend: Bool {
        #if targetEnvironment(simulator)
        true
        #else
        false
        #endif
    }

    func requestPermission() async -> Bool {
        await MicAvailabilityMonitor.shared.requestPermissionIfNeeded()
    }

    func start() async throws {
        guard !isRunning else { return }

        if Self.usesSimulatorSafeCaptureBackend {
            sampleRate = 44_100
            captureBuffer.discard()
            isRunning = true
            simulatorRecordingStartedAt = Date()
            return
        }

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: Self.sessionOptions)
            try session.setPreferredSampleRate(44_100)
            try session.setActive(true, options: [])
        } catch {
            throw ComposerMicCaptureError.startFailed("Failed to configure audio session: \(error.localizedDescription)")
        }

        sampleRate = session.sampleRate
        let audioEngine = AVAudioEngine()
        let inputNode = audioEngine.inputNode
        let hwFormat = inputNode.outputFormat(forBus: 0)
        guard hwFormat.channelCount > 0, hwFormat.sampleRate > 0 else {
            try? session.setActive(false, options: [.notifyOthersOnDeactivation])
            throw ComposerMicCaptureError.startFailed("No audio input available")
        }

        Self.installInputTap(on: inputNode, buffer: captureBuffer)
        do {
            try audioEngine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            try? session.setActive(false, options: [.notifyOthersOnDeactivation])
            throw ComposerMicCaptureError.startFailed("Failed to start audio engine: \(error.localizedDescription)")
        }

        engine = audioEngine
        isRunning = true
    }

    @discardableResult
    func stop() -> URL? {
        if Self.usesSimulatorSafeCaptureBackend {
            guard isRunning else { return nil }
            isRunning = false
            let startedAt = simulatorRecordingStartedAt
            simulatorRecordingStartedAt = nil
            let pcmData = Self.simulatorSilentPCMData(
                sampleRate: sampleRate,
                elapsed: startedAt.map { Date().timeIntervalSince($0) } ?? 0.25
            )
            return Self.writeWAVFile(pcmData: pcmData, sampleRate: sampleRate)
        }

        guard isRunning, let audioEngine = engine else { return nil }
        isRunning = false
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        engine = nil

        let pcmData = captureBuffer.drain()
        let url = Self.writeWAVFile(pcmData: pcmData, sampleRate: sampleRate)
        deactivateSession()
        return url
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
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { pcmBuffer, _ in
            guard let floatData = pcmBuffer.floatChannelData else { return }
            let frameCount = Int(pcmBuffer.frameLength)
            let channels = Int(pcmBuffer.format.channelCount)
            guard frameCount > 0, channels > 0 else { return }

            var int16Data = Data(count: frameCount * 2)
            int16Data.withUnsafeMutableBytes { rawBuffer in
                let samples = rawBuffer.bindMemory(to: Int16.self)
                for i in 0..<frameCount {
                    let sample: Float
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

    static func writeWAVFile(pcmData: Data, sampleRate: Double) -> URL? {
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

    private static func simulatorSilentPCMData(sampleRate: Double, elapsed: TimeInterval) -> Data {
        let boundedSeconds = min(max(elapsed, 0.25), 5.0)
        let frameCount = max(4_096, Int(sampleRate * boundedSeconds))
        return Data(count: frameCount * 2)
    }

    private func deactivateSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
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
        var v = value.littleEndian
        append(Data(bytes: &v, count: 2))
    }

    mutating func append(littleEndian value: UInt32) {
        var v = value.littleEndian
        append(Data(bytes: &v, count: 4))
    }
}
