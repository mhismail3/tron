import Testing
import Foundation

extension SourceGuardTests {
    @Test("Voice recording cancels when leaving chat")
    func testVoiceRecordingCancelsWhenLeavingChat() throws {
        let iosRoot = iosAppRoot()
        let chatViewSource = try String(
            contentsOf: iosRoot.appendingPathComponent("Sources/UI/Chat/Shell/ChatView.swift"),
            encoding: .utf8
        )
        let transcriptionSource = try String(
            contentsOf: iosRoot.appendingPathComponent("Sources/Session/Chat/ViewModel/ChatViewModel+Transcription.swift"),
            encoding: .utf8
        )

        #expect(
            transcriptionSource.contains("func cancelRecording()") &&
                transcriptionSource.contains("transcriptionTask?.cancel()") &&
                transcriptionSource.contains("micRecorder.cancelRecording()"),
            "ChatViewModel must expose an explicit voice-recording and transcription cancellation boundary"
        )
        #expect(
            chatViewSource.contains("viewModel.cancelRecording()") &&
                chatViewSource.contains("viewModel.stopLiveEventStream()"),
            "ChatView must cancel active voice capture and transcription when leaving the chat"
        )
        #expect(
            chatViewSource.range(of: "viewModel.cancelRecording()")?.lowerBound ?? chatViewSource.endIndex
                < chatViewSource.range(of: "viewModel.stopLiveEventStream()")?.lowerBound ?? chatViewSource.startIndex,
            "ChatView should cancel active voice capture and transcription before tearing down live session state"
        )
    }
}
