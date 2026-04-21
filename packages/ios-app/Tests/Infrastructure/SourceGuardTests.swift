import Testing
import Foundation

/// Regression guard: iOS source code and tests must contain no hardcoded
/// personal-info literals. User identity belongs in `MEMORY.md` on the server
/// (auto-injected into every session's context via the `memory.content` RPC
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
}
