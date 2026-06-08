import Testing
import Foundation

extension SourceGuardTests {

    @Test("Primitive shell has no fixed product modes")
    func testPrimitiveShellHasNoFixedProductModes() throws {
        let iosRoot = iosAppRoot()
        let sourcesRoot = iosRoot.appendingPathComponent("Sources")
        let uiRoot = sourcesRoot.appendingPathComponent("UI")

        let removedViewRoots = [
            "Agent" + "Control",
            "Audit" + "Details",
            "Prompt" + "Library",
            "Skills",
            "Source" + "Changes",
            "Sub" + "agents",
            "Voice" + "Notes",
            "Work",
        ]
        for rootName in removedViewRoots {
            #expect(
                !FileManager.default.fileExists(atPath: uiRoot.appendingPathComponent(rootName).path),
                "\(rootName) is a fixed product UI root; primitive iOS must render only the chat shell and generic runtime surfaces"
            )
        }

        let requiredShellFiles = [
            "UI/Chat/Shell/ContentView.swift",
            "UI/Chat/Shell/ChatView.swift",
            "UI/Chat/Composer/InputBar.swift",
            "UI/Settings/Shell/SettingsView.swift",
            "UI/RuntimeSurfaces/GeneratedRuntimeSurfaceView.swift",
        ]
        for relativePath in requiredShellFiles {
            #expect(
                FileManager.default.fileExists(atPath: sourcesRoot.appendingPathComponent(relativePath).path),
                "\(relativePath) is part of the retained primitive shell"
            )
        }

        let forbiddenNeedles: [(String, String)] = [
            ("Navigation" + "Mode" + "." + "work", "fixed Work navigation"),
            ("case " + "work\n", "fixed Work navigation enum case"),
            ("case " + "work,", "fixed Work navigation enum case"),
            ("case " + "work:", "fixed Work navigation enum case"),
            ("show" + "Agent" + "Control", "retired agent sheet presenter"),
            ("Agent" + "Control" + "View", "retired agent product sheet"),
            ("Work" + "Dash" + "board" + "View", "fixed Work session list"),
            ("Audit" + "Details" + "View", "retired fixed audit console"),
            ("Source" + "Control" + "Sheet", "retired fixed repository sheet"),
            ("Prompt" + "Library" + "Sheet", "fixed prompt picker"),
            ("Skill" + "Detail" + "Sheet", "fixed Skills sheet"),
            ("Mention" + "Popup", "fixed Skills picker"),
            ("Floating" + "Voice" + "Notes" + "Button", "retired fixed audio UI"),
            ("Voice" + "Notes" + "Recording" + "Sheet", "retired fixed audio UI"),
            ("Sub" + "agent" + "Detail" + "Sheet", "fixed worker UI"),
            ("Sub" + "agent" + "Results" + "List" + "Sheet", "fixed worker UI"),
            ("Capability" + "Client", "capability catalog/operator client"),
            ("agent::" + "work_snapshot", "server-owned Work projection"),
        ]

        guard let enumerator = FileManager.default.enumerator(
            at: sourcesRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            Issue.record("Could not enumerate \(sourcesRoot.path)")
            return
        }

        while let any = enumerator.nextObject() {
            guard let url = any as? URL else { continue }
            guard url.pathExtension == "swift" else { continue }

            let content = try String(contentsOf: url, encoding: .utf8)
            for (needle, reason) in forbiddenNeedles {
                #expect(
                    !content.contains(needle),
                    "\(url.path) contains \(reason): `\(needle)`"
                )
            }
        }
    }


    @Test("iOS sources use HRA feature-owned hierarchy")
    func testIOSSourcesUseHRAFeatureOwnedHierarchy() throws {
        let iosRoot = iosAppRoot()
        let bannedBuckets = [
            "Sources/UI/Views": "HRA-11 replaces the broad view bucket with UI/Chat, UI/Settings, UI/Onboarding, UI/RuntimeSurfaces, UI/Capabilities, UI/Components, UI/System, and UI/Theme owners.",
            "Sources/Engine/Network": "HRA-9 replaces the network bucket with Engine/Transport/WebSocket, Clients, Retry, and DeepLinks owners.",
            "Sources/Engine/Database": "HRA-9 reconciles database code under Engine/Persistence/SQLite and Repositories.",
            "Sources/Engine/EventStore": "HRA-9 reconciles event-store sync under Engine/Persistence/Sync and Repositories.",
            "Sources/Session/ViewModels/Managers": "HRA-10 moves manager files to chat coordinators, messaging, navigation, activity, or state owners.",
            "Sources/Session/ViewModels/Utilities": "HRA-10 moves message lookup helpers to Session/Chat/Navigation.",
            "Sources/Support/Concurrency": "HRA-12 moves concurrency primitives under Support/Foundation/Concurrency.",
            "Sources/Support/DependencyInjection": "HRA-12 moves dependency assembly under Support/Composition.",
            "Sources/Support/Diagnostics/Services": "HRA-12 flattens diagnostics services under Support/Diagnostics.",
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
            "Sources/UI/RuntimeSurfaces",
            "Sources/Support/Composition",
            "Sources/Support/Foundation",
            "Sources/Support/Diagnostics",
            "Sources/Support/Pairing",
            "Sources/Support/Storage",
            "Sources/Support/Feedback",
            "Sources/Support/Share",
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
            "Sources/Engine/Transport/DeepLinks",
            "Sources/Engine/Protocol/Core",
            "Sources/Engine/Protocol/Agent",
            "Sources/Engine/Protocol/Session",
            "Sources/Engine/Events/Live",
            "Sources/Engine/Events/Payloads",
            "Sources/Engine/Events/Plugins",
            "Sources/Engine/Events/Reconstruction",
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

        #expect(
            missingRequired.isEmpty && presentBanned.isEmpty && missingConnectionFiles.isEmpty,
            "HRA-9 Engine hierarchy drift. Missing roots: \(missingRequired); old roots present: \(presentBanned); missing split files: \(missingConnectionFiles)"
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
            "Sources/Session/Parsing",
            "Sources/Session/Timeline/Activity",
            "Sources/Session/Timeline/Messages",
            "Sources/Session/Timeline/Reconstruction",
            "Sources/Session/Timeline/Tokens",
        ]
        let bannedRoots = [
            "Sources/Session/Activity",
            "Sources/Session/Features",
            "Sources/Session/Messages",
            "Sources/Session/Reconstruction",
            "Sources/Session/Tokens",
            "Sources/Session/ViewModels",
        ]
        let splitDisplayModelFiles = [
            "Sources/Session/Timeline/Messages/CapabilityInvocationDisplayModel.swift",
            "Sources/Session/Timeline/Messages/CapabilityInvocationDisplayModel+PresentationHelpers.swift",
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
            "HRA-10 Session hierarchy drift. Missing roots: \(missingRequired); old roots present: \(presentBanned); missing split files: \(missingSplitFiles); oversized split files: \(oversizedSplitFiles)"
        )
    }


    @Test("iOS UI uses HRA target hierarchy")
    func testIOSUIUsesHRATargetHierarchy() throws {
        let iosRoot = iosAppRoot()
        let requiredRoots = [
            "Sources/UI/Capabilities",
            "Sources/UI/Capabilities/Shared",
            "Sources/UI/Capabilities/Thinking",
            "Sources/UI/Chat/Composer",
            "Sources/UI/Chat/Messages",
            "Sources/UI/Chat/Messages/Indicators",
            "Sources/UI/Chat/Sheets",
            "Sources/UI/Chat/Shell",
            "Sources/UI/Components",
            "Sources/UI/Onboarding/Flow",
            "Sources/UI/Onboarding/Pairing",
            "Sources/UI/Onboarding/Steps",
            "Sources/UI/RuntimeSurfaces",
            "Sources/UI/RuntimeSurfaces/Display",
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
        ]
        let splitUIFiles = [
            "Sources/UI/RuntimeSurfaces/GeneratedRuntimeSurfaceView.swift",
            "Sources/UI/RuntimeSurfaces/GeneratedRuntimeSurfaceView+Support.swift",
            "Sources/UI/Settings/Shell/SettingsView.swift",
            "Sources/UI/Settings/Shell/SettingsView+FooterSupport.swift",
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
            "HRA-11 UI hierarchy drift. Missing roots: \(missingRequired); old roots present: \(presentBanned); missing split files: \(missingSplitFiles); oversized split files: \(oversizedSplitFiles)"
        )
    }


    @Test("iOS Support uses HRA target hierarchy")
    func testIOSSupportUsesHRATargetHierarchy() throws {
        let iosRoot = iosAppRoot()
        let requiredRoots = [
            "Sources/App/Lifecycle",
            "Sources/Support/Composition",
            "Sources/Support/Diagnostics",
            "Sources/Support/Feedback",
            "Sources/Support/Foundation",
            "Sources/Support/Foundation/Concurrency",
            "Sources/Support/Foundation/Formatting",
            "Sources/Support/Foundation/Media",
            "Sources/Support/Foundation/Parsing",
            "Sources/Support/Foundation/SwiftUI",
            "Sources/Support/Foundation/Validation",
            "Sources/Support/Pairing",
            "Sources/Support/Pairing/Onboarding",
            "Sources/Support/Share",
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
        ]
        let requiredFiles = [
            "Sources/App/Lifecycle/AppDelegate.swift",
            "Sources/App/Lifecycle/TronMobileApp.swift",
            "Sources/Support/Composition/AppInitializer.swift",
            "Sources/Support/Composition/DependencyContainer.swift",
            "Sources/Support/Composition/DependencyEnvironment.swift",
            "Sources/Support/Composition/DependencyProviding.swift",
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
            "Sources/Support/Foundation/Media/ImageProcessor.swift",
            "Sources/Support/Foundation/Parsing/ContentLineParser.swift",
            "Sources/Support/Foundation/Parsing/DateParser.swift",
            "Sources/Support/Foundation/SwiftUI/Binding+PasteAware.swift",
            "Sources/Support/Foundation/SwiftUI/KeyboardObserver.swift",
            "Sources/Support/Foundation/SwiftUI/ToastCenter.swift",
            "Sources/Support/Foundation/SwiftUI/View+Accessibility.swift",
            "Sources/Support/Foundation/SwiftUI/View+Extensions.swift",
            "Sources/Support/Foundation/Validation/FolderNameValidator.swift",
            "Sources/Support/Pairing/PairedServerStore.swift",
            "Sources/Support/Share/SharedContent.swift",
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
            "HRA-12 Support hierarchy drift. Missing roots: \(missingRequired); old roots present: \(presentBanned); missing files: \(missingFiles); old files present: \(presentBannedFiles)"
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
        ]

        let missingRequired = requiredRoots
            .filter { !directoryExists(iosRoot.appendingPathComponent($0)) }
        let presentBanned = bannedRoots
            .filter { directoryExists(iosRoot.appendingPathComponent($0)) }

        #expect(
            missingRequired.isEmpty && presentBanned.isEmpty,
            "HRA iOS tests must mirror production owners. Missing target roots: \(missingRequired); old technical buckets still present: \(presentBanned)"
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
        #expect(project.contains("- path: Sources/Support/Share/SharedContent.swift"))
        #expect(project.contains("generateEmptyDirectories: true"))
        #expect(project.contains("createIntermediateGroups: true"))
    }
}
