import Testing
import Foundation

extension SourceGuardTests {
    @Test("Local transcription remains Engine settings policy")
    func testLocalTranscriptionRemainsEngineSettingsPolicy() throws {
        let iosRoot = iosAppRoot()
        let engineSource = try String(
            contentsOf: iosRoot.appendingPathComponent("Sources/UI/Settings/Pages/EngineSettingsPage.swift"),
            encoding: .utf8
        )
        let voiceSettingsPath = iosRoot.appendingPathComponent(
            "Sources/UI/Settings/Pages/VoiceSettingsPage.swift"
        )

        #expect(!FileManager.default.fileExists(atPath: voiceSettingsPath.path))
        #expect(engineSource.contains("label: \"Local transcription\""))
        #expect(engineSource.contains("updateServerSetting(.transcriptionEnabled(enabled))"))
        #expect(!engineSource.contains("label: \"Log level\""))
        #expect(!engineSource.contains("label: \"Retention\""))
        #expect(!engineSource.contains("label: \"Storage cap\""))
    }

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

    @Test("Voice waveform is driven by bounded recorder metering")
    func testVoiceWaveformUsesRecorderMetering() throws {
        let iosRoot = iosAppRoot()
        let recorderSource = try String(
            contentsOf: iosRoot.appendingPathComponent("Sources/Support/Foundation/Audio/ComposerMicRecorder.swift"),
            encoding: .utf8
        )
        let captureSource = try String(
            contentsOf: iosRoot.appendingPathComponent("Sources/Support/Foundation/Audio/ComposerMicCaptureEngine.swift"),
            encoding: .utf8
        )
        let waveformSource = try String(
            contentsOf: iosRoot.appendingPathComponent("Sources/UI/Chat/Composer/RecordingLevelWaveform.swift"),
            encoding: .utf8
        )
        let composerSource = try String(
            contentsOf: iosRoot.appendingPathComponent("Sources/UI/Chat/Composer/InputBar.swift"),
            encoding: .utf8
        )
        let shellSource = try String(
            contentsOf: iosRoot.appendingPathComponent("Sources/UI/Chat/Shell/ChatView+MessageList.swift"),
            encoding: .utf8
        )

        #expect(recorderSource.contains("private(set) var audioLevel: Double = 0"))
        #expect(recorderSource.contains("engine.currentLevel"))
        #expect(recorderSource.contains("stopMetering()"))
        #expect(captureSource.contains("squaredAmplitude += clamped * clamped"))
        #expect(captureSource.contains("normalizedMeterLevel(forRMS:"))
        #expect(waveformSource.contains("samples.removeFirst()"))
        #expect(waveformSource.contains("Color.tronEmerald"))
        #expect(composerSource.contains("RecordingLevelWaveform(level: config.recordingAudioLevel)"))
        #expect(shellSource.contains("recordingAudioLevel: viewModel.recordingAudioLevel"))
    }
}
