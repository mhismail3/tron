import Testing
import Foundation

extension SourceGuardTests {
    @Test("iOS sources use HRA feature-owned hierarchy")
    func testIOSSourcesUseHRAFeatureOwnedHierarchy() throws {
        let iosRoot = iosAppRoot()
        let bannedBuckets = [
            "Sources/UI/Views": "HRA-11 replaces the broad view bucket with UI/Chat, UI/WorkerConsole, UI/Settings, UI/Onboarding, UI/Capabilities, UI/Components, UI/System, and UI/Theme owners.",
            "Sources/Engine/Network": "HRA-9 replaces the network bucket with Engine/Transport/WebSocket, Clients, Retry, and DeepLinks owners.",
            "Sources/Engine/Database": "HRA-9 reconciles database code under Engine/Persistence/SQLite and Repositories.",
            "Sources/Engine/EventStore": "HRA-9 reconciles event-store sync under Engine/Persistence/Sync and Repositories.",
            "Sources/Session/ViewModels/Managers": "HRA-10 moves manager files to chat coordinators, messaging, navigation, activity, or state owners.",
            "Sources/Session/ViewModels/Utilities": "HRA-10 moves message lookup helpers to Session/Chat/Navigation.",
            "Sources/Support/Concurrency": "HRA-12 moves concurrency primitives under Support/Foundation/Concurrency.",
            "Sources/Support/DependencyInjection": "HRA-12 moves dependency assembly under Support/Composition.",
            "Sources/Support/Diagnostics/Services": "HRA-12 flattens diagnostics services under Support/Diagnostics.",
            "Sources/Support/Feedback": "single-file feedback ownership is represented by Support/FeedbackComposer.swift.",
            "Sources/Support/Share": "single-file share ownership is represented by Support/SharedContent.swift.",
            "Sources/UI/RuntimeSurfaces": "runtime-generated UI does not own a product source root.",
            "Sources/Support/Utilities": "HRA-12 splits utilities into scoped Support/Foundation concerns.",
            "Sources/Support/Extensions": "HRA-12 splits extensions into scoped Support/Foundation/SwiftUI or parsing/formatting concerns.",
            "Sources/Support/Infrastructure": "HRA-12 moves infrastructure services to diagnostics or foundation owners.",
            "Sources/Support/Observability": "HRA-12 merges observability helpers under Support/Diagnostics.",
            "Sources/Support/Settings": "HRA-12 moves paired-server settings storage under Support/Pairing.",
            "Sources/Support/Storage/Services": "HRA-12 flattens storage service files under Support/Storage.",
        ]
        let requiredRoots = [
            "Sources/App/Lifecycle",
            "Sources/Engine/Transport",
            "Sources/Engine/Protocol",
            "Sources/Engine/Events",
            "Sources/Engine/Persistence",
            "Sources/Session/Chat",
            "Sources/Session/Timeline",
            "Sources/UI/Chat",
            "Sources/UI/Settings",
            "Sources/UI/Onboarding",
            "Sources/Support/Composition",
            "Sources/Support/Foundation",
            "Sources/Support/Diagnostics",
            "Sources/Support/Pairing",
            "Sources/Support/Storage",
        ]

        let presentBanned = bannedBuckets.keys
            .sorted()
            .filter { directoryExists(iosRoot.appendingPathComponent($0)) }
        let missingRequired = requiredRoots
            .filter { !directoryExists(iosRoot.appendingPathComponent($0)) }

        #expect(
            presentBanned.isEmpty && missingRequired.isEmpty,
            "HRA iOS source hierarchy is still loose. Present banned buckets: \(presentBanned.map { "\($0): \(bannedBuckets[$0] ?? "")" }); missing target roots: \(missingRequired)"
        )
    }


    @Test("iOS Engine uses HRA target hierarchy")
    func testIOSEngineUsesHRATargetHierarchy() throws {
        let iosRoot = iosAppRoot()
        let requiredRoots = [
            "Sources/Engine/Transport/WebSocket",
            "Sources/Engine/Transport/Clients",
            "Sources/Engine/Transport/Retry",
            "Sources/Engine/Protocol/Core",
            "Sources/Engine/Events/Live",
            "Sources/Engine/Events/Payloads",
            "Sources/Engine/Events/Plugins",
            "Sources/Engine/Events/Reconstruction",
            "Sources/Engine/Events/Reconstruction/ChatMessageProjection",
            "Sources/Engine/Persistence/SQLite",
            "Sources/Engine/Persistence/Repositories",
            "Sources/Engine/Persistence/Sync",
        ]
        let bannedRoots = [
            "Sources/Engine/Network",
            "Sources/Engine/Database",
            "Sources/Engine/EventStore",
            "Sources/Engine/Protocol/DTOs",
            "Sources/Engine/Protocols",
            "Sources/Engine/Repositories",
            "Sources/Engine/Events/Core",
            "Sources/Engine/Events/Types",
            "Sources/Engine/Events/Reconstruction/Handlers",
            "Sources/Engine/Transport/DeepLinks",
            "Sources/Engine/Transport/WebSocket/Protocols",
            "Sources/Engine/Persistence/SQLite/Schema",
        ]
        let requiredFlatFiles = [
            "Sources/Engine/ModelFilteringService.swift",
            "Sources/Engine/Persistence/SQLite/DatabaseSchema.swift",
            "Sources/Engine/Transport/DeepLinkRouter.swift",
            "Sources/Engine/Transport/WebSocket/EngineTransport.swift",
            "Sources/Engine/Protocol/EngineProtocolTypes+Agent.swift",
            "Sources/Engine/Protocol/EngineProtocolTypes+Auth.swift",
            "Sources/Engine/Protocol/EngineProtocolTypes+Catalog.swift",
            "Sources/Engine/Protocol/EngineProtocolTypes+Events.swift",
            "Sources/Engine/Protocol/EngineProtocolTypes+Filesystem.swift",
            "Sources/Engine/Protocol/EngineProtocolTypes+Interaction.swift",
            "Sources/Engine/Protocol/EngineProtocolTypes+Model.swift",
            "Sources/Engine/Protocol/EngineProtocolTypes+Reconstruct.swift",
            "Sources/Engine/Protocol/EngineProtocolTypes+Session.swift",
            "Sources/Engine/Protocol/EngineProtocolTypes+Settings.swift",
            "Sources/Engine/Protocol/EngineProtocolTypes+System.swift",
            "Sources/Engine/Protocol/EngineProtocolTypes+WorkerKernel.swift",
        ]
        let connectionFiles = [
            "Sources/Engine/Transport/WebSocket/EngineConnection.swift",
            "Sources/Engine/Transport/WebSocket/EngineConnection+Requests.swift",
            "Sources/Engine/Transport/WebSocket/EngineConnection+Receiving.swift",
            "Sources/Engine/Transport/WebSocket/EngineConnection+Reconnect.swift",
            "Sources/Engine/Transport/WebSocket/EngineConnectionProtocolFrames.swift",
            "Sources/Engine/Transport/WebSocket/EngineConnectionTypes.swift",
        ]

        let missingRequired = requiredRoots
            .filter { !directoryExists(iosRoot.appendingPathComponent($0)) }
        let presentBanned = bannedRoots
            .filter { directoryExists(iosRoot.appendingPathComponent($0)) }
        let missingConnectionFiles = connectionFiles
            .filter { !FileManager.default.fileExists(atPath: iosRoot.appendingPathComponent($0).path) }
        let missingFlatFiles = requiredFlatFiles
            .filter { !FileManager.default.fileExists(atPath: iosRoot.appendingPathComponent($0).path) }

        #expect(
            missingRequired.isEmpty && presentBanned.isEmpty && missingConnectionFiles.isEmpty && missingFlatFiles.isEmpty,
            "HRA-9 Engine hierarchy drift. Missing roots: \(missingRequired); disallowed roots present: \(presentBanned); missing split files: \(missingConnectionFiles); missing single-file owners: \(missingFlatFiles)"
        )
    }

    @Test("iOS Engine transport tests mirror WebSocket owners")
    func testIOSEngineTransportTestsMirrorWebSocketOwners() throws {
        let iosRoot = iosAppRoot()
        let required = [
            "Tests/Engine/Transport/WebSocket",
            "Tests/Engine/Transport/WebSocket/EngineConnectionReconnectTests.swift",
        ]
        let banned = [
            "Tests/Engine/Transport/Clients/EngineConnectionReconnectTests.swift",
        ]

        let missing = required
            .filter { !FileManager.default.fileExists(atPath: iosRoot.appendingPathComponent($0).path) }
        let presentBanned = banned
            .filter { FileManager.default.fileExists(atPath: iosRoot.appendingPathComponent($0).path) }

        #expect(
            missing.isEmpty && presentBanned.isEmpty,
            "HRA iOS transport test mirror drift. Missing: \(missing); stale client-path tests: \(presentBanned)"
        )
    }


    @Test("iOS Session uses HRA target hierarchy")
    func testIOSSessionUsesHRATargetHierarchy() throws {
        let iosRoot = iosAppRoot()
        let requiredRoots = [
            "Sources/Session/Attachments",
            "Sources/Session/Chat/ViewModel",
            "Sources/Session/Chat/Coordinators",
            "Sources/Session/Chat/Messaging",
            "Sources/Session/Chat/Navigation",
            "Sources/Session/Chat/State",
            "Sources/Session/Timeline/Activity",
            "Sources/Session/Timeline/Messages",
        ]
        let bannedRoots = [
            "Sources/Session/Activity",
            "Sources/Session/Features",
            "Sources/Session/Messages",
            "Sources/Session/Reconstruction",
            "Sources/Session/Tokens",
            "Sources/Session/ViewModels",
            "Sources/Session/Parsing",
            "Sources/Session/Timeline/Reconstruction",
            "Sources/Session/Timeline/Tokens",
        ]
        let splitDisplayModelFiles = [
            "Sources/Session/Timeline/Messages/CapabilityInvocationDisplayModel.swift",
            "Sources/Session/Timeline/Messages/CapabilityInvocationDisplayModel+PresentationHelpers.swift",
            "Sources/Session/CapabilityArgumentParser.swift",
            "Sources/Session/Timeline/UnifiedEventTransformer.swift",
            "Sources/Session/Timeline/TokenRecord.swift",
        ]

        let missingRequired = requiredRoots
            .filter { !directoryExists(iosRoot.appendingPathComponent($0)) }
        let presentBanned = bannedRoots
            .filter { directoryExists(iosRoot.appendingPathComponent($0)) }
        let missingSplitFiles = splitDisplayModelFiles
            .filter { !FileManager.default.fileExists(atPath: iosRoot.appendingPathComponent($0).path) }
        let oversizedSplitFiles = try splitDisplayModelFiles.compactMap { relativePath -> String? in
            let lineCount = try sourceLineCount(iosRoot.appendingPathComponent(relativePath))
            return lineCount > 700 ? "\(relativePath) has \(lineCount) LOC" : nil
        }

        #expect(
            missingRequired.isEmpty
                && presentBanned.isEmpty
                && missingSplitFiles.isEmpty
                && oversizedSplitFiles.isEmpty,
            "HRA-10 Session hierarchy drift. Missing roots: \(missingRequired); disallowed roots present: \(presentBanned); missing split files: \(missingSplitFiles); oversized split files: \(oversizedSplitFiles)"
        )
    }


    @Test("iOS UI uses HRA target hierarchy")
    func testIOSUIUsesHRATargetHierarchy() throws {
        let iosRoot = iosAppRoot()
        let requiredRoots = [
            "Sources/UI/Capabilities",
            "Sources/UI/Capabilities/Shared",
            "Sources/UI/Chat/Composer",
            "Sources/UI/Chat/Messages",
            "Sources/UI/Chat/Sheets",
            "Sources/UI/Chat/Shell",
            "Sources/UI/Components",
            "Sources/UI/Onboarding/Flow",
            "Sources/UI/Onboarding/Steps",
            "Sources/UI/Settings/ModelPicker",
            "Sources/UI/Settings/Pages",
            "Sources/UI/Settings/Pages/ModelProviders",
            "Sources/UI/Settings/Providers/OAuth",
            "Sources/UI/Settings/Shell",
            "Sources/UI/System",
            "Sources/UI/Theme",
        ]
        let bannedRoots = [
            "Sources/UI/Views",
            "Sources/UI/Capabilities/Thinking",
            "Sources/UI/Chat/Messages/Indicators",
            "Sources/UI/Onboarding/Pairing",
        ]
        let splitUIFiles = [
            "Sources/UI/Settings/Shell/SettingsView.swift",
            "Sources/UI/Settings/Shell/SettingsView+FooterSupport.swift",
            "Sources/UI/Capabilities/ThinkingDetailSheet.swift",
            "Sources/UI/Chat/Messages/NeuralSparkIndicator.swift",
            "Sources/UI/Onboarding/QRCodeScannerSheet.swift",
        ]

        let missingRequired = requiredRoots
            .filter { !directoryExists(iosRoot.appendingPathComponent($0)) }
        let presentBanned = bannedRoots
            .filter { directoryExists(iosRoot.appendingPathComponent($0)) }
        let missingSplitFiles = splitUIFiles
            .filter { !FileManager.default.fileExists(atPath: iosRoot.appendingPathComponent($0).path) }
        let oversizedSplitFiles = try splitUIFiles.compactMap { relativePath -> String? in
            let lineCount = try sourceLineCount(iosRoot.appendingPathComponent(relativePath))
            return lineCount > 700 ? "\(relativePath) has \(lineCount) LOC" : nil
        }

        #expect(
            missingRequired.isEmpty
                && presentBanned.isEmpty
                && missingSplitFiles.isEmpty
                && oversizedSplitFiles.isEmpty,
            "HRA-11 UI hierarchy drift. Missing roots: \(missingRequired); disallowed roots present: \(presentBanned); missing split files: \(missingSplitFiles); oversized split files: \(oversizedSplitFiles)"
        )
    }


    @Test("iOS Support uses HRA target hierarchy")
    func testIOSSupportUsesHRATargetHierarchy() throws {
        let iosRoot = iosAppRoot()
        let requiredRoots = [
            "Sources/App/Lifecycle",
            "Sources/Support/Composition",
            "Sources/Support/Diagnostics",
            "Sources/Support/Foundation",
            "Sources/Support/Foundation/Concurrency",
            "Sources/Support/Foundation/Formatting",
            "Sources/Support/Foundation/Parsing",
            "Sources/Support/Foundation/SwiftUI",
            "Sources/Support/Pairing",
            "Sources/Support/Pairing/Onboarding",
            "Sources/Support/Storage",
        ]
        let bannedRoots = [
            "Sources/Support/Concurrency",
            "Sources/Support/DependencyInjection",
            "Sources/Support/Diagnostics/Services",
            "Sources/Support/Extensions",
            "Sources/Support/Infrastructure",
            "Sources/Support/Observability",
            "Sources/Support/Settings",
            "Sources/Support/Storage/Services",
            "Sources/Support/Utilities",
            "Sources/Support/Feedback",
            "Sources/Support/Foundation/Media",
            "Sources/Support/Foundation/Validation",
            "Sources/Support/Share",
        ]
        let requiredFiles = [
            "Sources/App/Lifecycle/AppDelegate.swift",
            "Sources/App/Lifecycle/AppRuntimeMode.swift",
            "Sources/App/Lifecycle/ProductionAppRoot.swift",
            "Sources/App/Lifecycle/TronMobileApp.swift",
            "Sources/Support/Composition/AppInitializer.swift",
            "Sources/Support/Composition/DependencyContainer+RuntimeServices.swift",
            "Sources/Support/Composition/DependencyContainer.swift",
            "Sources/Support/Composition/DependencyContainerStorage.swift",
            "Sources/Support/Composition/DependencyEnvironment.swift",
            "Sources/Support/Diagnostics/ClientLogIngestionService.swift",
            "Sources/Support/Diagnostics/DiagnosticsBundleBuilder.swift",
            "Sources/Support/Diagnostics/DiagnosticsRedactor.swift",
            "Sources/Support/Diagnostics/ErrorHandler.swift",
            "Sources/Support/Diagnostics/MetricKitDiagnosticsStore.swift",
            "Sources/Support/Diagnostics/TronLogger.swift",
            "Sources/Support/Foundation/AppConstants.swift",
            "Sources/Support/Foundation/Concurrency/AsyncSemaphore.swift",
            "Sources/Support/Foundation/Formatting/Date+Extensions.swift",
            "Sources/Support/Foundation/Formatting/DurationFormatter.swift",
            "Sources/Support/Foundation/Formatting/ModelNameFormatter.swift",
            "Sources/Support/Foundation/Formatting/String+Extensions.swift",
            "Sources/Support/Foundation/Formatting/TaskFormatting.swift",
            "Sources/Support/Foundation/Formatting/TokenFormatter.swift",
            "Sources/Support/Foundation/Formatting/VersionDisplay.swift",
            "Sources/Support/Foundation/ImageProcessor.swift",
            "Sources/Support/Foundation/Parsing/ContentLineParser.swift",
            "Sources/Support/Foundation/Parsing/DateParser.swift",
            "Sources/Support/Foundation/SwiftUI/Binding+PasteAware.swift",
            "Sources/Support/Foundation/SwiftUI/KeyboardObserver.swift",
            "Sources/Support/Foundation/SwiftUI/ToastCenter.swift",
            "Sources/Support/Foundation/SwiftUI/View+Accessibility.swift",
            "Sources/Support/Foundation/SwiftUI/View+Extensions.swift",
            "Sources/Support/Foundation/FolderNameValidator.swift",
            "Sources/Support/Pairing/PairedServerStore.swift",
            "Sources/Support/FeedbackComposer.swift",
            "Sources/Support/SharedContent.swift",
            "Sources/Support/Storage/DraftStore.swift",
            "Sources/Support/Storage/InputHistoryStore.swift",
            "Sources/Support/Storage/KeychainItem.swift",
            "Sources/Support/Storage/PairedServerTokenStore.swift",
        ]
        let bannedFiles = [
            "Sources/App/AppDelegate.swift",
            "Sources/App/TronMobileApp.swift",
            "Sources/Support/AppConstants.swift",
        ]

        let missingRequired = requiredRoots
            .filter { !directoryExists(iosRoot.appendingPathComponent($0)) }
        let presentBanned = bannedRoots
            .filter { directoryExists(iosRoot.appendingPathComponent($0)) }
        let missingFiles = requiredFiles
            .filter { !FileManager.default.fileExists(atPath: iosRoot.appendingPathComponent($0).path) }
        let presentBannedFiles = bannedFiles
            .filter { FileManager.default.fileExists(atPath: iosRoot.appendingPathComponent($0).path) }

        #expect(
            missingRequired.isEmpty
                && presentBanned.isEmpty
                && missingFiles.isEmpty
                && presentBannedFiles.isEmpty,
            "HRA-12 Support hierarchy drift. Missing roots: \(missingRequired); disallowed roots present: \(presentBanned); missing files: \(missingFiles); disallowed files present: \(presentBannedFiles)"
        )
    }


    @Test("iOS tests mirror HRA source boundaries")
    func testIOSTestsMirrorHRASourceBoundaries() throws {
        let iosRoot = iosAppRoot()
        let requiredRoots = [
            "Tests/Infrastructure",
            "Tests/Engine",
            "Tests/Session",
            "Tests/UI",
            "Tests/Support",
        ]
        let bannedRoots = [
            "Tests/Core",
            "Tests/Extensions",
            "Tests/Models",
            "Tests/Navigation",
            "Tests/Observability",
            "Tests/Onboarding",
            "Tests/Repositories",
            "Tests/Services",
            "Tests/Theme",
            "Tests/Utilities",
            "Tests/ViewModels",
            "Tests/Views",
            "Tests/Engine/Models",
            "Tests/Engine/Transport/DeepLinks",
            "Tests/Session/Parsing",
            "Tests/Support/Feedback",
            "Tests/Support/Foundation/Concurrency",
            "Tests/Support/Foundation/Validation",
            "Tests/UI/RuntimeSurfaces",
            "Tests/UI/WorkerConsole",
        ]
        let requiredFiles = [
            "Tests/Infrastructure/AppLifecycle/AppDelegateTests.swift",
            "Tests/Infrastructure/AppLifecycle/AppRuntimeModeTests.swift",
            "Tests/Infrastructure/Fixtures/HostedTestLifecycle.swift",
            "Tests/Infrastructure/Fixtures/IsolatedTestState.swift",
            "Tests/Infrastructure/Fixtures/IsolatedTestStateTests.swift",
            "Tests/Engine/ModelFilteringServiceTests.swift",
            "Tests/Engine/Transport/DeepLinkRouterTests.swift",
            "Tests/Session/CapabilityArgumentParserTests.swift",
            "Tests/Support/FeedbackComposerTests.swift",
            "Tests/Support/Foundation/AsyncSemaphoreTests.swift",
            "Tests/Support/Foundation/FolderCreationTests.swift",
        ]

        let missingRequired = requiredRoots
            .filter { !directoryExists(iosRoot.appendingPathComponent($0)) }
        let presentBanned = bannedRoots
            .filter { directoryExists(iosRoot.appendingPathComponent($0)) }
        let missingFiles = requiredFiles
            .filter { !FileManager.default.fileExists(atPath: iosRoot.appendingPathComponent($0).path) }

        #expect(
            missingRequired.isEmpty && presentBanned.isEmpty && missingFiles.isEmpty,
            "HRA iOS tests must mirror production owners. Missing target roots: \(missingRequired); missing owner files: \(missingFiles); disallowed technical buckets present: \(presentBanned)"
        )
    }


    @Test("XcodeGen keeps recursive iOS target membership")
    func testXcodeGenKeepsRecursiveIOSTargetMembership() throws {
        let iosRoot = iosAppRoot()
        let project = try String(
            contentsOf: iosRoot.appendingPathComponent("project.yml"),
            encoding: .utf8
        )

        #expect(project.contains("- path: Sources\n        createIntermediateGroups: true"))
        #expect(project.contains("- path: Tests\n        createIntermediateGroups: true"))
        #expect(project.contains("- path: ShareExtension"))
        #expect(project.contains("- path: Sources/Support/SharedContent.swift"))
        #expect(project.contains("generateEmptyDirectories: false"))
        #expect(project.contains("createIntermediateGroups: true"))
    }
}
