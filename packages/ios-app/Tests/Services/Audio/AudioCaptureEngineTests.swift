import XCTest
@testable import TronMobile

@MainActor
final class AudioCaptureEngineTests: XCTestCase {
    func testSimulatorSafeCaptureBackendProducesWavWithoutStartingAVAudioEngine() async throws {
        #if targetEnvironment(simulator)
        XCTAssertTrue(AudioCaptureEngine.usesSimulatorSafeCaptureBackend)

        let engine = AudioCaptureEngine()
        try await engine.start()
        XCTAssertTrue(engine.isRunning)
        XCTAssertGreaterThan(engine.currentAudioLevel, 0)

        let url = try XCTUnwrap(engine.stop())
        defer { try? FileManager.default.removeItem(at: url) }

        let data = try Data(contentsOf: url)
        XCTAssertGreaterThan(data.count, 1_024)
        XCTAssertEqual(String(data: Data(data.prefix(4)), encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: Data(data.dropFirst(8).prefix(4)), encoding: .ascii), "WAVE")
        XCTAssertFalse(engine.isRunning)
        #else
        XCTAssertFalse(AudioCaptureEngine.usesSimulatorSafeCaptureBackend)
        #endif
    }

    func testSimulatorSafeCaptureBackendSupportsPrewarmFlow() async throws {
        #if targetEnvironment(simulator)
        let engine = AudioCaptureEngine()
        try await engine.prepare()
        XCTAssertTrue(engine.isPrepared)
        XCTAssertFalse(engine.isRunning)

        try await engine.start()
        XCTAssertFalse(engine.isPrepared)
        XCTAssertTrue(engine.isRunning)

        let url = try XCTUnwrap(engine.stop())
        defer { try? FileManager.default.removeItem(at: url) }

        let data = try Data(contentsOf: url)
        XCTAssertGreaterThan(data.count, 1_024)
        XCTAssertEqual(String(data: Data(data.prefix(4)), encoding: .ascii), "RIFF")
        XCTAssertFalse(engine.isPrepared)
        XCTAssertFalse(engine.isRunning)
        #else
        XCTAssertFalse(AudioCaptureEngine.usesSimulatorSafeCaptureBackend)
        #endif
    }
}
