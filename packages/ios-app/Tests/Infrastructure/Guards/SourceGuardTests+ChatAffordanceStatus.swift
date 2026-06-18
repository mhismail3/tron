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

    @Test("Chat shell does not mount passive agent cockpit")
    func testChatShellDoesNotMountPassiveAgentCockpit() throws {
        let iosRoot = iosAppRoot()
        let chatSources = [
            "Sources/UI/Chat/Shell/ChatView.swift",
            "Sources/UI/Chat/Shell/ChatSheetContent.swift",
            "Sources/UI/Chat/Shell/ChatSheetModifier.swift",
            "Sources/Session/Chat/Coordinators/SheetCoordinator.swift",
            "Sources/Session/Chat/State/ChatSheet.swift",
        ]

        for path in chatSources {
            let source = try String(contentsOf: iosRoot.appendingPathComponent(path), encoding: .utf8)
            #expect(!source.contains("AgentStatusCapsuleView"))
            #expect(!source.contains("AgentCockpitViewModel()"))
            #expect(!source.contains("showAgentCockpit"))
            #expect(!source.contains("agentCockpit.refresh"))
            #expect(!source.contains("case agentCockpit"))
        }

        let cockpitViews = try String(
            contentsOf: iosRoot.appendingPathComponent("Sources/UI/AgentCockpit/AgentCockpitViews.swift"),
            encoding: .utf8
        )
        #expect(cockpitViews.contains("struct AgentCockpitSheet"))
        #expect(!cockpitViews.contains("struct AgentStatusCapsuleView"))
        #expect(cockpitViews.contains(#"SheetTitle(title: "Runtime Cockpit", color: .tronEmerald)"#))
        #expect(cockpitViews.contains("SheetDismissButton(color: .tronEmerald)"))
        #expect(cockpitViews.contains("TronSegmentedControl("))
        #expect(!cockpitViews.contains(#"Picker("Cockpit""#))
        #expect(cockpitViews.contains(".adaptivePresentationDetents([.medium, .large], ipadSizing: .largeForm)"))

        let serverSettings = try String(
            contentsOf: iosRoot.appendingPathComponent("Sources/UI/Settings/Pages/ConnectionSettingsPage.swift"),
            encoding: .utf8
        )
        #expect(serverSettings.contains("ConnectionSettingsDiagnosticsSheet"))
        #expect(serverSettings.contains("AgentCockpitSheet("))
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
