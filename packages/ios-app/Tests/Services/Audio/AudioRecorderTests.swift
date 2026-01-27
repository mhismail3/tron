import XCTest
@testable import TronMobile

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

    // MARK: - Initial State Tests

    func test_initialState_isNotRecording() {
        let recorder = AudioRecorder()
        XCTAssertFalse(recorder.isRecording)
    }

    func test_initialState_onFinishIsNil() {
        let recorder = AudioRecorder()
        XCTAssertNil(recorder.onFinish)
    }

    // MARK: - Property Access Tests

    func test_isRecording_isAccessible() {
        let recorder = AudioRecorder()
        _ = recorder.isRecording
    }

    func test_onFinish_canBeSet() {
        let recorder = AudioRecorder()
        var callbackCalled = false
        recorder.onFinish = { _, _ in
            callbackCalled = true
        }

        // Verify callback is set (we can't actually invoke it without recording)
        XCTAssertNotNil(recorder.onFinish)
        XCTAssertFalse(callbackCalled) // Not called yet
    }

    // MARK: - Cancel Recording Tests

    func test_cancelRecording_whenNotRecording_doesNotCrash() {
        let recorder = AudioRecorder()
        recorder.cancelRecording()
        XCTAssertFalse(recorder.isRecording)
    }

    // MARK: - Stop Recording Tests

    func test_stopRecording_whenNotRecording_doesNotCrash() {
        let recorder = AudioRecorder()
        recorder.stopRecording()
        XCTAssertFalse(recorder.isRecording)
    }

    // MARK: - Prewarm Tests

    func test_prewarmAudioSession_doesNotCrash() {
        let recorder = AudioRecorder()
        recorder.prewarmAudioSession()
        // Should not crash and should return immediately
    }

    func test_prewarmAudioSession_canBeCalledMultipleTimes() {
        let recorder = AudioRecorder()
        recorder.prewarmAudioSession()
        recorder.prewarmAudioSession()
        recorder.prewarmAudioSession()
        // Should not crash, second+ calls should be no-ops
    }

    // MARK: - Callback Tests

    func test_onFinish_callback_signature() {
        let recorder = AudioRecorder()
        var receivedURL: URL?
        var receivedSuccess: Bool?

        recorder.onFinish = { url, success in
            receivedURL = url
            receivedSuccess = success
        }

        // Verify the callback type is correct (can accept optional URL and Bool)
        XCTAssertNotNil(recorder.onFinish)
    }
}
