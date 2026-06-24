import XCTest
@testable import TronMobile

@MainActor
final class ChatTranscriptionCoordinatorTests: XCTestCase {
    func testFinishedRecordingInsertsTranscriptIntoEmptyInput() async {
        let coordinator = ChatTranscriptionCoordinator()
        let context = MockTranscriptionContext()
        context.nextTranscript = "  hello tron  "
        let url = URL(fileURLWithPath: "/tmp/input.wav")

        await coordinator.handleRecordingFinished(url: url, success: true, context: context)

        XCTAssertEqual(context.inputText, "hello tron")
        XCTAssertEqual(context.loadedURL, url)
        XCTAssertEqual(context.transcribedMimeType, "audio/wav")
        XCTAssertFalse(context.isTranscribing)
        XCTAssertTrue(context.errors.isEmpty)
    }

    func testFinishedRecordingAppendsTranscriptAfterExistingDraft() async {
        let coordinator = ChatTranscriptionCoordinator()
        let context = MockTranscriptionContext()
        context.inputText = "Existing prompt"
        context.nextTranscript = "second line"

        await coordinator.handleRecordingFinished(
            url: URL(fileURLWithPath: "/tmp/input.m4a"),
            success: true,
            context: context
        )

        XCTAssertEqual(context.inputText, "Existing prompt\nsecond line")
        XCTAssertEqual(context.transcribedMimeType, "audio/m4a")
    }

    func testEmptyTranscriptAddsNoSpeechError() async {
        let coordinator = ChatTranscriptionCoordinator()
        let context = MockTranscriptionContext()
        context.nextTranscript = "  \n "

        await coordinator.handleRecordingFinished(
            url: URL(fileURLWithPath: "/tmp/input.wav"),
            success: true,
            context: context
        )

        XCTAssertEqual(context.inputText, "")
        XCTAssertEqual(context.errors, ["No speech detected."])
        XCTAssertFalse(context.isTranscribing)
    }

    func testCancelledTranscriptionDoesNotMutateDraftAfterLateCompletion() async {
        let coordinator = ChatTranscriptionCoordinator()
        let context = MockTranscriptionContext()
        let transcriptionStarted = expectation(description: "transcription started")
        context.nextTranscript = "late transcript"
        context.onTranscriptionStarted = {
            transcriptionStarted.fulfill()
        }

        let task = Task { @MainActor in
            await coordinator.handleRecordingFinished(
                url: URL(fileURLWithPath: "/tmp/input.wav"),
                success: true,
                context: context
            )
        }

        await fulfillment(of: [transcriptionStarted], timeout: 1.0)
        task.cancel()
        context.resumeTranscription()
        await task.value

        XCTAssertEqual(context.inputText, "")
        XCTAssertTrue(context.errors.isEmpty)
        XCTAssertFalse(context.isTranscribing)
        XCTAssertEqual(context.transcribedMimeType, "audio/wav")
    }

    func testToggleRecordingStopsActiveRecordingAndTranscribes() async {
        let coordinator = ChatTranscriptionCoordinator()
        let context = MockTranscriptionContext()
        let url = URL(fileURLWithPath: "/tmp/input.caf")
        context.isRecording = true
        context.stopResult = (url, true)
        context.nextTranscript = "captured text"

        await coordinator.toggleRecording(context: context)

        XCTAssertEqual(context.stopRecordingCallCount, 1)
        XCTAssertEqual(context.startRecordingCallCount, 0)
        XCTAssertEqual(context.inputText, "captured text")
        XCTAssertEqual(context.transcribedMimeType, "audio/x-caf")
    }

    func testCancelledRecordingStartupCleansUpAfterLateStartCompletion() async {
        let coordinator = ChatTranscriptionCoordinator()
        let context = MockTranscriptionContext()
        let startSuspended = expectation(description: "recording startup suspended")
        context.onStartRecordingSuspended = {
            startSuspended.fulfill()
        }

        let task = Task { @MainActor in
            await coordinator.toggleRecording(context: context)
        }

        await fulfillment(of: [startSuspended], timeout: 1.0)
        task.cancel()
        context.resumeStartRecording()
        await task.value

        XCTAssertEqual(context.startRecordingCallCount, 1)
        XCTAssertEqual(context.cancelRecordingCallCount, 1)
        XCTAssertFalse(context.isRecording)
        XCTAssertFalse(context.isTranscribing)
        XCTAssertEqual(context.inputText, "")
        XCTAssertTrue(context.errors.isEmpty)
    }

    func testToggleRecordingDoesNotStartWhileProcessing() async {
        let coordinator = ChatTranscriptionCoordinator()
        let context = MockTranscriptionContext()
        context.isProcessing = true

        await coordinator.toggleRecording(context: context)

        XCTAssertEqual(context.startRecordingCallCount, 0)
        XCTAssertEqual(context.stopRecordingCallCount, 0)
        XCTAssertTrue(context.errors.isEmpty)
    }

    func testToggleRecordingStopsBeforeMicrophoneWhenTranscriptionDisabled() async {
        let coordinator = ChatTranscriptionCoordinator()
        let context = MockTranscriptionContext()
        context.readinessError = ChatTranscriptionAvailabilityError.disabled

        await coordinator.toggleRecording(context: context)

        XCTAssertEqual(context.readinessCallCount, 1)
        XCTAssertEqual(context.startRecordingCallCount, 0)
        XCTAssertEqual(context.errors, [
            "Local transcription is off. Enable Local transcription in Settings, restart Tron Server, then try again."
        ])
    }

    func testToggleRecordingShowsLoadingStateBeforeMicrophone() async {
        let coordinator = ChatTranscriptionCoordinator()
        let context = MockTranscriptionContext()
        context.readinessError = ChatTranscriptionAvailabilityError.loading("Local transcription model is loading.")

        await coordinator.toggleRecording(context: context)

        XCTAssertEqual(context.readinessCallCount, 1)
        XCTAssertEqual(context.startRecordingCallCount, 0)
        XCTAssertEqual(context.errors, ["Local transcription model is loading."])
    }

    func testToggleRecordingMapsMissingServerFunctionToRestartMessage() async {
        let coordinator = ChatTranscriptionCoordinator()
        let context = MockTranscriptionContext()
        context.readinessError = MockLocalizedError("function not found: transcription::list_models")

        await coordinator.toggleRecording(context: context)

        XCTAssertEqual(context.startRecordingCallCount, 0)
        XCTAssertEqual(context.errors, [
            "Voice input is not available on this Mac server yet. Restart Tron Server with the latest build, then try again."
        ])
    }

    func testFailedRecordingAddsRecordingError() async {
        let coordinator = ChatTranscriptionCoordinator()
        let context = MockTranscriptionContext()

        await coordinator.handleRecordingFinished(url: nil, success: false, context: context)

        XCTAssertEqual(context.errors, ["Recording failed."])
        XCTAssertFalse(context.isTranscribing)
    }

    func testWAVWriterProducesRiffFile() throws {
        let pcm = Data(repeating: 0x7f, count: 4_096)
        let url = try XCTUnwrap(ComposerMicCaptureEngine.writeWAVFile(pcmData: pcm, sampleRate: 44_100))
        defer { try? FileManager.default.removeItem(at: url) }

        let data = try Data(contentsOf: url)
        XCTAssertEqual(String(data: data.prefix(4), encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: data.dropFirst(8).prefix(4), encoding: .ascii), "WAVE")
        XCTAssertEqual(data.count, 44 + pcm.count)
    }
}

@MainActor
private final class MockTranscriptionContext: ChatTranscriptionContext {
    var isRecording = false
    var isProcessing = false
    var isTranscribing = false
    var inputText = ""
    var maxRecordingDuration: TimeInterval = 300

    var nextTranscript = ""
    var nextData = Data(repeating: 1, count: 2_048)
    var stopResult: (url: URL?, success: Bool) = (nil, false)
    var readinessError: Error?

    var readinessCallCount = 0
    var startRecordingCallCount = 0
    var cancelRecordingCallCount = 0
    var stopRecordingCallCount = 0
    var loadedURL: URL?
    var transcribedMimeType: String?
    var errors: [String] = []
    var shownErrors: [String] = []
    var onStartRecordingSuspended: (() -> Void)?
    var onTranscriptionStarted: (() -> Void)?
    private var startRecordingContinuation: CheckedContinuation<Void, Never>?
    private var transcribeContinuation: CheckedContinuation<String, Error>?

    func requireTranscriptionReady() async throws {
        readinessCallCount += 1
        if let readinessError {
            throw readinessError
        }
    }

    func startRecording() async throws {
        startRecordingCallCount += 1
        if onStartRecordingSuspended != nil {
            await withCheckedContinuation { continuation in
                startRecordingContinuation = continuation
                onStartRecordingSuspended?()
            }
        }
        isRecording = true
    }

    func cancelRecording() {
        cancelRecordingCallCount += 1
        isRecording = false
        isTranscribing = false
    }

    @discardableResult
    func stopRecording() -> (url: URL?, success: Bool) {
        stopRecordingCallCount += 1
        isRecording = false
        return stopResult
    }

    func transcribeAudio(data: Data, mimeType: String, fileName: String) async throws -> String {
        transcribedMimeType = mimeType
        if onTranscriptionStarted != nil {
            return try await withCheckedThrowingContinuation { continuation in
                transcribeContinuation = continuation
                onTranscriptionStarted?()
            }
        }
        return nextTranscript
    }

    func resumeTranscription() {
        transcribeContinuation?.resume(returning: nextTranscript)
        transcribeContinuation = nil
    }

    func resumeStartRecording() {
        startRecordingContinuation?.resume()
        startRecordingContinuation = nil
    }

    func loadAudioData(from url: URL) async throws -> Data {
        loadedURL = url
        return nextData
    }

    func appendTranscriptionError(_ message: String) {
        errors.append(message)
    }

    func showError(_ message: String) {
        shownErrors.append(message)
    }

    func logVerbose(_ message: String) {}
    func logDebug(_ message: String) {}
    func logInfo(_ message: String) {}
    func logWarning(_ message: String) {}
    func logError(_ message: String) {}
}

private struct MockLocalizedError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}
