import Foundation
import Testing

@Suite("Cleanup Guards")
struct CleanupGuardTests {
    private var iosRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var repoRoot: URL {
        iosRoot
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func read(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    @Test("Clone destination requires server home truth or an explicit locked path")
    func cloneRepoSheetDoesNotInventHomeDirectory() throws {
        let source = try read("packages/ios-app/Sources/Views/Session/CloneRepoSheet.swift")

        #expect(!source.contains("/" + "Users"))
        #expect(!source.contains("is" + "Loading" + "Home"))
        #expect(source.contains("Could not load home directory"))
        #expect(source.contains("destinationPath = lockedDestinationPath ?? \"\""))
    }

    @Test("Font settings no longer carries retired casual-axis storage")
    func fontSettingsDoesNotRetainRetiredCasualAxisMigration() throws {
        let source = try read("packages/ios-app/Sources/Theme/FontSettings.swift")

        for retired in [
            "casual" + "Axis",
            "font" + "Casual" + "Axis",
            "font" + "Casual" + "Axis" + "Set",
        ] {
            #expect(!source.contains(retired), "FontSettings still contains retired storage `\(retired)`")
        }
    }

    @Test("Display helpers use active defaults and deterministic heuristics")
    func displayHelpersAvoidLegacyFallbackTerminology() throws {
        let modelFormatter = try read("packages/ios-app/Sources/Utilities/ModelNameFormatter.swift")
        let localComputerName = try read("packages/mac-app/Sources/Services/Pairing/LocalComputerName.swift")

        let retiredTerm = "fall" + "back"
        #expect(!modelFormatter.localizedCaseInsensitiveContains(retiredTerm))
        #expect(modelFormatter.contains("displayOverride"))
        #expect(modelFormatter.contains("deterministic ID heuristics"))

        #expect(!localComputerName.localizedCaseInsensitiveContains(retiredTerm))
        #expect(localComputerName.contains("defaultName"))
    }
}
