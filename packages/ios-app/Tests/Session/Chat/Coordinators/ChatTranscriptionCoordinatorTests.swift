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

    func testToggleRecordingDoesNotStartWhileProcessing() async {
        let coordinator = ChatTranscriptionCoordinator()
        let context = MockTranscriptionContext()
        context.isProcessing = true

        await coordinator.toggleRecording(context: context)

        XCTAssertEqual(context.startRecordingCallCount, 0)
        XCTAssertEqual(context.stopRecordingCallCount, 0)
        XCTAssertTrue(context.errors.isEmpty)
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

    var startRecordingCallCount = 0
    var stopRecordingCallCount = 0
    var loadedURL: URL?
    var transcribedMimeType: String?
    var errors: [String] = []
    var shownErrors: [String] = []

    func startRecording() async throws {
        startRecordingCallCount += 1
        isRecording = true
    }

    @discardableResult
    func stopRecording() -> (url: URL?, success: Bool) {
        stopRecordingCallCount += 1
        isRecording = false
        return stopResult
    }

    func transcribeAudio(data: Data, mimeType: String, fileName: String) async throws -> String {
        transcribedMimeType = mimeType
        return nextTranscript
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
