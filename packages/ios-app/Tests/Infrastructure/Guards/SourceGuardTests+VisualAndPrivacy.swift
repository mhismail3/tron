import Testing
import Foundation

extension SourceGuardTests {

    @Test("Shell toolbar keeps explicit iPhone icons")
    func testShellToolbarKeepsExplicitIPhoneIcons() throws {
        let iosRoot = iosAppRoot()
        let toolbar = try String(
            contentsOf: iosRoot.appendingPathComponent("Sources/UI/Chat/Shell/ShellToolbarContent.swift"),
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
        let iosRoot = iosAppRoot()
        let badge = try String(
            contentsOf: iosRoot.appendingPathComponent("Sources/UI/Chat/Messages/MessageMetadataBadge.swift"),
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
            "/Users/",
            "TRON_FEEDBACK_EMAIL = tron@",
            "githubRepoOwner",
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
                // Skip this guard file itself — needle-construction is intentional.
                if isSourceGuardFile(url) { continue }
                if permitsHomePathRedactionNeedles(url) { continue }

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

    private func permitsHomePathRedactionNeedles(_ url: URL) -> Bool {
        let path = url.path
        return path.hasSuffix("Sources/Support/Diagnostics/DiagnosticsRedactor.swift")
            || path.hasSuffix("Sources/Support/Foundation/Formatting/String+Extensions.swift")
            || path.hasSuffix("Tests/Support/Diagnostics/DiagnosticsRedactorTests.swift")
            || path.hasSuffix("Tests/Support/Diagnostics/DiagnosticsBundleBuilderTests.swift")
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
            "Sand" + "boxes" + "Dash" + "board" + "View",
            "Container" + "DTO",
            "Container" + "Action" + "Params",
            "Container" + "Action" + "Result",
            "sandbox" + "::" + "list_" + "containers",
            "sandbox" + "::" + "start_" + "container",
            "sandbox" + "::" + "stop_" + "container",
            "sandbox" + "::" + "kill_" + "container",
            "sandbox" + "::" + "remove_" + "container",
            "Automations" + "Dash" + "board" + "View",
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

        let iosRoot = iosAppRoot()
        let checkedFiles = [
            iosRoot.appendingPathComponent("Sources/Engine/Persistence/SQLite/EventDatabase.swift"),
            iosRoot.appendingPathComponent("Sources/Support/Composition/DependencyContainer.swift"),
            iosRoot.appendingPathComponent("Sources/Support/Diagnostics/DiagnosticsBundleBuilder.swift"),
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
                guard url.pathExtension == "swift" || url.pathExtension == "md" else { continue }
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
}
