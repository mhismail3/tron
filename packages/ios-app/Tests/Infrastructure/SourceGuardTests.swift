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
        #expect(toolbar.contains(#".accessibilityLabel("Navigation")"#))
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
            "NavigationMode" + "." + "voiceNotes",
            "can" + "Manage" + "Automations",
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
            ("tool" + "Agent", "retired subagent spawn-type wire value"),
            ("Tool" + "Agent", "retired subagent spawn-type symbol"),
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
            ("Spawn" + "Subagent", "retired subagent topology naming"),
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

    @Test("Push registration requests permission after engine pairing")
    func testPushRegistrationRequestsPermissionAfterPairing() throws {
        let fileURL = URL(fileURLWithPath: #filePath)
        let iosRoot = fileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appEntry = try String(
            contentsOf: iosRoot.appendingPathComponent("Sources/App/TronMobileApp.swift"),
            encoding: .utf8
        )

        #expect(appEntry.contains("guard onboardingComplete else { return }"))
        #expect(appEntry.contains("await registerPushIfAuthorized()"))
        #expect(appEntry.contains("case .notDetermined:"))
        #expect(appEntry.contains("requestAuthorization()"))
        #expect(appEntry.contains("device::register"))
        #expect(appEntry.contains("inFlightDeviceTokenRegistrationKeys"))
        #expect(appEntry.contains("Device token registration already in flight; skipping duplicate"))
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

    @Test("Prompt Library picker is selection-only and management is generated UI")
    func testPromptLibraryPickerBoundaryAndGeneratedManagement() throws {
        let iosRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let promptRoot = iosRoot.appendingPathComponent("Sources/Views/PromptLibrary")
        let sheet = try String(
            contentsOf: promptRoot.appendingPathComponent("PromptLibrarySheet.swift"),
            encoding: .utf8
        )
        let historyList = try String(
            contentsOf: promptRoot.appendingPathComponent("PromptHistoryListView.swift"),
            encoding: .utf8
        )
        let snippetList = try String(
            contentsOf: promptRoot.appendingPathComponent("PromptSnippetListView.swift"),
            encoding: .utf8
        )
        let pickerState = try String(
            contentsOf: iosRoot.appendingPathComponent("Sources/ViewModels/State/PromptLibraryState.swift"),
            encoding: .utf8
        )
        let managementSheet = try String(
            contentsOf: promptRoot.appendingPathComponent("PromptLibraryManagementSurfaceSheet.swift"),
            encoding: .utf8
        )
        let generatedRenderer = try String(
            contentsOf: iosRoot.appendingPathComponent("Sources/Views/EngineConsole/GeneratedUISurfaceView.swift"),
            encoding: .utf8
        )

        #expect(sheet.contains("PromptLibraryManagementSurfaceSheet"))
        #expect(sheet.contains("onSelect(text)"))
        #expect(sheet.contains("onSelect(item.text)"))
        #expect(historyList.contains(".onTapGesture { onSelect(item.text) }"))
        #expect(snippetList.contains(".onTapGesture { onSelect(snippet.text) }"))
        #expect(!sheet.contains("SnippetEditorSheet"))
        #expect(!sheet.contains("showClearHistoryAlert"))
        #expect(!sheet.contains("isCreatingSnippet"))
        #expect(!sheet.contains("editingSnippet"))
        for pickerFile in [sheet, historyList, snippetList, pickerState] {
            #expect(!pickerFile.contains(".swipeActions"))
            #expect(!pickerFile.contains("createSnippet"))
            #expect(!pickerFile.contains("updateSnippet"))
            #expect(!pickerFile.contains("deleteSnippet"))
            #expect(!pickerFile.contains("deleteHistory"))
            #expect(!pickerFile.contains("clearHistory"))
            #expect(!pickerFile.contains("targetFunctionId"))
            #expect(!pickerFile.contains("payloadTemplate"))
            #expect(!pickerFile.contains("requiredGrant"))
            #expect(!pickerFile.contains("UiActionSubmissionDTO"))
        }
        #expect(!snippetList.contains("onEdit"))

        #expect(managementSheet.contains(#"targetType: "resource_collection""#))
        #expect(managementSheet.contains(#"prompt_library.snippets.v1"#))
        #expect(managementSheet.contains(#"prompt_library.history.v1"#))
        #expect(managementSheet.contains("GeneratedUISurfaceView"))
        #expect(managementSheet.contains("submitUiAction"))
        #expect(managementSheet.contains("ToastCenter.shared.push"))
        #expect(managementSheet.contains("successMessage"))
        #expect(managementSheet.contains("toastDedupKey"))
        #expect(managementSheet.contains(".withToastBanner()"))
        #expect(!managementSheet.contains("lastActionResult"))
        #expect(!managementSheet.contains("actionResultView"))
        #expect(!managementSheet.contains("childInvocationId"))
        #expect(!managementSheet.contains("targetFunctionId"))
        #expect(!managementSheet.contains("payloadTemplate"))
        #expect(!managementSheet.contains("requiredGrant"))

        #expect(generatedRenderer.contains("seedFormDefaultsIfNeeded"))
        #expect(generatedRenderer.contains(#"component.props?["value"]"#))
        #expect(generatedRenderer.contains(#""TextField", "TextArea", "Select", "Toggle", "Stepper", "DateTime""#))
        #expect(generatedRenderer.contains("confirmationDialog"))
        #expect(generatedRenderer.contains("GeneratedUIRenderer.inputIsSatisfied"))
        #expect(generatedRenderer.contains("GeneratedUIRenderer.userInput"))
        #expect(generatedRenderer.contains("UiActionSubmissionDTO"))
        #expect(generatedRenderer.contains("guard !isOfflineCached else { return }"))
        #expect(generatedRenderer.contains("UiActionPresentationDTO"))
        #expect(generatedRenderer.contains("GeneratedUIActionButtonRole(presentation:"))
        #expect(generatedRenderer.contains("presentationIcon(for:"))
        #expect(generatedRenderer.contains("SettingsCard"))
        #expect(generatedRenderer.contains("TronTypography"))
        #expect(generatedRenderer.contains(".sectionFill"))
        #expect(generatedRenderer.contains("GeneratedUIActionButtonStyle"))
        #expect(generatedRenderer.contains(".generatedUIAction"))
        #expect(generatedRenderer.contains(".buttonStyle(.noFeedback)"))
        #expect(generatedRenderer.contains("generatedUIRowExpansionAnimation"))
        #expect(generatedRenderer.contains("Animation.smooth"))
        #expect(generatedRenderer.contains("withAnimation(generatedUIRowExpansionAnimation)"))
        #expect(generatedRenderer.contains(".transition(.opacity)"))
        #expect(!generatedRenderer.contains("targetFunctionId"))
        #expect(!generatedRenderer.contains("isDestructive(action:"))
        #expect(!generatedRenderer.contains("actionSymbol(action:"))
        #expect(!generatedRenderer.contains("humanizedActionLabel"))
        #expect(!generatedRenderer.contains(#"text.contains("delete")"#))
        #expect(!generatedRenderer.contains(#"text.contains("refresh")"#))
        #expect(!generatedRenderer.contains(".textFieldStyle(.roundedBorder)"))
        #expect(!generatedRenderer.contains(".background(.thinMaterial"))
        #expect(!generatedRenderer.contains(".spring("))
        #expect(!generatedRenderer.contains(".scaleEffect("))
        #expect(!generatedRenderer.contains("DisclosureGroup"))
        #expect(managementSheet.contains("SettingsCard"))
        #expect(managementSheet.contains("animatesSelection: false"))
    }

    @Test("Engine approval flow stays server-owned")
    func testEngineApprovalFlowStaysServerOwned() throws {
        let iosRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let client = try String(
            contentsOf: iosRoot.appendingPathComponent("Sources/Services/Network/Clients/ApprovalClient.swift"),
            encoding: .utf8
        )
        let coordinator = try String(
            contentsOf: iosRoot.appendingPathComponent("Sources/ViewModels/Handlers/EngineApprovalCoordinator.swift"),
            encoding: .utf8
        )
        let sheet = try String(
            contentsOf: iosRoot.appendingPathComponent("Sources/Views/EngineApproval/EngineApprovalSheet.swift"),
            encoding: .utf8
        )
        let types = try String(
            contentsOf: iosRoot.appendingPathComponent("Sources/Models/Messages/EngineApprovalTypes.swift"),
            encoding: .utf8
        )

        #expect(client.contains("\"approval::resolve\""))
        #expect(client.contains("authorityScopes: [\"approval.resolve\"]"))
        #expect(coordinator.contains("status: .resolving"))
        #expect(coordinator.contains("decision: nil"))
        #expect(coordinator.contains("updateMessageFromServerApproval"))
        #expect(coordinator.contains("context.connectionState.isConnected"))
        #expect(coordinator.contains("Approval decisions are read-only while disconnected"))
        #expect(sheet.contains("capabilityData.consequenceSections"))
        #expect(types.contains("targetMetadata"))
        #expect(types.contains("authorityGrantId"))
        #expect(types.contains("idempotencyKey"))
    }

    @Test("Engine Console overview and inspection sheet stay native and scoped")
    func testEngineConsoleOverviewAndInspectionBoundary() throws {
        let iosRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let engineConsole = try String(
            contentsOf: iosRoot.appendingPathComponent("Sources/Views/EngineConsole/EngineConsoleView.swift"),
            encoding: .utf8
        )
        let engineConsoleComponents = try String(
            contentsOf: iosRoot.appendingPathComponent("Sources/Views/EngineConsole/EngineConsoleComponents.swift"),
            encoding: .utf8
        )
        let engineConsoleState = try String(
            contentsOf: iosRoot.appendingPathComponent("Sources/ViewModels/State/EngineConsoleState.swift"),
            encoding: .utf8
        )
        let capabilityClient = try String(
            contentsOf: iosRoot.appendingPathComponent("Sources/Services/Network/Clients/CapabilityClient.swift"),
            encoding: .utf8
        )
        let moduleProjection = try String(
            contentsOf: iosRoot.appendingPathComponent("Sources/ViewModels/State/EngineConsoleModuleProjection.swift"),
            encoding: .utf8
        )
        let moduleProjectionView = try String(
            contentsOf: iosRoot.appendingPathComponent("Sources/Views/EngineConsole/EngineConsoleModuleProjectionView.swift"),
            encoding: .utf8
        )
        let engineConsoleSurface = engineConsole + "\n" + engineConsoleComponents

        #expect(!engineConsole.contains(#".navigationTitle("Engine")"#))
        #expect(engineConsole.contains("DashboardToolbarContent("))
        #expect(engineConsole.contains(#"title: "Engine","#))
        #expect(engineConsole.contains("EngineConsoleSuggestionChips(suggestions: state.substrateSearchSuggestions)"))
        #expect(engineConsoleState.contains("var substrateSearchSuggestions: [EngineConsoleSearchSuggestion]"))
        #expect(engineConsoleState.contains("registry?.implementations"))
        #expect(engineConsoleState.contains("registry?.documents"))
        #expect(engineConsoleState.contains("catalogWatchSnapshot("))
        #expect(engineConsoleState.contains("catalogSnapshot?.snapshot?.functions"))
        #expect(capabilityClient.contains(#""catalog::watch_snapshot""#))
        #expect(capabilityClient.contains(#""catalog.read""#))
        #expect(engineConsoleState.contains("controlSnapshot?.availableActions"))
        #expect(engineConsoleState.contains("controlSnapshot?.modulePackages"))
        #expect(engineConsoleState.contains("controlSnapshot?.uiSurfaceRefs"))
        #expect(engineConsoleState.contains("readOnlyMutationReason"))
        #expect(engineConsoleState.contains("Offline Engine Console cache is read-only"))
        #expect(engineConsoleState.contains("failMutationIfReadOnly(surface: true)"))
        #expect(engineConsoleState.contains("failMutationIfReadOnly(program: true)"))
        #expect(engineConsoleState.contains("failMutationIfReadOnly()"))
        #expect(engineConsole.contains("isOfflineCached: state.isMutatingDisabled"))
        #expect(engineConsoleState.contains("audit?.events"))
        #expect(engineConsoleState.contains("programRuns?.programRuns"))
        #expect(engineConsoleState.contains(#""capabilities.primer""#))
        #expect(engineConsoleState.contains(#""conformance \(implementation.implementationId)""#))
        #expect(!engineConsoleComponents.contains("private let suggestions"))
        for fixedCatalogSuggestion in [
            "Read files",
            "Run command",
            "Search web",
            "Ask user",
            "Spawn worker",
            "read a file",
            "run a shell command",
            "search the web",
            "ask the user a question"
        ] {
            #expect(!engineConsoleComponents.contains(fixedCatalogSuggestion))
        }
        #expect(engineConsole.contains("EngineConsoleModuleProjectionCard("))
        #expect(engineConsole.contains("projection: state.moduleOperatorProjection"))
        #expect(engineConsole.contains(#"state.controlAdvertisesAction(functionId: "ui::surface_for_target", targetType: target.targetType)"#))
        #expect(engineConsole.contains("state.authorSurface(targetType: target.targetType, targetId: target.targetId)"))
        #expect(engineConsoleState.contains("EngineConsoleModuleOperatorProjection.make(from: controlSnapshot)"))
        #expect(moduleProjection.contains("snapshot.moduleHealth"))
        #expect(moduleProjection.contains("snapshot.moduleSourceTrust"))
        #expect(moduleProjection.contains(#".filter { $0.functionId.hasPrefix("module::") }"#))
        #expect(moduleProjection.contains("var surfaceTargets: [EngineConsoleModuleSurfaceTarget]"))
        #expect(moduleProjectionView.contains("projection.evidenceRefCount"))
        #expect(moduleProjectionView.contains("projection.surfaceTargets"))
        #expect(moduleProjectionView.contains("openSurface(target)"))
        #expect(moduleProjectionView.contains("projection.actions"))
        for forbiddenModulePolicy in [
            "module::configure",
            "module::activate",
            "module::approve_source",
            "module::run_conformance",
            "payloadTemplate",
            "packagePolicy"
        ] {
            #expect(!moduleProjection.contains(forbiddenModulePolicy))
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
        #expect(engineConsoleSurface.contains(".adaptivePresentationDetents([.medium, .large], ipadSizing: .largeForm)"))
        #expect(engineConsoleSurface.contains(#"SheetTitle(title: "Inspection", color: tint)"#))
        #expect(engineConsoleSurface.contains("SheetDismissButton(color: tint)"))
        #expect(engineConsoleSurface.contains("EngineConsoleCard(tint: tint)"))
        #expect(engineConsoleSurface.contains("private var secondaryTitle: String?"))
        #expect(engineConsoleSurface.contains("candidate != primaryTitle"))

        let readinessStart = try #require(engineConsole.range(of: "private var readinessIssues"))
        let readinessEnd = try #require(engineConsole.range(of: "private var mutationIssue"))
        let readinessBlock = String(engineConsole[readinessStart.lowerBound..<readinessEnd.lowerBound])
        #expect(!readinessBlock.contains("Program runtime unavailable"))
        #expect(!readinessBlock.contains("programRuntimeReady"))
        #expect(engineConsole.contains("private var programRuntimeReady: Bool"))
        #expect(engineConsole.contains("Program execution stays disabled until the first-party worker reports healthy conformance."))
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

    @Test("Codex iPhone action builds and launches fast production scheme")
    func testCodexIPhoneActionBuildsAndLaunchesFastProductionScheme() throws {
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

        #expect(environment.contains(#"name = "Rebuild + Launch iOS Prod Fast on iPhone""#))
        #expect(environment.contains("TRON_IOS_DEVICE_NAME=iPhone"))
        #expect(environment.contains(#"TRON_IOS_SCHEME='Tron Fast'"#))
        #expect(environment.contains("TRON_IOS_CONFIGURATION=ProdDebug"))
        #expect(environment.contains("scripts/tron-ios-beta install"))

        #expect(installScript.contains(#"SCHEME="${TRON_IOS_SCHEME:-Tron Beta}""#))
        #expect(installScript.contains(#"CONFIG="${TRON_IOS_CONFIGURATION:-Beta}""#))
        #expect(installScript.contains("TRON_IOS_SCHEME"))
        #expect(installScript.contains("TRON_IOS_CONFIGURATION"))
        #expect(installScript.contains(#"app="$DERIVED_DATA/Build/Products/${CONFIG}-iphoneos/TronMobile.app""#))
        #expect(!installScript.contains(#"find "$DERIVED_DATA/Build/Products" -name "TronMobile.app" -path "*iphoneos*" -type d | head -1"#))

        #expect(developmentDoc.contains("Rebuild + Launch iOS Prod Fast on iPhone"))
        #expect(developmentDoc.contains("installs the requested configuration's `iphoneos` product"))
        #expect(rootReadme.contains("Rebuild + Launch iOS Prod Fast on iPhone"))
        #expect(rootReadme.contains("installs the requested configuration's `iphoneos` product"))
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
}
