import Testing
import Foundation

extension SourceGuardTests {

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
            ("tool" + "Start", "retired session list activity kind"),
            ("tool" + "End", "retired session list activity kind"),
            ("tool" + "Agent", "retired worker spawn-type wire value"),
            ("Tool" + "Agent", "retired worker spawn-type symbol"),
            ("tool" + "Count", "retired analytics capability-count field"),
            ("tool" + "Status", "retired interaction status payload field"),
            ("tool" + "Order", "retired capability metadata ordering key"),
            ("tool" + "Execution" + "Mode", "retired capability metadata execution key"),
            ("tool" + "Schema", "retired capability metadata schema key"),
            ("local" + "Tool" + "Schema", "retired local capability schema key"),
            ("Tool" + "Operation", "retired process kind"),
            ("Tool" + "Color", "retired session list color model"),
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

        let iosRoot = iosAppRoot()
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
                if isSourceGuardFile(url) { continue }

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
        let iosRoot = iosAppRoot()
        let deletedPaths = [
            "Sources/Support/Notifications/PushNotificationService.swift",
            "Sources/Support/Infrastructure/APNsEnvironment.swift",
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
                if isSourceGuardFile(path) {
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
        let iosRoot = iosAppRoot()
        let deletedPaths = [
            "Sources/Engine/Network/Clients/ContextClient.swift",
            "Sources/Engine/Network/Clients/CronClient.swift",
            "Sources/Engine/Network/Clients/DisplayClient.swift",
            "Sources/Engine/Network/Clients/FilesystemClient.swift",
            "Sources/Engine/Network/Clients/JobClient.swift",
            "Sources/Engine/Network/Clients/NotificationClient.swift",
            "Sources/Engine/Network/Clients/RepoClient.swift",
            "Sources/Engine/Protocol/DTOs/EngineProtocolTypes+Cron.swift",
            "Sources/Engine/Protocol/DTOs/EngineProtocolTypes+Filesystem.swift",
            "Sources/Engine/Protocol/DTOs/EngineProtocolTypes+Repo.swift",
            "Sources/Engine/Protocol/DTOs/EngineProtocolTypes+Task.swift",
            "Sources/Session/Timeline/Messages/NotificationDeliveryTypes.swift",
            "Sources/Support/Storage/NotificationStore.swift",
            "Sources/Session/Chat/State/ContextRefreshGate.swift",
            "Sources/UI/Capabilities/NotificationDelivery",
            "Sources/UI/Notifications",
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
                if isSourceGuardFile(path) {
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
        let iosRoot = iosAppRoot()
        let checkedPaths = [
            "Sources/Engine/Events/Payloads/CapabilityInvocationPayloads.swift",
            "Sources/Engine/Events/Plugins/CapabilityInvocation",
            "Sources/Engine/Persistence/SQLite/SessionEvent+Summary.swift",
            "Sources/Session/Timeline/Activity/ActivityLine.swift",
            "Sources/Session/Timeline/Activity/CapabilityActivityPresentation.swift",
            "Sources/Session/Timeline/Activity/ServerActivityLine.swift",
            "Sources/Engine/Protocol/Agent/EngineProtocolTypes+Agent.swift",
            "Sources/Engine/Protocol/Capability/EngineProtocolTypes+Capability.swift",
            "Sources/Session/Timeline/Messages",
            "Sources/Session/Chat/ViewModel/ChatViewModel+Reconstruction.swift",
            "Sources/Session/Chat/Coordinators/CapabilityInvocationCoordinator.swift",
            "Sources/Session/Timeline/Activity/SessionActivityStreamManager.swift",
            "Sources/UI/Capabilities",
            "Tests/Core/Events/Plugins",
            "Tests/Core/Events/UnifiedEventTransformerActionProjectionTests.swift",
            "Tests/Models/CapabilityInvocationDisplayModelTests.swift",
            "Tests/Support/CapabilityTestFixtures.swift",
            "Tests/ViewModels/CapabilityInvocationCoordinatorTests.swift",
            "Tests/ViewModels/SessionActivityStreamTests.swift",
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
            for file in files where !isSourceGuardFile(file) {
                let source = try String(contentsOf: file, encoding: .utf8)
                for token in forbidden {
                    #expect(!source.contains(token), "\(token) must stay deleted from capability primitive identity path: \(file.path)")
                }
            }
        }
    }
}
