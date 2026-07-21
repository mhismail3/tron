import Foundation
import Testing

extension SourceGuardTests {
    @Test("Fixed transcription remains outside the primitive product shell")
    func fixedTranscriptionRemainsAbsent() throws {
        let iosRoot = iosAppRoot()
        let repoRoot = iosRoot.deletingLastPathComponent().deletingLastPathComponent()
        let forbiddenPaths = [
            "packages/agent/src/domains/transcription",
            "packages/ios-app/Sources/Engine/Protocol/EngineProtocolTypes+Transcription.swift",
            "packages/ios-app/Sources/Engine/Transport/Clients/TranscriptionClient.swift",
            "packages/ios-app/Sources/Session/Chat/Coordinators/ChatTranscriptionCoordinator.swift",
            "packages/ios-app/Sources/Session/Chat/ViewModel/ChatViewModel+Transcription.swift",
            "packages/ios-app/Sources/Support/Foundation/Audio/ComposerMicCaptureEngine.swift",
            "packages/ios-app/Sources/Support/Foundation/Audio/ComposerMicRecorder.swift",
            "packages/ios-app/Sources/UI/Chat/Composer/RecordingLevelWaveform.swift",
        ]

        for relativePath in forbiddenPaths {
            let path = repoRoot.appendingPathComponent(relativePath).path
            #expect(!FileManager.default.fileExists(atPath: path), "Fixed feature residue: \(relativePath)")
        }
    }

    @Test("iOS product surfaces do not advertise fixed voice transcription")
    func productSurfacesDoNotAdvertiseFixedVoiceTranscription() throws {
        let iosRoot = iosAppRoot()
        let paths = [
            "Sources/Engine/Protocol/EngineProtocolTypes+Settings.swift",
            "Sources/Engine/Transport/WebSocket/EngineClient.swift",
            "Sources/Session/Chat/State/InputBarState.swift",
            "Sources/UI/Chat/Composer/ActionButtons.swift",
            "Sources/UI/Chat/Composer/InputBar.swift",
            "Sources/UI/Settings/Pages/EngineSettingsPage.swift",
            "Sources/Info.plist",
        ]

        for relativePath in paths {
            let source = try String(
                contentsOf: iosRoot.appendingPathComponent(relativePath),
                encoding: .utf8
            ).lowercased()
            #expect(!source.contains("transcription"), "Fixed transcription leaked into \(relativePath)")
            #expect(!source.contains("microphone"), "Fixed microphone capture leaked into \(relativePath)")
            #expect(!source.contains("onmictap"), "Fixed microphone action leaked into \(relativePath)")
        }
    }
}
