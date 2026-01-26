import XCTest
@testable import TronMobile

/// Tests for TranscriptionCoordinator - handles voice recording and transcription
/// Uses TDD: Tests written first, then implementation follows
@MainActor
final class TranscriptionCoordinatorTests: XCTestCase {

    var coordinator: TranscriptionCoordinator!
    var mockContext: MockTranscriptionContext!

    override func setUp() async throws {
        mockContext = MockTranscriptionContext()
        coordinator = TranscriptionCoordinator()
    }

    override func tearDown() async throws {
        coordinator = nil
        mockContext = nil
    }

    // MARK: - Toggle Recording Tests

    func testToggleRecordingWhenNotRecordingStartsRecording() async {
        // Given: Not currently recording
        mockContext.isRecording = false

        // When: Toggle recording
        await coordinator.toggleRecording(context: mockContext)

        // Then: Should start recording
        XCTAssertTrue(mockContext.startRecordingCalled)
        XCTAssertFalse(mockContext.stopRecordingCalled)
    }

    func testToggleRecordingWhenRecordingStopsRecording() async {
        // Given: Currently recording
        mockContext.isRecording = true

        // When: Toggle recording
        await coordinator.toggleRecording(context: mockContext)

        // Then: Should stop recording
        XCTAssertTrue(mockContext.stopRecordingCalled)
        XCTAssertFalse(mockContext.startRecordingCalled)
    }

    func testToggleRecordingWhileProcessingDoesNotStart() async {
        // Given: Not recording but processing
        mockContext.isRecording = false
        mockContext.isProcessing = true

        // When: Toggle recording
        await coordinator.toggleRecording(context: mockContext)

        // Then: Should NOT start recording
        XCTAssertFalse(mockContext.startRecordingCalled)
    }

    func testToggleRecordingWhileTranscribingDoesNotStart() async {
        // Given: Not recording but transcribing
        mockContext.isRecording = false
        mockContext.isTranscribing = true

        // When: Toggle recording
        await coordinator.toggleRecording(context: mockContext)

        // Then: Should NOT start recording
        XCTAssertFalse(mockContext.startRecordingCalled)
    }

    func testStartRecordingFailureShowsNotification() async {
        // Given: Recording will fail
        mockContext.isRecording = false
        mockContext.startRecordingShouldFail = true

        // When: Toggle recording (starts)
        await coordinator.toggleRecording(context: mockContext)

        // Then: Should show transcription failed notification
        XCTAssertTrue(mockContext.transcriptionFailedNotificationShown)
    }

    // MARK: - Recording Finished Tests

    func testHandleRecordingFinishedWithSuccessTranscribes() async {
        // Given: Recording succeeded with valid URL
        let url = URL(fileURLWithPath: "/tmp/test_recording.m4a")
        mockContext.simulateAudioFileSize = 2048  // Larger than minimum
        mockContext.transcriptionResult = "Hello world"

        // When: Recording finished
        await coordinator.handleRecordingFinished(url: url, success: true, context: mockContext)

        // Then: Should transcribe and update input
        XCTAssertTrue(mockContext.transcribeAudioCalled)
        XCTAssertEqual(mockContext.inputText, "Hello world")
    }

    func testHandleRecordingFinishedWithFailureShowsNotification() async {
        // Given: Recording failed
        let url = URL(fileURLWithPath: "/tmp/test_recording.m4a")

        // When: Recording finished with failure
        await coordinator.handleRecordingFinished(url: nil, success: false, context: mockContext)

        // Then: Should show failed notification
        XCTAssertTrue(mockContext.transcriptionFailedNotificationShown)
        XCTAssertFalse(mockContext.transcribeAudioCalled)
    }

    func testHandleRecordingFinishedWithNilURLShowsNotification() async {
        // When: Recording finished with nil URL
        await coordinator.handleRecordingFinished(url: nil, success: true, context: mockContext)

        // Then: Should show failed notification
        XCTAssertTrue(mockContext.transcriptionFailedNotificationShown)
    }

    func testHandleRecordingFinishedWithTooSmallFileShowsNoSpeech() async {
        // Given: Recording is too small (< 1KB)
        let url = URL(fileURLWithPath: "/tmp/test_recording.m4a")
        mockContext.simulateAudioFileSize = 500  // Less than 1KB

        // When: Recording finished
        await coordinator.handleRecordingFinished(url: url, success: true, context: mockContext)

        // Then: Should show no speech notification
        XCTAssertTrue(mockContext.noSpeechNotificationShown)
        XCTAssertFalse(mockContext.transcribeAudioCalled)
    }

    func testHandleRecordingFinishedWithEmptyTranscriptShowsNoSpeech() async {
        // Given: Transcription returns empty text
        let url = URL(fileURLWithPath: "/tmp/test_recording.m4a")
        mockContext.simulateAudioFileSize = 2048
        mockContext.transcriptionResult = "   "  // Only whitespace

        // When: Recording finished
        await coordinator.handleRecordingFinished(url: url, success: true, context: mockContext)

        // Then: Should show no speech notification
        XCTAssertTrue(mockContext.noSpeechNotificationShown)
    }

    func testHandleRecordingFinishedAppendsToExistingInput() async {
        // Given: Input already has text
        let url = URL(fileURLWithPath: "/tmp/test_recording.m4a")
        mockContext.simulateAudioFileSize = 2048
        mockContext.inputText = "Existing text"
        mockContext.transcriptionResult = "New transcription"

        // When: Recording finished
        await coordinator.handleRecordingFinished(url: url, success: true, context: mockContext)

        // Then: Should append with newline
        XCTAssertEqual(mockContext.inputText, "Existing text\nNew transcription")
    }

    func testHandleRecordingFinishedReplacesEmptyInput() async {
        // Given: Input is empty/whitespace
        let url = URL(fileURLWithPath: "/tmp/test_recording.m4a")
        mockContext.simulateAudioFileSize = 2048
        mockContext.inputText = "   "  // Whitespace only
        mockContext.transcriptionResult = "New transcription"

        // When: Recording finished
        await coordinator.handleRecordingFinished(url: url, success: true, context: mockContext)

        // Then: Should replace (not append)
        XCTAssertEqual(mockContext.inputText, "New transcription")
    }

    func testHandleRecordingFinishedSetsTranscribingState() async {
        // Given: Valid recording
        let url = URL(fileURLWithPath: "/tmp/test_recording.m4a")
        mockContext.simulateAudioFileSize = 2048
        mockContext.transcriptionResult = "Hello"

        // When: Recording finished
        await coordinator.handleRecordingFinished(url: url, success: true, context: mockContext)

        // Then: isTranscribing should have been set true then false
        XCTAssertTrue(mockContext.isTranscribingWasSetTrue)
        XCTAssertFalse(mockContext.isTranscribing)  // Should be false at end
    }

    func testHandleRecordingFinishedWithTranscriptionErrorShowsFailure() async {
        // Given: Transcription will fail
        let url = URL(fileURLWithPath: "/tmp/test_recording.m4a")
        mockContext.simulateAudioFileSize = 2048
        mockContext.transcriptionShouldFail = true

        // When: Recording finished
        await coordinator.handleRecordingFinished(url: url, success: true, context: mockContext)

        // Then: Should show failed notification
        XCTAssertTrue(mockContext.transcriptionFailedNotificationShown)
    }

    func testHandleRecordingFinishedWithNoSpeechErrorShowsNoSpeech() async {
        // Given: Transcription fails with "no speech" error
        let url = URL(fileURLWithPath: "/tmp/test_recording.m4a")
        mockContext.simulateAudioFileSize = 2048
        mockContext.transcriptionShouldFailWithNoSpeech = true

        // When: Recording finished
        await coordinator.handleRecordingFinished(url: url, success: true, context: mockContext)

        // Then: Should show no speech notification (not generic failure)
        XCTAssertTrue(mockContext.noSpeechNotificationShown)
        XCTAssertFalse(mockContext.transcriptionFailedNotificationShown)
    }

    // MARK: - MIME Type Tests

    func testMimeTypeForWav() {
        let url = URL(fileURLWithPath: "/tmp/test.wav")
        let mimeType = coordinator.mimeType(for: url)
        XCTAssertEqual(mimeType, "audio/wav")
    }

    func testMimeTypeForM4a() {
        let url = URL(fileURLWithPath: "/tmp/test.m4a")
        let mimeType = coordinator.mimeType(for: url)
        XCTAssertEqual(mimeType, "audio/m4a")
    }

    func testMimeTypeForCaf() {
        let url = URL(fileURLWithPath: "/tmp/test.caf")
        let mimeType = coordinator.mimeType(for: url)
        XCTAssertEqual(mimeType, "audio/x-caf")
    }

    func testMimeTypeForUnknownExtension() {
        let url = URL(fileURLWithPath: "/tmp/test.xyz")
        let mimeType = coordinator.mimeType(for: url)
        XCTAssertEqual(mimeType, "application/octet-stream")
    }

    func testMimeTypeIsCaseInsensitive() {
        let url = URL(fileURLWithPath: "/tmp/test.WAV")
        let mimeType = coordinator.mimeType(for: url)
        XCTAssertEqual(mimeType, "audio/wav")
    }

    // MARK: - No Speech Error Detection Tests

    func testIsNoSpeechDetectedErrorWithNoSpeechMessage() {
        let error = TranscriptionTestError.custom("No speech detected in audio")
        XCTAssertTrue(coordinator.isNoSpeechDetectedError(error))
    }

    func testIsNoSpeechDetectedErrorWithNoTextMessage() {
        let error = TranscriptionTestError.custom("no text found")
        XCTAssertTrue(coordinator.isNoSpeechDetectedError(error))
    }

    func testIsNoSpeechDetectedErrorWithOtherMessage() {
        let error = TranscriptionTestError.custom("Network error")
        XCTAssertFalse(coordinator.isNoSpeechDetectedError(error))
    }
}

// MARK: - Test Error

enum TranscriptionTestError: Error, LocalizedError {
    case custom(String)
    case noSpeech
    case generic

    var errorDescription: String? {
        switch self {
        case .custom(let message): return message
        case .noSpeech: return "No speech detected"
        case .generic: return "Transcription failed"
        }
    }
}

// MARK: - Mock Context

/// Mock implementation of TranscriptionContext for testing
@MainActor
final class MockTranscriptionContext: TranscriptionContext {
    // MARK: - State
    var isRecording: Bool = false
    var isProcessing: Bool = false
    var isTranscribing: Bool = false {
        didSet {
            if isTranscribing {
                isTranscribingWasSetTrue = true
            }
        }
    }
    var inputText: String = ""
    var maxRecordingDuration: TimeInterval = 120

    // MARK: - Tracking for Assertions
    var startRecordingCalled = false
    var stopRecordingCalled = false
    var transcribeAudioCalled = false
    var transcriptionFailedNotificationShown = false
    var noSpeechNotificationShown = false
    var isTranscribingWasSetTrue = false

    // MARK: - Test Configuration
    var startRecordingShouldFail = false
    var transcriptionShouldFail = false
    var transcriptionShouldFailWithNoSpeech = false
    var transcriptionResult: String = ""
    var simulateAudioFileSize: Int = 0

    // MARK: - Protocol Methods

    func startRecording() async throws {
        startRecordingCalled = true
        if startRecordingShouldFail {
            throw TranscriptionTestError.generic
        }
    }

    func stopRecording() {
        stopRecordingCalled = true
    }

    func transcribeAudio(data: Data, mimeType: String, fileName: String) async throws -> String {
        transcribeAudioCalled = true
        if transcriptionShouldFailWithNoSpeech {
            throw TranscriptionTestError.noSpeech
        }
        if transcriptionShouldFail {
            throw TranscriptionTestError.generic
        }
        return transcriptionResult
    }

    func loadAudioData(from url: URL) async throws -> Data {
        if simulateAudioFileSize < 1024 {
            throw TronMobile.AudioFileTooSmallError(size: simulateAudioFileSize)
        }
        // Return dummy data of the simulated size
        return Data(count: simulateAudioFileSize)
    }

    func appendTranscriptionFailedNotification() {
        transcriptionFailedNotificationShown = true
    }

    func appendNoSpeechDetectedNotification() {
        noSpeechNotificationShown = true
    }

    // MARK: - Logging (no-op for tests)
    func logVerbose(_ message: String) {}
    func logDebug(_ message: String) {}
    func logInfo(_ message: String) {}
    func logWarning(_ message: String) {}
    func logError(_ message: String) {}
}
