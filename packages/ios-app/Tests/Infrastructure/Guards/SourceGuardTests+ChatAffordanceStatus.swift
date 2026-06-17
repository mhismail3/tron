import Testing
import Foundation

extension SourceGuardTests {
    @Test("Chat timeline does not mount connection status pill")
    func testChatTimelineDoesNotMountConnectionStatusPill() throws {
        let iosRoot = iosAppRoot()
        let chatSources = [
            "Sources/UI/Chat/Shell/ChatView+MessageList.swift",
            "Sources/UI/Chat/Shell/ChatView.swift",
        ]

        for path in chatSources {
            let source = try String(contentsOf: iosRoot.appendingPathComponent(path), encoding: .utf8)
            #expect(!source.contains("ConnectionStatusPill"))
        }
        #expect(!FileManager.default.fileExists(atPath: iosRoot.appendingPathComponent("Sources/UI/Components/ConnectionStatusPill.swift").path))
    }

    @Test("Thinking indicator is app-owned Neural Spark only")
    func testThinkingIndicatorIsNeuralSparkOnly() throws {
        let iosRoot = iosAppRoot()
        let source = try String(
            contentsOf: iosRoot.appendingPathComponent("Sources/UI/Chat/Shell/ThinkingIndicator.swift"),
            encoding: .utf8
        )

        #expect(source.contains("NeuralSparkIndicator()"))
        #expect(!source.contains("AppearanceSettings"))
        #expect(!FileManager.default.fileExists(atPath: iosRoot.appendingPathComponent("Sources/UI/Theme/ThinkingIndicatorStyle.swift").path))
        #expect(!FileManager.default.fileExists(atPath: iosRoot.appendingPathComponent("Sources/UI/Chat/Messages/Indicators/PhaseWaveIndicator.swift").path))
        #expect(!FileManager.default.fileExists(atPath: iosRoot.appendingPathComponent("Sources/UI/Chat/Messages/Indicators/OrbitingParticleIndicator.swift").path))
    }

    @Test("Chat scoped errors do not use generic alert surface")
    func testChatScopedErrorsAvoidGenericAlertSurface() throws {
        let iosRoot = iosAppRoot()
        let chatView = try String(
            contentsOf: iosRoot.appendingPathComponent("Sources/UI/Chat/Shell/ChatView.swift"),
            encoding: .utf8
        )
        let errorPath = "Sources/Session/Chat/ViewModel/ChatViewModel+Errors.swift"
        let errorRouting = try String(
            contentsOf: iosRoot.appendingPathComponent(errorPath),
            encoding: .utf8
        )

        #expect(!chatView.contains(#".alert("Error""#))
        #expect(errorRouting.contains("appendLocalError"))
        #expect(errorRouting.contains("LocalChatNotification.error"))
    }
}
