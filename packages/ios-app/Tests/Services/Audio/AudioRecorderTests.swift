import XCTest
import AVFoundation
@testable import TronMobile

// MARK: - AudioCaptureBuffer Tests

final class AudioCaptureBufferTests: XCTestCase {

    func test_initialDrainReturnsEmpty() {
        let buffer = AudioCaptureBuffer()
        XCTAssertTrue(buffer.drain().isEmpty)
    }

    func test_appendAndDrain() {
        let buffer = AudioCaptureBuffer()
        buffer.append(Data([1, 2, 3]))
        buffer.append(Data([4, 5, 6]))
        let result = buffer.drain()
        XCTAssertEqual(result, Data([1, 2, 3, 4, 5, 6]))
    }

    func test_drainClearsBuffer() {
        let buffer = AudioCaptureBuffer()
        buffer.append(Data([1, 2]))
        _ = buffer.drain()
        XCTAssertTrue(buffer.drain().isEmpty)
    }

    func test_discardClearsBuffer() {
        let buffer = AudioCaptureBuffer()
        buffer.append(Data([1, 2]))
        buffer.discard()
        XCTAssertTrue(buffer.drain().isEmpty)
    }

    func test_largeConcatenation() {
        let buffer = AudioCaptureBuffer()
        let chunk = Data(repeating: 0x42, count: 8192)
        for _ in 0..<100 { buffer.append(chunk) }
        let result = buffer.drain()
        XCTAssertEqual(result.count, 819_200)
    }
}

// MARK: - WAV File Writing Tests

@MainActor
final class WAVFileWritingTests: XCTestCase {

    func test_headerIs44Bytes() {
        let pcm = Data(repeating: 0, count: 100)
        let url = AudioRecorder.writeWAVFile(pcmData: pcm, sampleRate: 44100)
        XCTAssertNotNil(url)
        let data = try! Data(contentsOf: url!)
        XCTAssertEqual(data.count, 144)
        try? FileManager.default.removeItem(at: url!)
    }

    func test_riffHeader() {
        let pcm = Data([0x01, 0x00, 0xFF, 0x7F])
        let url = AudioRecorder.writeWAVFile(pcmData: pcm, sampleRate: 44100)!
        let data = try! Data(contentsOf: url)
        XCTAssertEqual(String(data: data[0..<4], encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: data[8..<12], encoding: .ascii), "WAVE")
        XCTAssertEqual(String(data: data[12..<16], encoding: .ascii), "fmt ")
        XCTAssertEqual(String(data: data[36..<40], encoding: .ascii), "data")
        try? FileManager.default.removeItem(at: url)
    }

    func test_sampleRateInHeader() {
        let pcm = Data(repeating: 0, count: 4)
        let url = AudioRecorder.writeWAVFile(pcmData: pcm, sampleRate: 48000)!
        let data = try! Data(contentsOf: url)
        let rate: UInt32 = data.subdata(in: 24..<28).withUnsafeBytes { $0.load(as: UInt32.self) }
        XCTAssertEqual(rate, 48000)
        try? FileManager.default.removeItem(at: url)
    }

    func test_pcmDataIntact() {
        let pcm = Data([0x01, 0x00, 0xFF, 0x7F, 0x00, 0x80])
        let url = AudioRecorder.writeWAVFile(pcmData: pcm, sampleRate: 44100)!
        let data = try! Data(contentsOf: url)
        XCTAssertEqual(data.subdata(in: 44..<50), pcm)
        try? FileManager.default.removeItem(at: url)
    }

    func test_emptyPCM_returnsNil() {
        let url = AudioRecorder.writeWAVFile(pcmData: Data(), sampleRate: 44100)
        XCTAssertNil(url)
    }
}

// MARK: - AudioRecorder Tests

@MainActor
final class AudioRecorderTests: XCTestCase {

    // MARK: - RecorderError Tests

    func test_recorderError_permissionDenied_hasDescription() {
        let error = AudioRecorder.RecorderError.permissionDenied
        XCTAssertEqual(error.errorDescription, "Microphone permission denied")
    }

    func test_recorderError_startFailed_hasDescription() {
        let error = AudioRecorder.RecorderError.startFailed("Test reason")
        XCTAssertEqual(error.errorDescription, "Test reason")
    }

    func test_recorderError_startFailed_includesCustomMessage() {
        let message = "Failed to configure audio session: Error occurred"
        let error = AudioRecorder.RecorderError.startFailed(message)
        XCTAssertEqual(error.errorDescription, message)
    }

    // MARK: - State Machine Tests

    func test_initialState_isNotRecording() {
        let recorder = AudioRecorder()
        XCTAssertFalse(recorder.isRecording)
    }

    func test_initialState_onFinishIsNil() {
        let recorder = AudioRecorder()
        XCTAssertNil(recorder.onFinish)
    }

    func test_stopRecording_whenNotRecording_isIdempotent() {
        let recorder = AudioRecorder()
        let result1 = recorder.stopRecording()
        let result2 = recorder.stopRecording()
        XCTAssertFalse(recorder.isRecording)
        XCTAssertNil(result1.url)
        XCTAssertFalse(result1.success)
        XCTAssertNil(result2.url)
        XCTAssertFalse(result2.success)
    }

    func test_cancelRecording_whenNotRecording_isIdempotent() {
        let recorder = AudioRecorder()
        recorder.cancelRecording()
        recorder.cancelRecording()
        XCTAssertFalse(recorder.isRecording)
    }

    func test_onFinish_canBeSetAndCleared() {
        let recorder = AudioRecorder()
        recorder.onFinish = { _, _ in }
        XCTAssertNotNil(recorder.onFinish)
        recorder.onFinish = nil
        XCTAssertNil(recorder.onFinish)
    }

    func test_sessionOptions_containsDefaultToSpeaker() {
        XCTAssertTrue(AudioRecorder.sessionOptions.contains(.defaultToSpeaker))
    }
}
