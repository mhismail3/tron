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
                        "\(url.lastPathComponent) contains personal-info literal `\(needle)` - route user info through runtime state"
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
    }

}
