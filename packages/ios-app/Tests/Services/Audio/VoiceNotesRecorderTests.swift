import XCTest
@testable import TronMobile

// MARK: - VoiceNotesRecorder Tests

@MainActor
final class VoiceNotesRecorderTests: XCTestCase {

    // MARK: - State Enum Tests

    func test_stateEnum_idleEquality() {
        XCTAssertEqual(VoiceNotesRecorder.State.idle, VoiceNotesRecorder.State.idle)
    }

    func test_stateEnum_recordingEquality() {
        XCTAssertEqual(VoiceNotesRecorder.State.recording, VoiceNotesRecorder.State.recording)
    }

    func test_stateEnum_savingEquality() {
        XCTAssertEqual(VoiceNotesRecorder.State.saving, VoiceNotesRecorder.State.saving)
    }

    func test_stateEnum_stoppedEquality() {
        let url1 = URL(string: "file:///test1.m4a")!
        let url2 = URL(string: "file:///test1.m4a")!
        let url3 = URL(string: "file:///test2.m4a")!

        XCTAssertEqual(VoiceNotesRecorder.State.stopped(url1), VoiceNotesRecorder.State.stopped(url2))
        XCTAssertNotEqual(VoiceNotesRecorder.State.stopped(url1), VoiceNotesRecorder.State.stopped(url3))
    }

    func test_stateEnum_differentStatesNotEqual() {
        XCTAssertNotEqual(VoiceNotesRecorder.State.idle, VoiceNotesRecorder.State.recording)
        XCTAssertNotEqual(VoiceNotesRecorder.State.recording, VoiceNotesRecorder.State.saving)
    }

    // MARK: - RecorderError Tests

    func test_recorderError_permissionDenied_hasDescription() {
        let error = VoiceNotesRecorder.RecorderError.permissionDenied
        XCTAssertEqual(error.errorDescription, "Microphone permission denied")
    }

    func test_recorderError_startFailed_hasDescription() {
        let error = VoiceNotesRecorder.RecorderError.startFailed("Custom reason")
        XCTAssertEqual(error.errorDescription, "Custom reason")
    }

    // MARK: - Initial State Tests

    func test_initialState_isIdle() {
        let recorder = VoiceNotesRecorder()
        XCTAssertEqual(recorder.state, .idle)
    }

    func test_initialState_isNotRecording() {
        let recorder = VoiceNotesRecorder()
        XCTAssertFalse(recorder.isRecording)
    }

    func test_initialState_hasNotStopped() {
        let recorder = VoiceNotesRecorder()
        XCTAssertFalse(recorder.hasStopped)
    }

    func test_initialState_audioLevelIsZero() {
        let recorder = VoiceNotesRecorder()
        XCTAssertEqual(recorder.audioLevel, 0)
    }

    func test_initialState_recordingDurationIsZero() {
        let recorder = VoiceNotesRecorder()
        XCTAssertEqual(recorder.recordingDuration, 0)
    }

    // MARK: - Property Access Tests

    func test_state_isAccessible() {
        let recorder = VoiceNotesRecorder()
        _ = recorder.state
    }

    func test_audioLevel_isAccessible() {
        let recorder = VoiceNotesRecorder()
        _ = recorder.audioLevel
    }

    func test_recordingDuration_isAccessible() {
        let recorder = VoiceNotesRecorder()
        _ = recorder.recordingDuration
    }

    func test_isRecording_isAccessible() {
        let recorder = VoiceNotesRecorder()
        _ = recorder.isRecording
    }

    func test_hasStopped_isAccessible() {
        let recorder = VoiceNotesRecorder()
        _ = recorder.hasStopped
    }

    // MARK: - Max Duration Tests

    func test_maxDuration_isFiveMinutes() {
        XCTAssertEqual(VoiceNotesRecorder.maxDuration, 300)
    }

    // MARK: - isRecording Computed Property Tests

    func test_isRecording_falseWhenIdle() {
        let recorder = VoiceNotesRecorder()
        XCTAssertEqual(recorder.state, .idle)
        XCTAssertFalse(recorder.isRecording)
    }

    // MARK: - hasStopped Computed Property Tests

    func test_hasStopped_falseWhenIdle() {
        let recorder = VoiceNotesRecorder()
        XCTAssertEqual(recorder.state, .idle)
        XCTAssertFalse(recorder.hasStopped)
    }

    // MARK: - getRecordingURL Tests

    func test_getRecordingURL_returnsNilWhenIdle() {
        let recorder = VoiceNotesRecorder()
        XCTAssertNil(recorder.getRecordingURL())
    }

    // MARK: - Reset Tests

    func test_reset_resetsToIdle() {
        let recorder = VoiceNotesRecorder()
        recorder.reset()
        XCTAssertEqual(recorder.state, .idle)
    }

    // MARK: - Cancel Recording Tests

    func test_cancelRecording_resetsState() {
        let recorder = VoiceNotesRecorder()
        recorder.cancelRecording()
        XCTAssertEqual(recorder.state, .idle)
        XCTAssertEqual(recorder.audioLevel, 0)
        XCTAssertEqual(recorder.recordingDuration, 0)
    }

    // MARK: - Stop Recording Tests

    func test_stopRecording_doesNothingWhenNotRecording() {
        let recorder = VoiceNotesRecorder()
        recorder.stopRecording()
        // Should not crash, state remains idle
        XCTAssertEqual(recorder.state, .idle)
    }
}
