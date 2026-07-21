import Foundation
import Testing

@Suite("Mac source guard")
struct MacSourceGuardTests {

    @Test("theme owns adaptive tokens without global gradient aliases")
    func themeOwnsAdaptiveTokensWithoutGlobalGradientAliases() throws {
        let macRoot = try Self.macAppRoot()
        let source = try Self.read(macRoot, "Sources/Support/Theme/TronColors.swift")

        #expect(source.contains("init(lightHex: String, darkHex: String)"))
        #expect(source.contains("convenience init(hex: String)"))
        #expect(source.components(separatedBy: "init(hex: String)").count - 1 == 1)
        for token in ["tronEmerald", "tronEmeraldDeep", "tronMint", "tronSuccess"] {
            #expect(source.contains("static let \(token) = Color(lightHex:"))
        }
        #expect(!source.contains("tronEmeraldGradient"))
        #expect(!source.contains("extension ShapeStyle where Self == Color"))
    }

    @Test("diagnostics redactor keeps iOS auth-field parity")
    func diagnosticsRedactorKeepsAuthFieldParity() throws {
        let macRoot = try Self.macAppRoot()
        let redactor = try Self.read(macRoot, "Sources/Support/DiagnosticsRedactor.swift")
        let tests = try Self.read(macRoot, "Tests/Support/DiagnosticsRedactorTests.swift")

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

    @Test("status poller keeps a latest-only bounded stream")
    func statusPollerKeepsLatestOnlyBoundedStream() throws {
        let macRoot = try Self.macAppRoot()
        let source = try Self.read(macRoot, "Sources/Server/Health/ServerStatusPoller.swift")

        #expect(source.contains("struct ServerStatusPoller: Sendable"))
        #expect(source.contains("AsyncStream(bufferingPolicy: .bufferingNewest(1))"))
        #expect(source.contains("continuation.onTermination"))
        #expect(source.contains("task.cancel()"))
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
            "Sources/Resources/Library/LoginItems/Tron Server Dev.app/Contents/Info.plist",
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

        for (relativePath, identifier, displayName) in [
            ("Sources/Resources/Library/LoginItems/Tron Server.app/Contents/Info.plist", "com.tron.server", "Tron Server"),
            ("Sources/Resources/Library/LoginItems/Tron Server Dev.app/Contents/Info.plist", "com.tron.server.dev", "Tron Server Dev"),
        ] {
            let info = try Self.read(macRoot, relativePath)
            #expect(info.contains("<key>CFBundleIdentifier</key>\n    <string>\(identifier)</string>"))
            #expect(info.contains("<key>CFBundleName</key>\n    <string>\(displayName)</string>"))
            #expect(info.contains("<key>CFBundleDisplayName</key>\n    <string>\(displayName)</string>"))
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

        let bundleScript = try Self.read(macRoot, "scripts/bundle-agent.sh")
        #expect(bundleScript.contains("tracked_plists=("))
        #expect(bundleScript.contains("tracked helper metadata is missing"))
        for destination in ["HELPER_RESOURCES", "DEV_HELPER_RESOURCES"] {
            #expect(
                bundleScript.contains("cp \"$RESOURCES_DIR/AppIcon.icns\" \"$\(destination)/AppIcon.icns\"")
            )
        }
        for plistVariable in [
            "HELPER_INFO_PLIST",
            "DEV_HELPER_INFO_PLIST",
            "LAUNCH_AGENT_PLIST",
            "DEV_LAUNCH_AGENT_PLIST",
        ] {
            #expect(!bundleScript.contains("cat > \"$\(plistVariable)\""))
        }
    }

    @Test("generated helper payload policy keeps outputs ignored")
    func generatedHelperPayloadPolicyKeepsOutputsIgnored() throws {
        let macRoot = try Self.macAppRoot()
        let repoRoot = macRoot
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let ignoredPayloads = [
            "Sources/Resources/Library/LoginItems/Tron Server.app/Contents/MacOS/tron",
            "Sources/Resources/Library/LoginItems/Tron Server Dev.app/Contents/MacOS/tron",
            "Sources/Resources/Library/LoginItems/Tron Server.app/Contents/Resources/AppIcon.icns",
            "Sources/Resources/Library/LoginItems/Tron Server Dev.app/Contents/Resources/AppIcon.icns",
        ]
        let gitignore = try Self.read(macRoot, ".gitignore")

        for relativePath in ignoredPayloads {
            let repoRelativePath = "packages/mac-app/\(relativePath)"
            #expect(!gitignore.contains("!\(relativePath)"))
            #expect(gitignore.contains(relativePath))
            let isTracked = try Self.gitTracks(repoRelativePath, repoRoot: repoRoot)
            let isIgnored = try Self.gitIgnores(repoRelativePath, repoRoot: repoRoot)
            #expect(!isTracked)
            #expect(isIgnored)
        }
    }

    @Test("bundle-agent --clean removes only ignored staged payloads")
    func bundleAgentCleanRemovesOnlyIgnoredStagedPayloads() throws {
        let macRoot = try Self.macAppRoot()
        let script = try Self.read(macRoot, "scripts/bundle-agent.sh")
        let cleanBlock = try #require(script.range(of: "if [ \"$do_clean\" -eq 1 ]; then"))
        let sourceResolution = try #require(script.range(of: "# --- source resolution"))
        let block = String(script[cleanBlock.lowerBound..<sourceResolution.lowerBound])

        #expect(script.contains("--clean"))
        #expect(block.contains("rm -f"))
        #expect(block.contains("$STAGING_PATH"))
        #expect(block.contains("$DEV_STAGING_PATH"))
        #expect(block.contains("$HELPER_RESOURCES/AppIcon.icns"))
        #expect(block.contains("$DEV_HELPER_RESOURCES/AppIcon.icns"))
        #expect(!block.contains("rm -rf"))
        #expect(!block.contains("HELPER_BUNDLE"))
        #expect(!block.contains("LAUNCH_AGENT_PLIST"))
        #expect(script.contains("remove ignored staged helper payloads"))
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
