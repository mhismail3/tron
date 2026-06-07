import Testing
import Foundation

/// Regression guard: iOS source code and tests must contain no hardcoded
/// personal-info literals. User identity belongs in `MEMORY.md` on the server
/// (auto-injected into every session's context via the `memory.content` engine protocol
/// field); the iOS client never needs to encode it in code.
///
/// Needles are assembled from substrings so this test file itself doesn't
/// contain them.
@Suite("Source Guards")
struct SourceGuardTests {
    @Test("Dashboard toolbar keeps explicit iPhone icons")
    func testDashboardToolbarKeepsExplicitIPhoneIcons() throws {
        let iosRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let toolbar = try String(
            contentsOf: iosRoot.appendingPathComponent("Sources/Views/Chat/DashboardToolbarContent.swift"),
            encoding: .utf8
        )

        #expect(toolbar.contains(#"Image("TronLogoVector")"#))
        #expect(toolbar.contains(#"Image(systemName: "gearshape")"#))
        #expect(toolbar.contains(#".accessibilityLabel("Show sidebar")"#))
        #expect(toolbar.contains(#".accessibilityLabel("Settings")"#))
        #expect(!toolbar.contains(#"Label("Settings", systemImage:"#))
        #expect(!toolbar.contains(#"Text("Navigation")"#))
    }

    @Test("Message metadata cost is not double-prefixed")
    func testMessageMetadataCostIsNotDoublePrefixed() throws {
        let iosRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let badge = try String(
            contentsOf: iosRoot.appendingPathComponent("Sources/Views/MessageBubble/MessageMetadataBadge.swift"),
            encoding: .utf8
        )

        #expect(badge.contains("Text(record.formattedInput)"))
        #expect(!badge.contains("Text(record.formattedNewInput)"))
        #expect(badge.contains("Text(formatCost(cost.totalCost))"))
        #expect(!badge.contains(#"Image(systemName: "dollarsign")"#))
    }

    @Test("No personal-info literals in iOS Sources or Tests")
    func testNoPersonalInfoLiterals() throws {
        let needles: [String] = [
            "M" + "oh" + "sin",
            "Is" + "ma" + "il",
            "is" + "ma" + "il",
            "mh" + "is" + "mail",
        ]

        let fileURL = URL(fileURLWithPath: #filePath)
        let iosRoot = fileURL
            .deletingLastPathComponent() // Infrastructure/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // ios-app/
        let sourceRoots = [
            iosRoot.appendingPathComponent("Sources"),
            iosRoot.appendingPathComponent("Tests"),
        ]

        for root in sourceRoots {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else {
                Issue.record("Could not enumerate \(root.path)")
                continue
            }
            while let any = enumerator.nextObject() {
                guard let url = any as? URL else { continue }
                guard url.pathExtension == "swift" else { continue }
                // Skip this guard file itself — needle-construction is intentional.
                if url.path == #filePath { continue }

                let content = try String(contentsOf: url, encoding: .utf8)
                for needle in needles {
                    #expect(
                        !content.contains(needle),
                        "\(url.lastPathComponent) contains personal-info literal `\(needle)` - route user info through MEMORY.md on the server"
                    )
                }
            }
        }
    }

    @Test("Removed implementation names do not reappear")
    func testRemovedNamesStayRemoved() throws {
        let forbidden: [String] = [
            "Tele" + "metry" + "Client",
            "Tele" + "metry" + "Event",
            "Token" + "Bucket",
            "Privacy" + "Settings" + "Page",
            "tele" + "metry" + "Enabled" + "Storage" + "Key",
            "Sen" + "try" + "Redactor",
            "Post" + "Hog",
            "Open" + "Tele" + "metry",
            "github" + "Issue" + "Page",
            "open" + "Feedback" + "Issue",
            "Create" + " Issue",
            "Sandbox" + "Client",
            "Sand" + "boxes" + "Dashboard" + "View",
            "Container" + "DTO",
            "Container" + "Action" + "Params",
            "Container" + "Action" + "Result",
            "sandbox" + "::" + "list_" + "containers",
            "sandbox" + "::" + "start_" + "container",
            "sandbox" + "::" + "stop_" + "container",
            "sandbox" + "::" + "kill_" + "container",
            "sandbox" + "::" + "remove_" + "container",
            "Automations" + "Dashboard" + "View",
            "Automation" + "Detail" + "Sheet",
            "Automation" + "Form" + "Sheet",
            "Automation" + "Run" + "Detail" + "Sheet",
            "Voice" + "Notes" + "List" + "View",
            "Safari" + "View",
            "NavigationMode" + "." + "automations",
            "NavigationMode" + "." + "voice" + "Notes",
            "can" + "Manage" + "Automations",
            "Plugin" + "Sources" + "Page",
            "mcp" + "Servers",
            "plugin" + "Sources",
            "mcp" + "Schema" + "Refresh" + "Ttl" + "Ms",
            "Builtin" + "Hook",
            "Agent" + "Hook" + "Setting",
            "User" + "Hook" + "Directory",
            "hooks" + "Llm" + "Model",
            "git" + "Protected" + "Branches",
            "rules" + "Discover" + "Standalone" + "Files",
            "retain" + "Model",
            "auto" + "Retain" + "Interval",
            "trans" + "cription" + "Enabled",
            "Au" + "dio" + "Recorder",
            "Au" + "dio" + "Capture" + "Engine",
            "Media" + "Client",
            "Mem" + "ory" + "Coordinator",
            "Rules" + "Activated" + "Plugin",
            "Mem" + "ory" + "Updated" + "Plugin",
            "memory" + "." + "retained",
            "rules" + "." + "activated",
        ]

        let fileURL = URL(fileURLWithPath: #filePath)
        let iosRoot = fileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceRoots = [
            iosRoot.appendingPathComponent("Sources"),
            iosRoot.appendingPathComponent("Tests"),
        ]

        for root in sourceRoots {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else {
                Issue.record("Could not enumerate \(root.path)")
                continue
            }

            while let any = enumerator.nextObject() {
                guard let url = any as? URL else { continue }
                guard url.pathExtension == "swift" else { continue }
                if url.path == #filePath { continue }

                let content = try String(contentsOf: url, encoding: .utf8)
                for needle in forbidden {
                    #expect(
                        !content.contains(needle),
                        "\(url.lastPathComponent) contains removed diagnostics scaffold `\(needle)`"
                    )
                }
            }
        }
    }

    @Test("Temporary event cache remains projection-only")
    func testFallbackEventCacheRemainsProjectionOnly() throws {
        let forbidden: [(String, String)] = [
            ("target" + "Function" + "Id", "generated UI target construction"),
            ("payload" + "Template", "generated UI payload construction"),
            ("required" + "Grant", "grant construction"),
            ("Authority" + "Grant", "grant policy ownership"),
            ("resource" + "Refs", "resource lineage ownership"),
            ("Resource" + "Ref", "resource lineage ownership"),
        ]

        let fileURL = URL(fileURLWithPath: #filePath)
        let iosRoot = fileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let checkedFiles = [
            iosRoot.appendingPathComponent("Sources/Database/EventDatabase.swift"),
            iosRoot.appendingPathComponent("Sources/Core/DI/DependencyContainer.swift"),
            iosRoot.appendingPathComponent("Sources/Services/Diagnostics/DiagnosticsBundleBuilder.swift"),
        ]

        for url in checkedFiles {
            let content = try String(contentsOf: url, encoding: .utf8)
            #expect(
                content.contains("temporary" + "Cache")
                    || content.contains("Event" + "Database" + "Storage" + "Mode")
                    || content.contains("eventDatabase.storageMode"),
                "\(url.path) should keep temporary cache mode explicit"
            )
            for (needle, reason) in forbidden {
                #expect(
                    !content.contains(needle),
                    "\(url.path) couples temporary event cache mode to \(reason): `\(needle)`"
                )
            }
        }
    }

    @Test("Tron client code uses the engine protocol only")
    func testTronClientTransportIsEngineOnly() throws {
        let forbidden: [(String, String)] = [
            ("R" + "PCClient", "old Tron client type"),
            ("R" + "PCTransport", "old Tron transport type"),
            ("R" + "PCTypes", "old Tron protocol model namespace"),
            ("Mock" + "R" + "PC", "old Tron test mock name"),
            ("rpc" + "Client", "old dependency name"),
            ("send" + "(method:", "old method-string transport API"),
            ("Web" + "SocketService", "old connection type"),
            ("Json" + "RpcEvent", "old event wrapper"),
            ("Json" + "R" + "pc", "old Tron method-string transport spelling"),
            ("/" + "ws", "removed Tron client endpoint"),
        ]

        let fileURL = URL(fileURLWithPath: #filePath)
        let iosRoot = fileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceRoots = [
            iosRoot.appendingPathComponent("Sources"),
            iosRoot.appendingPathComponent("Tests"),
        ]

        for root in sourceRoots {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else {
                Issue.record("Could not enumerate \(root.path)")
                continue
            }

            while let any = enumerator.nextObject() {
                guard let url = any as? URL else { continue }
                guard url.pathExtension == "swift" || url.pathExtension == "md" else { continue }
                if url.path == #filePath { continue }

                let content = try String(contentsOf: url, encoding: .utf8)
                for (needle, reason) in forbidden {
                    #expect(
                        !content.contains(needle),
                        "\(url.path) contains \(reason): `\(needle)`"
                    )
                }
            }
        }
    }

    @Test("Capability-native UI has no legacy active tool models")
    func testCapabilityNativeUIHasNoLegacyActiveToolModels() throws {
        let forbidden: [(String, String)] = [
            ("Tool" + "Descriptor" + "Catalog", "retired descriptor catalog"),
            ("Tool" + "Kind", "retired tool-kind enum"),
            ("Tool" + "Use" + "Data", "retired active invocation model"),
            ("Tool" + "Result" + "Data", "retired active result model"),
            ("Command" + "Tool" + "Chip", "retired command-tool chip"),
            ("Command" + "Tool" + "Status", "retired command-tool status"),
            ("Legacy" + "Tool", "legacy tool compatibility naming"),
            ("Tool" + "Fallback", "tool fallback compatibility naming"),
            ("Compatibility" + "Tool", "tool compatibility naming"),
            ("tool" + "." + "call", "retired tool event type"),
            ("tool" + "." + "result", "retired tool event type"),
            ("tool" + "." + "progress", "retired tool event type"),
            ("error" + "." + "tool", "retired tool error event type"),
            ("tool" + "_" + "start", "retired tool forwarded event type"),
            ("tool" + "_" + "end", "retired tool forwarded event type"),
            ("tool" + "." + "start", "retired tool forwarded event type"),
            ("tool" + "." + "end", "retired tool forwarded event type"),
            ("agent" + "." + "tool" + "_", "retired live stream event prefix"),
            ("tool" + "::" + "result", "retired interaction-response function"),
            ("tool" + "Call" + "Id", "retired invocation identifier spelling"),
            ("model" + "Tool" + "Name", "retired model primitive key spelling"),
            ("model" + "_" + "tool" + "_" + "name", "retired model primitive storage spelling"),
            ("tool" + "_" + "call" + "_" + "id", "retired invocation identifier storage spelling"),
            ("tool" + "_" + "name", "retired capability identity storage spelling"),
            ("tool" + "_" + "calls", "provider protocol payload shape outside protocol boundary"),
            ("tool" + "_" + "use", "provider protocol payload shape outside protocol boundary"),
            ("tool" + "_" + "result", "provider protocol payload shape outside protocol boundary"),
            ("Tool" + "Call", "retired invocation identifier/model spelling"),
            ("tool " + "call", "retired invocation wording"),
            ("tool" + "Start", "retired dashboard activity kind"),
            ("tool" + "End", "retired dashboard activity kind"),
            ("tool" + "Agent", "retired worker spawn-type wire value"),
            ("Tool" + "Agent", "retired worker spawn-type symbol"),
            ("tool" + "Count", "retired analytics capability-count field"),
            ("tool" + "Status", "retired interaction status payload field"),
            ("tool" + "Order", "retired capability metadata ordering key"),
            ("tool" + "Execution" + "Mode", "retired capability metadata execution key"),
            ("tool" + "Schema", "retired capability metadata schema key"),
            ("local" + "Tool" + "Schema", "retired local capability schema key"),
            ("Tool" + "Operation", "retired process kind"),
            ("Tool" + "Color", "retired dashboard color model"),
            ("with" + "Fallback" + "Model" + "Tool" + "Name", "old-name tool identity substitution"),
            ("modelPrimitiveName ?? " + "tool" + "Name", "old-name model primitive substitution"),
            (#"payload["modelPrimitiveName"] as? String ?? payload["# + "tool" + #"Name"]"#, "old-name payload identity substitution"),
            ("CapabilityIdentity(modelPrimitiveName: " + "tool" + "Name", "old-name identity synthesis"),
            ("Tool" + "Payloads", "retired payload file/type naming"),
            ("Tool" + "Handlers", "retired event handler naming"),
            ("Tool" + "Event" + "Coordinator", "retired event coordinator naming"),
            ("Tool" + "Argument" + "Extractor", "retired argument extractor naming"),
            ("MCP" + "Client", "retired MCP source client naming"),
            ("MCP" + "Servers" + "Page", "retired MCP settings page naming"),
            ("Engine" + "Invoke", "retired engine meta-capability naming"),
            ("Mcp" + "Search" + "Capability", "retired plugin source search UI"),
            ("Mcp" + "Call" + "Capability", "retired plugin source call UI"),
            ("Read" + "Capability" + "Detail", "retired first-party detail sheet"),
            ("Bash" + "Capability" + "Detail", "retired first-party detail sheet"),
            ("Write" + "Capability" + "Detail", "retired first-party detail sheet"),
            ("Edit" + "Capability" + "Detail", "retired first-party detail sheet"),
            ("Web" + "Search" + "Capability", "retired web-search capability UI"),
            ("Web" + "Fetch" + "Capability", "retired web-fetch capability UI"),
            ("Display" + "Capability" + "Detail", "retired display capability detail sheet"),
            ("Ask" + "User" + "Question", "retired interaction topology naming"),
            ("ask" + "User" + "Question", "retired interaction topology naming"),
            ("Notify" + "App", "retired notification topology naming"),
            ("Get" + "Confirmation", "retired confirmation topology naming"),
            ("Spawn" + "Sub" + "agent", "retired worker topology naming"),
            ("capability" + "Name == " + #""AskUserQuestion""#, "old-name interaction detection"),
            (#""name": "# + #""AskUserQuestion""#, "old-name interaction fixture identity"),
            (#""name":"# + #""AskUserQuestion""#, "old-name interaction fixture identity"),
            (#""name": AnyCodable("# + #""AskUserQuestion""#, "old-name interaction event identity"),
            ("capability" + "Name: " + #""AskUserQuestion""#, "old-name interaction event identity"),
            (#""modelPrimitiveName": AnyCodable("Read")"#, "retired first-party fixture identity"),
            (#""modelPrimitiveName": AnyCodable("Write")"#, "retired first-party fixture identity"),
            (#""modelPrimitiveName": AnyCodable("Edit")"#, "retired first-party fixture identity"),
            (#""modelPrimitiveName": AnyCodable("Bash")"#, "retired first-party fixture identity"),
            (#""name": AnyCodable("Read")"#, "retired first-party fixture identity"),
            (#""name": AnyCodable("Write")"#, "retired first-party fixture identity"),
            (#""name": AnyCodable("Edit")"#, "retired first-party fixture identity"),
            (#""name": AnyCodable("Bash")"#, "retired first-party fixture identity"),
            ("Read " + "capability arguments", "retired first-party test label"),
            ("Bash " + "capability arguments", "retired first-party test label"),
            ("Web" + "Fetch arguments", "retired first-party test label"),
            ("Web" + "Search arguments", "retired first-party test label"),
            ("Phase 2 " + "Bash", "retired first-party test section"),
            ("Read " + "capability output", "retired first-party comment"),
            (".tool" + "Use(", "retired message content case"),
            (".tool" + "Result(", "retired message content case"),
            ("command" + "Tool" + "Detail", "retired chat sheet route"),
            ("cancel" + "Command" + "Tool", "retired tap action")
        ]

        let fileURL = URL(fileURLWithPath: #filePath)
        let iosRoot = fileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceRoots = [
            iosRoot.appendingPathComponent("Sources"),
            iosRoot.appendingPathComponent("Tests"),
        ]

        for root in sourceRoots {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else {
                Issue.record("Could not enumerate \(root.path)")
                continue
            }

            while let any = enumerator.nextObject() {
                guard let url = any as? URL else { continue }
                guard url.pathExtension == "swift" else { continue }
                if url.path == #filePath { continue }

                let content = try String(contentsOf: url, encoding: .utf8)
                for (needle, reason) in forbidden {
                    #expect(
                        !content.contains(needle),
                        "\(url.path) contains \(reason): `\(needle)`"
                    )
                }
            }
        }
    }

    @Test("Primitive shell has no APNs or device-token client plane")
    func testPrimitiveShellHasNoAPNsOrDeviceTokenClientPlane() throws {
        let fileURL = URL(fileURLWithPath: #filePath)
        let iosRoot = fileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let deletedPaths = [
            "Sources/Services/Notifications/PushNotificationService.swift",
            "Sources/Services/Infrastructure/APNsEnvironment.swift",
            "Tests/Services/PushNotificationServiceTests.swift",
            "Tests/Services/APNsEnvironmentTests.swift",
        ]
        for relativePath in deletedPaths {
            #expect(
                !FileManager.default.fileExists(atPath: iosRoot.appendingPathComponent(relativePath).path),
                "\(relativePath) belongs to the deleted push transport plane"
            )
        }
        for relativePath in [
            "TronMobileBeta.entitlements",
            "TronMobileProd.entitlements",
        ] {
            let entitlement = try String(
                contentsOf: iosRoot.appendingPathComponent(relativePath),
                encoding: .utf8
            )
            #expect(!entitlement.contains("aps-environment"))
        }
        let forbidden = [
            "PushNotificationService",
            "APNsEnvironment",
            "device::register",
            "device::unregister",
            "DeviceTokenRegister",
            "registerForRemoteNotifications",
            "UNUserNotificationCenter",
            "registerPushIfAuthorized",
            "registerDeviceToken",
        ]
        let checkedRoots = [
            iosRoot.appendingPathComponent("Sources"),
            iosRoot.appendingPathComponent("Tests"),
        ]
        for root in checkedRoots {
            for path in try swiftFiles(in: root) {
                if path.lastPathComponent == "SourceGuardTests.swift" {
                    continue
                }
                let source = try String(contentsOf: path, encoding: .utf8)
                for token in forbidden {
                    #expect(!source.contains(token), "\(token) must stay deleted from \(path.path)")
                }
            }
        }
    }

    @Test("Primitive shell has no stale typed domain clients")
    func testPrimitiveShellHasNoStaleTypedDomainClients() throws {
        let iosRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let deletedPaths = [
            "Sources/Services/Network/Clients/ContextClient.swift",
            "Sources/Services/Network/Clients/CronClient.swift",
            "Sources/Services/Network/Clients/DisplayClient.swift",
            "Sources/Services/Network/Clients/FilesystemClient.swift",
            "Sources/Services/Network/Clients/JobClient.swift",
            "Sources/Services/Network/Clients/NotificationClient.swift",
            "Sources/Services/Network/Clients/RepoClient.swift",
            "Sources/Models/EngineProtocol/EngineProtocolTypes+Cron.swift",
            "Sources/Models/EngineProtocol/EngineProtocolTypes+Filesystem.swift",
            "Sources/Models/EngineProtocol/EngineProtocolTypes+Repo.swift",
            "Sources/Models/EngineProtocol/EngineProtocolTypes+Task.swift",
            "Sources/Models/Messages/NotificationDeliveryTypes.swift",
            "Sources/Services/NotificationStore.swift",
            "Sources/ViewModels/State/ContextRefreshGate.swift",
            "Sources/Views/Capabilities/NotificationDelivery",
            "Sources/Views/Notifications",
            "Tests/Models/EngineProtocol/EngineProtocolTypesCronTests.swift",
            "Tests/Services/ContextClientTests.swift",
            "Tests/Services/CronClientTests.swift",
            "Tests/Services/DisplayClientTests.swift",
            "Tests/Services/FilesystemClientTests.swift",
            "Tests/Services/JobClientTests.swift",
            "Tests/Services/NotificationClientTests.swift",
            "Tests/Services/NotificationStoreTests.swift",
            "Tests/Services/WorkspaceValidationTests.swift",
            "Tests/ViewModels/ContextRefreshGateTests.swift",
            "Tests/Views/NotificationInboxFilterTests.swift",
            "Tests/Views/NotificationSheetPresentationTests.swift",
        ]
        for relativePath in deletedPaths {
            #expect(
                !FileManager.default.fileExists(atPath: iosRoot.appendingPathComponent(relativePath).path),
                "\(relativePath) is fixed capability client/UI/test surface"
            )
        }

        let forbidden = [
            "ContextClient",
            "CronClient",
            "DisplayClient",
            "FilesystemClient",
            "JobClient",
            "NotificationClient",
            "RepoClient",
            "RepoListSessions",
            "RepoSessionSummary",
            "RepoGetDivergence",
            "RepoDivergence",
            "RpcTask",
            "TaskListParams",
            "TaskListResult",
            "NotificationStore",
            "NotificationDelivery",
            "ContextRefreshGate",
            "syncFromServerSnapshot",
            "ContextSnapshotResult",
            "context.getSnapshot",
            "context.getDetailedSnapshot",
            "display.stopStream",
            "job.cancel",
            "notifications::send",
            "repo.listSessions",
            "repo.getDivergence",
            "tasks.list",
        ]
        let checkedRoots = [
            iosRoot.appendingPathComponent("Sources"),
            iosRoot.appendingPathComponent("Tests"),
        ]
        for root in checkedRoots {
            for path in try swiftFiles(in: root) {
                if path.lastPathComponent == "SourceGuardTests.swift" {
                    continue
                }
                let source = try String(contentsOf: path, encoding: .utf8)
                for token in forbidden {
                    #expect(!source.contains(token), "\(token) must stay deleted from \(path.path)")
                }
            }
        }
    }

    @Test("Capability identity stays primitive-only")
    func testCapabilityIdentityStaysPrimitiveOnly() throws {
        let iosRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let checkedPaths = [
            "Sources/Core/Events/Payloads/CapabilityInvocationPayloads.swift",
            "Sources/Core/Events/Plugins/CapabilityInvocation",
            "Sources/Database/SessionEvent+Summary.swift",
            "Sources/Models/Dashboard/ActivityLine.swift",
            "Sources/Models/Dashboard/CapabilityActivityPresentation.swift",
            "Sources/Models/Dashboard/ServerActivityLine.swift",
            "Sources/Models/EngineProtocol/EngineProtocolTypes+Agent.swift",
            "Sources/Models/EngineProtocol/EngineProtocolTypes+Capability.swift",
            "Sources/Models/Messages",
            "Sources/ViewModels/Chat/ChatViewModel+Reconstruction.swift",
            "Sources/ViewModels/Handlers/CapabilityInvocationCoordinator.swift",
            "Sources/ViewModels/Managers/DashboardStreamManager.swift",
            "Sources/Views/Capabilities",
            "Tests/Core/Events/Plugins",
            "Tests/Core/Events/UnifiedEventTransformerActionProjectionTests.swift",
            "Tests/Models/CapabilityInvocationDisplayModelTests.swift",
            "Tests/Support/CapabilityTestFixtures.swift",
            "Tests/ViewModels/CapabilityInvocationCoordinatorTests.swift",
            "Tests/ViewModels/DashboardCapabilityStreamTests.swift",
            "Tests/Views/Capabilities",
        ]
        let forbidden = [
            "contract" + "Id",
            "implementation" + "Id",
            "function" + "Id",
            "plugin" + "Id",
            "worker" + "Id",
            "schema" + "Digest",
            "catalog" + "Revision",
            "trust" + "Tier",
            "risk" + "Level",
            "effect" + "Class",
            "binding" + "Decision" + "Id",
            "capability" + "::" + "search",
            "capability" + "::" + "inspect",
            "source" + "Label",
            "plugin" + "Label",
            "worker" + "Label",
        ]

        for relativePath in checkedPaths {
            let url = iosRoot.appendingPathComponent(relativePath)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let files: [URL]
            if (try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                files = try swiftFiles(in: url)
            } else {
                files = [url]
            }
            for file in files where file.lastPathComponent != "SourceGuardTests.swift" {
                let source = try String(contentsOf: file, encoding: .utf8)
                for token in forbidden {
                    #expect(!source.contains(token), "\(token) must stay deleted from capability primitive identity path: \(file.path)")
                }
            }
        }
    }

    @Test("Draft persistence has no skills residue")
    func testDraftPersistenceHasNoSkillsResidue() throws {
        let iosRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let checkedPaths = [
            "Sources/Database",
            "Sources/Services/DraftStore.swift",
            "Tests/Infrastructure",
            "Tests/Services/DraftStoreTests.swift",
        ]
        let forbidden = [
            "skills" + "_json",
            "spells" + "_json",
            "selected" + "Skills",
            "Selected" + "Skill",
        ]

        for relativePath in checkedPaths {
            let url = iosRoot.appendingPathComponent(relativePath)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let files: [URL]
            if (try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                files = try swiftFiles(in: url)
            } else {
                files = [url]
            }
            for file in files where file.lastPathComponent != "SourceGuardTests.swift" {
                let source = try String(contentsOf: file, encoding: .utf8)
                for token in forbidden {
                    #expect(!source.contains(token), "\(token) must stay deleted from draft persistence path: \(file.path)")
                }
            }
        }
    }

    @Test("Primitive shell has no user-interaction pause plane")
    func testPrimitiveShellHasNoUserInteractionPausePlane() throws {
        let iosRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let checkedPaths = [
            "Sources",
            "Tests",
            "project.yml",
        ]
        let forbidden = [
            "User" + "Interaction" + "Invocation",
            "User" + "Interaction" + "Capability",
            "User" + "Interaction" + "Coordinator",
            "User" + "Interaction" + "State",
            "User" + "Interaction" + "Sheet",
            "User" + "Interaction" + "Viewer",
            "case " + "user" + "Interaction",
            "." + "user" + "Interaction",
            "answered" + "Questions",
            "submit" + "Answers",
            "Submit" + "Answers",
            "agent::" + "submit_answers",
            "capability.pause.",
            "Capability" + "Pause",
            "pause" + "Id",
            "prompt" + "Payload",
            "answer" + "Authority",
            "interaction" + "Status",
            "parsed" + "Answers",
            "ask" + "_user",
            "is" + "User" + "Interaction" + "Capability",
        ]

        for relativePath in checkedPaths {
            let url = iosRoot.appendingPathComponent(relativePath)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let files: [URL]
            if (try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                files = try swiftFiles(in: url)
            } else {
                files = [url]
            }
            for file in files where file.lastPathComponent != "SourceGuardTests.swift" {
                let source = try String(contentsOf: file, encoding: .utf8)
                for token in forbidden {
                    #expect(!source.contains(token), "\(token) must stay deleted from primitive shell: \(file.path)")
                }
            }
        }
    }

    @Test("Primitive shell has no fixed process dashboard plane")
    func testPrimitiveShellHasNoFixedProcessDashboardPlane() throws {
        let iosRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let deletedPaths = [
            "Sources/Core/Events/Plugins/Process",
            "Sources/ViewModels/Chat/ChatViewModel+ProcessEvents.swift",
            "Sources/ViewModels/State/ProcessState.swift",
            "Sources/Views/Capabilities/Process",
            "Sources/Views/Process",
            "Tests/ViewModels/State/ProcessStateTests.swift",
        ]
        for relativePath in deletedPaths {
            #expect(
                !FileManager.default.fileExists(atPath: iosRoot.appendingPathComponent(relativePath).path),
                "\(relativePath) belongs to the deleted fixed process dashboard plane"
            )
        }

        let checkedPaths = [
            "Sources",
            "Tests",
            "project.yml",
        ]
        let forbidden = [
            "Process" + "List" + "Sheet",
            "Process" + "State",
            "Process" + "Event" + "Handler",
            "Process" + "Spawned" + "Plugin",
            "Process" + "Completed" + "Plugin",
            "Process" + "Status" + "Update" + "Plugin",
            "Job" + "Backgrounded" + "Plugin",
            "Manage" + "Process" + "Result" + "Viewer",
            "show" + "Process" + "Sheet",
            "clear" + "Process" + "State",
            "handle" + "Process" + "Spawned",
            "handle" + "Process" + "Completed",
            "handle" + "Process" + "Status" + "Update",
            "handle" + "Job" + "Backgrounded",
            "process" + "." + "spawned",
            "process" + "." + "completed",
            "process" + "." + "status_update",
            "job" + "." + "backgrounded",
            "case " + "processes",
        ]

        for relativePath in checkedPaths {
            let url = iosRoot.appendingPathComponent(relativePath)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let files: [URL]
            if (try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                files = try swiftFiles(in: url)
            } else {
                files = [url]
            }
            for file in files where file.lastPathComponent != "SourceGuardTests.swift" {
                let source = try String(contentsOf: file, encoding: .utf8)
                for token in forbidden {
                    #expect(!source.contains(token), "\(token) must stay deleted from primitive shell: \(file.path)")
                }
            }
        }
    }

    @Test("iOS runtime contract is iOS 26 only")
    func testIOSRuntimeContractIsIOS26Only() throws {
        let fileURL = URL(fileURLWithPath: #filePath)
        let iosRoot = fileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let projectYML = try String(
            contentsOf: iosRoot.appendingPathComponent("project.yml"),
            encoding: .utf8
        )
        let baseConfig = try String(
            contentsOf: iosRoot.appendingPathComponent("Configuration/Base.xcconfig"),
            encoding: .utf8
        )
        let appEntry = try String(
            contentsOf: iosRoot.appendingPathComponent("Sources/App/TronMobileApp.swift"),
            encoding: .utf8
        )
        let architectureDoc = try String(
            contentsOf: iosRoot.appendingPathComponent("docs/architecture.md"),
            encoding: .utf8
        )
        let rootReadme = try String(
            contentsOf: iosRoot
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("README.md"),
            encoding: .utf8
        )

        #expect(projectYML.contains(#"iOS: "26.0""#))
        #expect(baseConfig.contains("IPHONEOS_DEPLOYMENT_TARGET = 26.0"))
        #expect(architectureDoc.contains("**Minimum iOS**: 26.0"))
        #expect(!architectureDoc.contains("**Minimum iOS**: 18.0"))
        #expect(rootReadme.contains("**Minimum iOS:** 26.0"))
        #expect(!rootReadme.contains("**Minimum iOS:** 18.0"))
        #expect(!appEntry.contains("This app requires iOS 26 or later"))
        #expect(!appEntry.contains("if #available(iOS 26.0, *)"))
    }

    @Test("Primitive shell has no fixed prompt picker plane")
    func testPrimitiveShellHasNoFixedPromptPickerPlane() throws {
        let iosRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let promptRoot = iosRoot.appendingPathComponent("Sources/Views/Prompt" + "Library")

        #expect(!FileManager.default.fileExists(atPath: promptRoot.path))
        #expect(!FileManager.default.fileExists(
            atPath: iosRoot.appendingPathComponent("Sources/ViewModels/State/Prompt" + "LibraryState.swift").path
        ))
        #expect(!FileManager.default.fileExists(
            atPath: iosRoot.appendingPathComponent("Sources/Models/EngineProtocol/EngineProtocolTypes+Prompt" + "Library.swift").path
        ))
        #expect(!FileManager.default.fileExists(
            atPath: iosRoot.appendingPathComponent("Sources/Services/Network/Clients/Prompt" + "LibraryClient.swift").path
        ))
    }

    @Test("Primitive shell has no interactive approval plane")
    func testPrimitiveShellHasNoInteractiveApprovalPlane() throws {
        let iosRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let deletedPaths = [
            "Sources/Core/Events/Plugins/Approval",
            "Sources/Services/Network/Clients/ApprovalClient.swift",
            "Sources/ViewModels/Handlers/EngineApprovalCoordinator.swift",
            "Sources/ViewModels/State/EngineApprovalState.swift",
            "Sources/Views/EngineApproval",
            "Sources/Models/Messages/EngineApprovalTypes.swift",
            "Sources/Models/EngineProtocol/EngineProtocolTypes+Approval.swift",
        ]
        for relativePath in deletedPaths {
            #expect(
                !FileManager.default.fileExists(atPath: iosRoot.appendingPathComponent(relativePath).path),
                "\(relativePath) belongs to the deleted interactive approval plane"
            )
        }

        let forbiddenFragments = [
            "approval::resolve",
            "approval.pending",
            "approval.resolved",
            "approvalPromptMode",
            "AutonomyApprovalPromptMode",
            "EngineApproval",
            "engineApproval",
            "ApprovalClient",
            "approvalPolicy",
            "approvalContract",
            "approvalState",
            "APPROVAL_REQUIRED"
        ]
        let sourcesRoot = iosRoot.appendingPathComponent("Sources")
        guard let enumerator = FileManager.default.enumerator(
            at: sourcesRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            Issue.record("Unable to enumerate iOS sources")
            return
        }
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            let content = try String(contentsOf: url, encoding: .utf8)
            for fragment in forbiddenFragments {
                #expect(
                    !content.contains(fragment),
                    "\(url.lastPathComponent) retains deleted approval fragment \(fragment)"
                )
            }
        }
    }

    @Test("Audit Details product console stays removed")
    func testAuditDetailsOverviewAndInspectionBoundary() throws {
        let iosRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let deletedPaths = [
            "Sources/Views/AuditDetails",
            "Sources/ViewModels/State/AuditDetailsState.swift",
            "Sources/ViewModels/State/AuditDetailsWorkerPackProjection.swift",
            "Sources/ViewModels/State/AuditDetailsWorkerArtifactProjection.swift",
            "Sources/Services/Network/Clients/CapabilityClient.swift",
        ]
        for relativePath in deletedPaths {
            #expect(
                !FileManager.default.fileExists(atPath: iosRoot.appendingPathComponent(relativePath).path),
                "\(relativePath) belongs to the deleted fixed Audit Details console"
            )
        }

        let forbiddenProductionModulePolicy = [
            "module::act",
            "module::package_action",
            "module::mutate_package",
            "module::configure",
            "module::activate",
            "module::approve_source",
            "module::run_conformance",
            "modulePolicy",
            "packagePolicy",
            "ModulePolicy",
            "PackagePolicy"
        ]
        let sourcesRoot = iosRoot.appendingPathComponent("Sources")
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
            for forbidden in forbiddenProductionModulePolicy {
                #expect(
                    !content.contains(forbidden),
                    "\(url.lastPathComponent) must not own module action/policy target `\(forbidden)`"
                )
            }
        }
    }

    @Test("feedback recipient has tracked non-placeholder default")
    func testFeedbackRecipientConfigDefault() throws {
        let fileURL = URL(fileURLWithPath: #filePath)
        let iosRoot = fileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let baseConfig = try String(
            contentsOf: iosRoot.appendingPathComponent("Configuration/Base.xcconfig"),
            encoding: .utf8
        )
        let expected = "tron@" + "mh" + "is" + "mail.com"
        let line = try #require(
            baseConfig
                .split(separator: "\n")
                .first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("TRON_FEEDBACK_EMAIL =") }
        )
        let value = line
            .split(separator: "=", maxSplits: 1)
            .last?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        #expect(value == expected)
        #expect(value?.isEmpty == false)
        #expect(value?.contains("$(") == false)
    }

    @Test("settings log viewer remains available in production builds")
    func testSettingsLogViewerAvailableInProductionBuilds() throws {
        let fileURL = URL(fileURLWithPath: #filePath)
        let iosRoot = fileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let settingsView = try String(
            contentsOf: iosRoot.appendingPathComponent("Sources/Views/Settings/SettingsView.swift"),
            encoding: .utf8
        )
        let logViewer = try String(
            contentsOf: iosRoot.appendingPathComponent("Sources/Views/System/LogViewer.swift"),
            encoding: .utf8
        )
        let ingestionService = try String(
            contentsOf: iosRoot.appendingPathComponent("Sources/Services/Diagnostics/ClientLogIngestionService.swift"),
            encoding: .utf8
        )
        let miscClient = try String(
            contentsOf: iosRoot.appendingPathComponent("Sources/Services/Network/Clients/MiscClient.swift"),
            encoding: .utf8
        )
        let dependencyContainer = try String(
            contentsOf: iosRoot.appendingPathComponent("Sources/Core/DI/DependencyContainer.swift"),
            encoding: .utf8
        )
        let app = try String(
            contentsOf: iosRoot.appendingPathComponent("Sources/App/TronMobileApp.swift"),
            encoding: .utf8
        )
        let architectureDoc = try String(
            contentsOf: iosRoot.appendingPathComponent("docs/architecture.md"),
            encoding: .utf8
        )
        let rootReadme = try String(
            contentsOf: iosRoot
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("README.md"),
            encoding: .utf8
        )

        #expect(settingsView.contains("@State private var showLogViewer = false"))
        #expect(settingsView.contains("Button { showLogViewer = true }"))
        #expect(settingsView.contains("LogViewer()"))
        #expect(!settingsView.contains("#if DEBUG || BETA"))
        #expect(!logViewer.hasPrefix("#if DEBUG || BETA"))
        #expect(!logViewer.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("#endif"))
        #expect(!logViewer.contains("exportLogsToServer"))
        #expect(!logViewer.contains("square.and.arrow.up"))
        #expect(logViewer.contains("Server sync is automatic while connected"))
        #expect(ingestionService.contains("ClientLogIngestionPlanner"))
        #expect(ingestionService.contains("ios:client-log-ingest:"))
        #expect(ingestionService.contains("uploadedEntryFingerprints"))
        #expect(ingestionService.contains("visibleEntryFingerprints"))
        #expect(ingestionService.contains("DiagnosticsRedactor"))
        #expect(ingestionService.contains("Task.isCancelled"))
        #expect(ingestionService.contains("uploadTaskSerial"))
        #expect(ingestionService.contains("isSuccessfulIngestionPlumbing"))
        #expect(dependencyContainer.contains("clientLogIngestionService.start()"))
        #expect(dependencyContainer.contains("clientLogIngestionService.updateEngineClient(newClient)"))
        #expect(app.contains("container.clientLogIngestionService.handleConnectionChange"))
        #expect(app.contains("container.clientLogIngestionService.handleScenePhaseChange"))
        #expect(miscClient.contains("func ingestLogs(entries: [ClientLogEntry], idempotencyKey: EngineIdempotencyKey) async throws -> LogsIngestResult"))

        let ingestStart = try #require(miscClient.range(of: "func ingestLogs(entries: [ClientLogEntry]"))
        let diagnosticsStart = try #require(miscClient.range(of: "// MARK: - Diagnostics (debug / beta only)"))
        let ingestBlock = miscClient[ingestStart.lowerBound..<diagnosticsStart.lowerBound]
        #expect(!ingestBlock.contains("#if DEBUG || BETA"))
        #expect(!ingestBlock.contains("logger.info"))

        #expect(architectureDoc.contains("The settings toolbar exposes Logs in every build configuration."))
        #expect(architectureDoc.contains("mirrors bounded client logs into the server `logs` table"))
        #expect(architectureDoc.contains("self-feeding diagnostics loop"))
        #expect(rootReadme.contains("Settings also exposes the Logs sheet in every iOS build configuration"))
        #expect(rootReadme.contains("automatically ingests deduplicated client logs"))
        #expect(rootReadme.contains("self-feeding diagnostics loops"))
    }

    @Test("fast production scheme keeps prod identity with debug build settings")
    func testFastProductionSchemeUsesProdIdentityAndDebugSettings() throws {
        let fileURL = URL(fileURLWithPath: #filePath)
        let iosRoot = fileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let projectYML = try String(
            contentsOf: iosRoot.appendingPathComponent("project.yml"),
            encoding: .utf8
        )
        let prodDebugConfig = try String(
            contentsOf: iosRoot.appendingPathComponent("Configuration/ProdDebug.xcconfig"),
            encoding: .utf8
        )
        let developmentDoc = try String(
            contentsOf: iosRoot.appendingPathComponent("docs/development.md"),
            encoding: .utf8
        )
        let architectureDoc = try String(
            contentsOf: iosRoot.appendingPathComponent("docs/architecture.md"),
            encoding: .utf8
        )
        let rootReadme = try String(
            contentsOf: iosRoot
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("README.md"),
            encoding: .utf8
        )

        #expect(projectYML.contains("ProdDebug: Configuration/ProdDebug.xcconfig"))
        #expect(projectYML.contains("ProdDebug: debug"))
        #expect(projectYML.contains("Tron Fast:"))
        #expect(projectYML.contains("config: ProdDebug"))
        #expect(projectYML.contains("CODE_SIGN_ENTITLEMENTS: TronMobileProd.entitlements"))
        #expect(projectYML.contains("CODE_SIGN_ENTITLEMENTS: ShareExtension/ShareExtensionProd.entitlements"))

        #expect(prodDebugConfig.contains("SWIFT_OPTIMIZATION_LEVEL = -Onone"))
        #expect(prodDebugConfig.contains("ENABLE_TESTABILITY = YES"))
        #expect(prodDebugConfig.contains("ONLY_ACTIVE_ARCH = YES"))
        #expect(prodDebugConfig.contains("SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG"))
        #expect(!prodDebugConfig.contains("BETA"))
        #expect(prodDebugConfig.contains("PRODUCT_BUNDLE_IDENTIFIER = com.tron.mobile"))
        #expect(prodDebugConfig.contains("ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon"))

        #expect(developmentDoc.contains("Tron Fast"))
        #expect(architectureDoc.contains("ProdDebug"))
        #expect(rootReadme.contains("Tron Fast"))
    }

    @Test("Codex iPhone actions rebuild and install production variants")
    func testCodexIPhoneActionsRebuildAndInstallProductionVariants() throws {
        let fileURL = URL(fileURLWithPath: #filePath)
        let iosRoot = fileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let repoRoot = iosRoot
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let environment = try String(
            contentsOf: repoRoot.appendingPathComponent(".codex/environments/environment.toml"),
            encoding: .utf8
        )
        let installScript = try String(
            contentsOf: repoRoot.appendingPathComponent("scripts/tron-ios-beta"),
            encoding: .utf8
        )
        let developmentDoc = try String(
            contentsOf: iosRoot.appendingPathComponent("docs/development.md"),
            encoding: .utf8
        )
        let rootReadme = try String(
            contentsOf: repoRoot.appendingPathComponent("README.md"),
            encoding: .utf8
        )

        #expect(environment.contains(#"name = "Rebuild + Install + Launch iOS Beta on iPhone""#))
        #expect(environment.contains(#"name = "Rebuild + Install + Launch iOS Prod Fast Debug on iPhone""#))
        #expect(environment.contains("TRON_IOS_DEVICE_NAME=iPhone"))
        #expect(environment.contains(#"TRON_IOS_SCHEME='Tron Fast'"#))
        #expect(environment.contains("TRON_IOS_CONFIGURATION=ProdDebug"))
        #expect(environment.contains("scripts/tron-ios-beta install"))
        #expect(environment.contains(#"name = "Rebuild + Install + Launch iOS Prod Release on iPhone""#))
        #expect(environment.contains("TRON_IOS_SCHEME=Tron"))
        #expect(environment.contains("TRON_IOS_CONFIGURATION=Prod scripts/tron-ios-beta install"))
        #expect(environment.contains(#"name = "Just Launch Installed iOS Beta on iPhone""#))
        #expect(environment.contains(#"name = "Just Launch Installed iOS Prod on iPhone""#))
        #expect(!environment.contains(#"name = "Just Launch Installed iOS Prod Fast on iPhone""#))
        #expect(environment.contains("TRON_IOS_CONFIGURATION=Prod scripts/tron-ios-beta launch"))

        var actionNames: [String] = []
        var inAction = false
        for line in environment.split(separator: "\n").map(String.init) {
            if line == "[[actions]]" {
                inAction = true
                continue
            }
            if line.hasPrefix("[") && line != "[[actions]]" {
                inAction = false
            }
            if inAction && line.hasPrefix(#"name = ""#) && line.hasSuffix(#"""#) {
                let name = line
                    .dropFirst(#"name = ""#.count)
                    .dropLast()
                actionNames.append(String(name))
            }
        }
        #expect(Set(actionNames).count == actionNames.count)
        #expect(actionNames
            .filter { $0.hasPrefix("Rebuild") }
            .allSatisfy { $0.hasPrefix("Rebuild + Install + Launch") })
        #expect(actionNames
            .filter { $0.hasPrefix("Just Launch Installed iOS Prod") }
            == ["Just Launch Installed iOS Prod on iPhone"])

        #expect(installScript.contains(#"SCHEME="${TRON_IOS_SCHEME:-Tron Beta}""#))
        #expect(installScript.contains(#"CONFIG="${TRON_IOS_CONFIGURATION:-Beta}""#))
        #expect(installScript.contains("TRON_IOS_SCHEME"))
        #expect(installScript.contains("TRON_IOS_CONFIGURATION"))
        #expect(installScript.contains(#"app="$DERIVED_DATA/Build/Products/${CONFIG}-iphoneos/TronMobile.app""#))
        #expect(!installScript.contains(#"find "$DERIVED_DATA/Build/Products" -name "TronMobile.app" -path "*iphoneos*" -type d | head -1"#))

        #expect(developmentDoc.contains("Rebuild + Install + Launch iOS Prod Fast Debug on iPhone"))
        #expect(developmentDoc.contains("Rebuild + Install + Launch iOS Prod Release on iPhone"))
        #expect(developmentDoc.contains("Just Launch Installed"))
        #expect(developmentDoc.contains("deduplicated by bundle ID"))
        #expect(developmentDoc.contains("installs the requested configuration's `iphoneos`"))
        #expect(rootReadme.contains("Rebuild + Install + Launch"))
        #expect(rootReadme.contains("Just Launch Installed"))
        #expect(rootReadme.contains("deduplicated production"))
        #expect(rootReadme.contains("installs the requested configuration's `iphoneos`"))
    }

    @Test("iOS 26 cleanup hooks stay removed")
    func testIOS26CleanupHooksStayRemoved() throws {
        let fileURL = URL(fileURLWithPath: #filePath)
        let iosRoot = fileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourcesRoot = iosRoot.appendingPathComponent("Sources")
        let forbiddenNeedles: [(String, String)] = [
            ("if #available(iOS 26.0, *)", "runtime iOS 26 availability gate"),
            ("ASPresentationAnchor(frame:", "presentation-anchor workaround"),
            ("+ Text(", "Text concatenation"),
        ]
        let chipStyleStrokeRegex = try NSRegularExpression(
            pattern: #"(?s)\.chipStyle\s*\([^)]*strokeOpacity\s*:"#,
            options: []
        )

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
                    "\(url.lastPathComponent) contains removed \(reason)"
                )
            }

            let chipStyleStrokeMatches = chipStyleStrokeRegex.matches(
                in: content,
                range: NSRange(location: 0, length: (content as NSString).length)
            )
            #expect(
                chipStyleStrokeMatches.isEmpty,
                "\(url.lastPathComponent) routes removed chipStyle strokeOpacity compatibility through the glass-only API"
            )
        }
    }

    @Test("Primitive shell has no fixed product modes")
    func testPrimitiveShellHasNoFixedProductModes() throws {
        let fileURL = URL(fileURLWithPath: #filePath)
        let iosRoot = fileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourcesRoot = iosRoot.appendingPathComponent("Sources")
        let viewsRoot = sourcesRoot.appendingPathComponent("Views")

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
                !FileManager.default.fileExists(atPath: viewsRoot.appendingPathComponent(rootName).path),
                "\(rootName) is a fixed product UI root; primitive iOS must render only the chat shell and generic runtime surfaces"
            )
        }

        let requiredShellFiles = [
            "Views/Chat/ContentView.swift",
            "Views/Chat/ChatView.swift",
            "Views/InputBar/InputBar.swift",
            "Views/Settings/SettingsView.swift",
            "Views/DynamicSurfaces/GeneratedRuntimeSurfaceView.swift",
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
            ("show" + "Agent" + "Control", "Agent Control sheet presenter"),
            ("Agent" + "Control" + "View", "Agent Control product sheet"),
            ("Work" + "Dashboard" + "View", "fixed Work dashboard"),
            ("Audit" + "Details" + "View", "fixed Audit Details console"),
            ("Source" + "Control" + "Sheet", "fixed Source Control sheet"),
            ("Prompt" + "Library" + "Sheet", "fixed prompt picker"),
            ("Skill" + "Detail" + "Sheet", "fixed Skills sheet"),
            ("Mention" + "Popup", "fixed Skills picker"),
            ("Floating" + "Voice" + "Notes" + "Button", "fixed Voice Notes UI"),
            ("Voice" + "Notes" + "Recording" + "Sheet", "fixed Voice Notes UI"),
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

    private func swiftFiles(in root: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            Issue.record("Could not enumerate \(root.path)")
            return []
        }

        var files: [URL] = []
        while let any = enumerator.nextObject() {
            guard let url = any as? URL else { continue }
            guard url.pathExtension == "swift" else { continue }
            files.append(url)
        }
        return files
    }
}
