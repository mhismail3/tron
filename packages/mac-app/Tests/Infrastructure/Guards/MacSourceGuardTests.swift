import Foundation
import Testing

@Suite("Mac source guard")
struct MacSourceGuardTests {

    @Test("required roots and banned roots stay explicit")
    func requiredRootsAndBannedRootsStayExplicit() throws {
        let macRoot = try Self.macAppRoot()
        let requiredRoots = [
            "Sources/App",
            "Sources/App/CommandMode",
            "Sources/App/Composition",
            "Sources/App/Lifecycle",
            "Sources/MenuBar/Actions",
            "Sources/MenuBar/Controller",
            "Sources/MenuBar/Presentation",
            "Sources/Server/Health",
            "Sources/Server/LaunchAgent",
            "Sources/Server/PairingToken",
            "Sources/Server/Paths",
            "Sources/Server/ProcessControl",
            "Sources/Support/Diagnostics",
            "Sources/Support/Feedback",
            "Sources/Support/Foundation",
            "Sources/Support/Onboarding",
            "Sources/Support/Pairing",
            "Sources/Support/Theme",
            "Sources/Wizard/Components",
            "Sources/Wizard/Flow",
            "Sources/Wizard/Steps",
            "Tests/Infrastructure/Fakes",
            "Tests/Infrastructure/Guards",
            "Tests/Server/Health",
            "Tests/Server/LaunchAgent",
            "Tests/Support/Foundation",
        ]
        for root in requiredRoots {
            #expect(
                Self.directoryExists(macRoot.appendingPathComponent(root)),
                "required roots missing: \(root)"
            )
        }

        let bannedRoots = [
            "Sources/Services",
            "Sources/Theme",
            "Sources/Views",
            "Sources/Server/Health/LaunchAgent",
            "Tests/Services",
        ]
        for root in bannedRoots {
            #expect(
                !FileManager.default.fileExists(atPath: macRoot.appendingPathComponent(root).path),
                "banned roots must not exist: \(root)"
            )
        }

        let serverPing = try Self.read(macRoot, "Sources/Server/Health/ServerPing.swift")
        for forbidden in ["SMAppService", "LiveLaunchAgentManager", "launchctl", "enum Subprocess"] {
            #expect(!serverPing.contains(forbidden), "ServerPing.swift must not own \(forbidden)")
        }

        let liveManager = try Self.read(macRoot, "Sources/Server/LaunchAgent/LiveLaunchAgentManager.swift")
        #expect(liveManager.contains("SMAppService"))
        #expect(liveManager.contains("LaunchAgentManaging"))

        let subprocess = try Self.read(macRoot, "Sources/Support/Foundation/Subprocess.swift")
        #expect(subprocess.contains("enum Subprocess"))
        #expect(subprocess.contains("ProcessResult"))
    }

    @Test("diagnostics redactor keeps iOS auth-field parity")
    func diagnosticsRedactorKeepsAuthFieldParity() throws {
        let macRoot = try Self.macAppRoot()
        let redactor = try Self.read(macRoot, "Sources/Support/Diagnostics/DiagnosticsRedactor.swift")
        let tests = try Self.read(macRoot, "Tests/Support/Diagnostics/DiagnosticsRedactorTests.swift")

        for required in [
            "accessToken",
            "refreshToken",
            "clientSecret",
            "authorizationCode",
            "authCode",
            "oauthCode",
            "swiftDescriptionTokenRegex",
            "redactSwiftDescriptionTokenValues",
        ] {
            #expect(redactor.contains(required), "Mac DiagnosticsRedactor missing auth redaction marker: \(required)")
        }

        for required in [
            "redactsCamelCaseAuthJSONValues",
            "redactsSwiftDescriptionAuthFields",
            "sk-live-abcdefghijklmnopqrstuvwxyz",
            "oauth-code-1234567890",
        ] {
            #expect(tests.contains(required), "Mac DiagnosticsRedactorTests missing coverage marker: \(required)")
        }
    }

    @Test("helper-resource layout preserves tracked helper skeletons")
    func helperResourceLayoutPreservesTrackedHelperSkeletons() throws {
        let macRoot = try Self.macAppRoot()
        let repoRoot = macRoot
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let trackedResources = [
            "Sources/Resources/AppIcon.icns",
            "Sources/Resources/Library/LaunchAgents/com.tron.server.plist",
            "Sources/Resources/Library/LaunchAgents/com.tron.server.dev.plist",
            "Sources/Resources/Library/LoginItems/Tron Server.app/Contents/Info.plist",
            "Sources/Resources/Library/LoginItems/Tron Server.app/Contents/Resources/AppIcon.icns",
            "Sources/Resources/Library/LoginItems/Tron Server Dev.app/Contents/Info.plist",
            "Sources/Resources/Library/LoginItems/Tron Server Dev.app/Contents/Resources/AppIcon.icns",
        ]

        for relativePath in trackedResources {
            #expect(
                FileManager.default.fileExists(atPath: macRoot.appendingPathComponent(relativePath).path),
                "tracked helper-resource layout missing \(relativePath)"
            )
            let repoRelativePath = "packages/mac-app/\(relativePath)"
            let isTracked = try Self.gitTracks(repoRelativePath, repoRoot: repoRoot)
            let isIgnored = try Self.gitIgnores(repoRelativePath, repoRoot: repoRoot)
            #expect(isTracked)
            #expect(!isIgnored)
        }

        let releaseLaunchAgent = try Self.read(
            macRoot,
            "Sources/Resources/Library/LaunchAgents/com.tron.server.plist"
        )
        #expect(releaseLaunchAgent.contains("<string>com.tron.server</string>"))
        #expect(
            releaseLaunchAgent.contains(
                "<string>Contents/Library/LoginItems/Tron Server.app/Contents/MacOS/tron</string>"
            )
        )

        let devLaunchAgent = try Self.read(
            macRoot,
            "Sources/Resources/Library/LaunchAgents/com.tron.server.dev.plist"
        )
        #expect(devLaunchAgent.contains("<string>com.tron.server.dev</string>"))
        #expect(
            devLaunchAgent.contains(
                "<string>Contents/Library/LoginItems/Tron Server Dev.app/Contents/MacOS/tron</string>"
            )
        )
    }

    @Test("staged-binary policy keeps helper executables ignored")
    func stagedBinaryPolicyKeepsHelperExecutablesIgnored() throws {
        let macRoot = try Self.macAppRoot()
        let repoRoot = macRoot
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let ignoredBinaries = [
            "Sources/Resources/Library/LoginItems/Tron Server.app/Contents/MacOS/tron",
            "Sources/Resources/Library/LoginItems/Tron Server.app/Contents/MacOS/tron-program-worker",
            "Sources/Resources/Library/LoginItems/Tron Server Dev.app/Contents/MacOS/tron",
            "Sources/Resources/Library/LoginItems/Tron Server Dev.app/Contents/MacOS/tron-program-worker",
        ]
        let gitignore = try Self.read(macRoot, ".gitignore")

        for relativePath in ignoredBinaries {
            let repoRelativePath = "packages/mac-app/\(relativePath)"
            #expect(!gitignore.contains("!\(relativePath)"))
            #expect(gitignore.contains(relativePath))
            let isTracked = try Self.gitTracks(repoRelativePath, repoRoot: repoRoot)
            let isIgnored = try Self.gitIgnores(repoRelativePath, repoRoot: repoRoot)
            #expect(!isTracked)
            #expect(isIgnored)
        }
    }

    @Test("bundle-agent --clean removes only ignored staged binaries")
    func bundleAgentCleanRemovesOnlyIgnoredStagedBinaries() throws {
        let macRoot = try Self.macAppRoot()
        let script = try Self.read(macRoot, "scripts/bundle-agent.sh")
        let cleanBlock = try #require(script.range(of: "if [ \"$do_clean\" -eq 1 ]; then"))
        let sourceResolution = try #require(script.range(of: "# --- source resolution"))
        let block = String(script[cleanBlock.lowerBound..<sourceResolution.lowerBound])

        #expect(script.contains("--clean"))
        #expect(block.contains("rm -f"))
        #expect(block.contains("$STAGING_PATH"))
        #expect(block.contains("$WORKER_STAGING_PATH"))
        #expect(block.contains("$DEV_STAGING_PATH"))
        #expect(block.contains("$DEV_WORKER_STAGING_PATH"))
        #expect(!block.contains("rm -rf"))
        #expect(!block.contains("HELPER_BUNDLE"))
        #expect(!block.contains("LAUNCH_AGENT_PLIST"))
        #expect(script.contains("remove ignored staged helper binaries"))
    }

    @Test("Mac Swift near-budget files require scorecard rows at 590 LOC")
    func macSwiftNearBudgetFilesRequireScorecardRowsAt590LOC() throws {
        let macRoot = try Self.macAppRoot()
        let repoRoot = macRoot
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let nearBudgetWarningLineCount = 590
        let scorecard = try String(
            contentsOf: repoRoot.appendingPathComponent(
                "packages/agent/docs/post-aha-adversarial-closeout-scorecard.md"
            ),
            encoding: .utf8
        )
        let roots = [
            macRoot.appendingPathComponent("Sources"),
            macRoot.appendingPathComponent("Tests"),
        ]
        let nearBudgetFiles = try roots.flatMap(Self.swiftFiles)
            .map { ($0, try Self.sourceLineCount($0)) }
            .filter { _, lineCount in lineCount >= nearBudgetWarningLineCount }

        for (url, lineCount) in nearBudgetFiles {
            let repoRelative = "packages/mac-app/\(Self.relativePath(url, from: macRoot))"
            #expect(
                scorecard.contains("| `\(repoRelative)` | \(lineCount) |"),
                "\(repoRelative) has \(lineCount) LOC and needs a concrete split-plan scorecard row"
            )
        }
    }

    private static func macAppRoot(filePath: String = #filePath) throws -> URL {
        var candidate = URL(fileURLWithPath: filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("project.yml").path)
                && directoryExists(candidate.appendingPathComponent("Sources"))
                && directoryExists(candidate.appendingPathComponent("Tests")) {
                return candidate
            }
            candidate.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }

    private static func directoryExists(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    private static func read(_ root: URL, _ relativePath: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private static func swiftFiles(in root: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return enumerator.compactMap { entry -> URL? in
            guard let url = entry as? URL else { return nil }
            guard url.pathExtension == "swift" else { return nil }
            return url
        }
    }

    private static func sourceLineCount(_ url: URL) throws -> Int {
        let source = try String(contentsOf: url, encoding: .utf8)
        return source.split(separator: "\n", omittingEmptySubsequences: false).count
    }

    private static func relativePath(_ url: URL, from root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        if path.hasPrefix(rootPath + "/") {
            return String(path.dropFirst(rootPath.count + 1))
        }
        return path
    }

    private static func gitTracks(_ relativePath: String, repoRoot: URL) throws -> Bool {
        try gitExitCode(["ls-files", "--error-unmatch", relativePath], repoRoot: repoRoot) == 0
    }

    private static func gitIgnores(_ relativePath: String, repoRoot: URL) throws -> Bool {
        try gitExitCode(["check-ignore", "--quiet", relativePath], repoRoot: repoRoot) == 0
    }

    private static func gitExitCode(_ arguments: [String], repoRoot: URL) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repoRoot.path] + arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}
