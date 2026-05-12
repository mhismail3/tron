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
                if url.path.contains("/CodexApp/") { continue }

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
