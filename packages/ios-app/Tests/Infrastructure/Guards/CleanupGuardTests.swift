import Foundation
import Testing

@Suite("Cleanup Guards")
struct CleanupGuardTests {
    private var iosRoot: URL {
        var candidate = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("project.yml").path) {
                return candidate
            }
            candidate.deleteLastPathComponent()
        }
        preconditionFailure("Could not locate packages/ios-app from \(#filePath)")
    }

    private var repoRoot: URL {
        iosRoot
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func read(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    @Test("Font settings no longer carries retired casual-axis storage")
    func fontSettingsDoesNotRetainRetiredCasualAxisMigration() throws {
        let source = try read("packages/ios-app/Sources/UI/Theme/FontSettings.swift")

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
        let modelFormatter = try read("packages/ios-app/Sources/Support/Foundation/Formatting/ModelNameFormatter.swift")
        let localComputerName = try read("packages/mac-app/Sources/Support/Pairing/LocalComputerName.swift")

        let retiredTerm = "fall" + "back"
        #expect(!modelFormatter.localizedCaseInsensitiveContains(retiredTerm))
        #expect(modelFormatter.contains("displayOverride"))
        #expect(modelFormatter.contains("deterministic ID heuristics"))

        #expect(!localComputerName.localizedCaseInsensitiveContains(retiredTerm))
        #expect(localComputerName.contains("defaultName"))
    }
}
