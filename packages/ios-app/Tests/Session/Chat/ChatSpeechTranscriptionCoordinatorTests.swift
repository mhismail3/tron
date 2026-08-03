import XCTest
@testable import TronMobile

@MainActor
final class ChatSpeechTranscriptionCoordinatorTests: XCTestCase {
    func testFinishedCaptureInsertsTrimmedTranscriptIntoEmptyDraft() async {
        let coordinator = ChatSpeechTranscriptionCoordinator()
        let context = MockSpeechTranscriptionContext()
        context.nextTranscript = "  hello tron  "
        let url = URL(fileURLWithPath: "/tmp/input.wav")

        await coordinator.handleRecordingFinished(url: url, success: true, context: context)

        XCTAssertEqual(context.inputText, "hello tron")
        XCTAssertEqual(context.loadedURL, url)
        XCTAssertEqual(context.transcribedMimeType, "audio/wav")
        XCTAssertFalse(context.isTranscribing)
        XCTAssertTrue(context.errors.isEmpty)
    }

    func testFinishedCaptureAppendsTranscriptAfterExistingDraft() async {
        let coordinator = ChatSpeechTranscriptionCoordinator()
        let context = MockSpeechTranscriptionContext()
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

    func testEmptyTranscriptReportsNoSpeechWithoutMutatingDraft() async {
        let coordinator = ChatSpeechTranscriptionCoordinator()
        let context = MockSpeechTranscriptionContext()
        context.nextTranscript = " \n "

        await coordinator.handleRecordingFinished(
            url: URL(fileURLWithPath: "/tmp/input.wav"),
            success: true,
            context: context
        )

        XCTAssertEqual(context.inputText, "")
        XCTAssertEqual(context.errors, ["No speech detected."])
        XCTAssertFalse(context.isTranscribing)
    }

    func testToggleRequiresCurrentSpeechWorkerBeforeOpeningMicrophone() async {
        let coordinator = ChatSpeechTranscriptionCoordinator()
        let context = MockSpeechTranscriptionContext()
        context.readinessError = SpeechTranscriptionAvailabilityError.noActiveWorker

        await coordinator.toggleRecording(context: context)

        XCTAssertEqual(context.readinessCallCount, 1)
        XCTAssertEqual(context.startRecordingCallCount, 0)
        XCTAssertEqual(context.errors, [
            "Voice input needs a healthy speech transcription worker. Ask Tron to create or enable one, then try again."
        ])
    }

    func testToggleStopsActiveCaptureAndInvokesTranscription() async {
        let coordinator = ChatSpeechTranscriptionCoordinator()
        let context = MockSpeechTranscriptionContext()
        context.isRecording = true
        context.stopResult = (URL(fileURLWithPath: "/tmp/input.caf"), true)
        context.nextTranscript = "captured text"

        await coordinator.toggleRecording(context: context)

        XCTAssertEqual(context.stopRecordingCallCount, 1)
        XCTAssertEqual(context.startRecordingCallCount, 0)
        XCTAssertEqual(context.inputText, "captured text")
        XCTAssertEqual(context.transcribedMimeType, "audio/x-caf")
    }

    func testCancellationPreventsLateTranscriptFromMutatingDraft() async {
        let coordinator = ChatSpeechTranscriptionCoordinator()
        let context = MockSpeechTranscriptionContext()
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
        await fulfillment(of: [transcriptionStarted], timeout: 1)
        task.cancel()
        context.resumeTranscription()
        await task.value

        XCTAssertEqual(context.inputText, "")
        XCTAssertTrue(context.errors.isEmpty)
        XCTAssertFalse(context.isTranscribing)
    }

    func testTrailingModeShowsMicOnlyWhenSpeechActionIsAvailable() {
        XCTAssertEqual(
            ComposerTrailingMode(
                showStop: false,
                canSend: false,
                canRecord: true,
                isRecording: false,
                isTranscribing: false
            ),
            .record
        )
        XCTAssertEqual(
            ComposerTrailingMode(
                showStop: false,
                canSend: false,
                canRecord: false,
                isRecording: false,
                isTranscribing: false
            ),
            .send
        )
    }

    func testTrailingModePreservesLifecyclePrecedence() {
        XCTAssertEqual(
            ComposerTrailingMode(
                showStop: true,
                canSend: true,
                canRecord: true,
                isRecording: true,
                isTranscribing: true
            ),
            .stopAgent
        )
        XCTAssertEqual(
            ComposerTrailingMode(
                showStop: false,
                canSend: true,
                canRecord: true,
                isRecording: true,
                isTranscribing: false
            ),
            .stopRecording
        )
        XCTAssertEqual(
            ComposerTrailingMode(
                showStop: false,
                canSend: true,
                canRecord: true,
                isRecording: false,
                isTranscribing: true
            ),
            .transcribing
        )
    }

    func testWAVWriterProducesRiffFile() throws {
        let pcm = Data(repeating: 0x7f, count: 4_096)
        let url = try XCTUnwrap(
            ComposerMicCaptureEngine.writeWAVFile(pcmData: pcm, sampleRate: 44_100)
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let data = try Data(contentsOf: url)
        XCTAssertEqual(String(data: data.prefix(4), encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: data.dropFirst(8).prefix(4), encoding: .ascii), "WAVE")
        XCTAssertEqual(data.count, 44 + pcm.count)
    }

    func testAudioMeterAndSmoothingStayBounded() {
        XCTAssertEqual(ComposerMicCaptureEngine.normalizedMeterLevel(forRMS: 0), 0, accuracy: 0.001)
        XCTAssertGreaterThan(ComposerMicCaptureEngine.normalizedMeterLevel(forRMS: 0.02), 0.2)
        XCTAssertEqual(ComposerMicCaptureEngine.normalizedMeterLevel(forRMS: 1), 1, accuracy: 0.001)

        var smoother = ComposerAudioLevelSmoother()
        XCTAssertEqual(smoother.update(target: 1), 0.58, accuracy: 0.001)
        XCTAssertEqual(smoother.update(target: 0), 0.464, accuracy: 0.001)
        smoother.reset()
        XCTAssertEqual(smoother.value, 0)
    }

    func testNeverStartedCaptureCanBeCancelledRepeatedly() {
        let engine = ComposerMicCaptureEngine()

        engine.cancel()
        engine.cancel()

        XCTAssertFalse(engine.isRunning)
    }
}

@MainActor
private final class MockSpeechTranscriptionContext: ChatSpeechTranscriptionContext {
    var isRecording = false
    var isProcessing = false
    var isTranscribing = false
    var inputText = ""

    var nextTranscript = ""
    var stopResult: (url: URL?, success: Bool) = (nil, false)
    var readinessError: Error?
    var readinessCallCount = 0
    var startRecordingCallCount = 0
    var stopRecordingCallCount = 0
    var loadedURL: URL?
    var transcribedMimeType: String?
    var errors: [String] = []
    var onTranscriptionStarted: (() -> Void)?
    private var transcribeContinuation: CheckedContinuation<String, Error>?

    func requireSpeechTranscriptionReady() async throws {
        readinessCallCount += 1
        if let readinessError {
            throw readinessError
        }
    }

    func startRecording() async throws {
        startRecordingCallCount += 1
        isRecording = true
    }

    func cancelRecording() {
        isRecording = false
        isTranscribing = false
    }

    @discardableResult
    func stopRecording() -> (url: URL?, success: Bool) {
        stopRecordingCallCount += 1
        isRecording = false
        return stopResult
    }

    func transcribeCapturedAudio(
        data _: Data,
        mimeType: String,
        fileName _: String
    ) async throws -> String {
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

    func loadCapturedAudio(from url: URL) async throws -> Data {
        loadedURL = url
        return Data(repeating: 1, count: 2_048)
    }

    func appendSpeechTranscriptionError(_ message: String) {
        errors.append(message)
    }
}
