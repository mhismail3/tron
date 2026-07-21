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
            "Sources/App/Lifecycle",
            "Sources/MenuBar/Actions",
            "Sources/MenuBar/Presentation",
            "Sources/Server/Health",
            "Sources/Server/LaunchAgent",
            "Sources/Server/Paths",
            "Sources/Server/ProcessControl",
            "Sources/Support/Foundation",
            "Sources/Support/Onboarding",
            "Sources/Support/Pairing",
            "Sources/Support/Theme",
            "Sources/Wizard/Components",
            "Sources/Wizard/Flow",
            "Sources/Wizard/Steps",
            "Tests/App",
            "Tests/Infrastructure/Fakes",
            "Tests/MenuBar",
            "Tests/Server/Health",
            "Tests/Support",
            "Tests/Wizard",
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
            "Sources/Support/Observability",
            "Sources/App/Composition",
            "Sources/MenuBar/Controller",
            "Sources/Server/PairingToken",
            "Sources/Support/Diagnostics",
            "Sources/Support/Feedback",
            "Tests/App/CommandMode",
            "Tests/Infrastructure/Guards",
            "Tests/Server/LaunchAgent",
            "Tests/Server/PairingToken",
            "Tests/Support/Diagnostics",
            "Tests/Support/Feedback",
            "Tests/Support/Foundation",
            "Tests/Wizard/Components",
            "Tests/Wizard/Steps",
            "Tests/Mocks",
            "Tests/Observability",
            "Tests/Services",
        ]
        for root in bannedRoots {
            #expect(
                !FileManager.default.fileExists(atPath: macRoot.appendingPathComponent(root).path),
                "banned roots must not exist: \(root)"
            )
        }

        let allowedDirectSwiftFiles: [String: [String]] = [
            "Sources/App": ["EnvironmentSetup.swift"],
            "Sources/Server": ["BearerTokenReader.swift"],
            "Sources/MenuBar": ["MenuBarController.swift"],
            "Sources/Wizard": [],
        ]
        for (root, allowed) in allowedDirectSwiftFiles {
            let directSwiftFiles = try FileManager.default.contentsOfDirectory(
                at: macRoot.appendingPathComponent(root),
                includingPropertiesForKeys: nil
            )
            .filter { $0.pathExtension == "swift" }
            .map(\.lastPathComponent)
            .sorted()
            #expect(
                directSwiftFiles == allowed.sorted(),
                "source owner roots may contain only explicit single-file owners: \(root): \(directSwiftFiles)"
            )
        }

        let serverPing = try Self.read(macRoot, "Sources/Server/Health/ServerPing.swift")
        for forbidden in ["SMAppService", "LiveLaunchAgentManager", "launchctl", "enum Subprocess"] {
            #expect(!serverPing.contains(forbidden), "ServerPing.swift must not own \(forbidden)")
        }

        let liveManager = try Self.read(macRoot, "Sources/Server/LaunchAgent/LiveLaunchAgentManager.swift")
        let processProbe = try Self.read(macRoot, "Sources/Server/ProcessControl/ServerProcessProbe.swift")
        #expect(liveManager.contains("SMAppService"))
        #expect(liveManager.contains("LaunchAgentManaging"))
        #expect(liveManager.contains("ServerProcessProbe.processElapsedTime(pid: pid)"))
        #expect(!liveManager.contains("\"etime=\""))
        #expect(processProbe.contains("\"etime=\""))

        let launchAgentContract = try Self.read(macRoot, "Sources/Server/LaunchAgent/LaunchAgentManaging.swift")
        let installStep = try Self.read(macRoot, "Sources/Wizard/Steps/InstallStep.swift")
        #expect(launchAgentContract.contains("enum LaunchAgentLoader"))
        #expect(!installStep.contains("enum LaunchAgentLoader"))

        let subprocess = try Self.read(macRoot, "Sources/Support/Foundation/Subprocess.swift")
        #expect(subprocess.contains("enum Subprocess"))
        #expect(subprocess.contains("ProcessResult"))

        let menuController = try Self.read(macRoot, "Sources/MenuBar/MenuBarController.swift")
        let actionHandler = try Self.read(macRoot, "Sources/MenuBar/Actions/MenuBarActionHandler.swift")
        #expect(menuController.contains("private let setup: EnvironmentSetup"))
        #expect(menuController.components(separatedBy: ".environment(\\.environmentSetup, setup)").count - 1 == 2)
        for method in ["showPairingInfoWindow", "showLogsWindow"] {
            #expect(menuController.contains("func \(method)()"))
            #expect(actionHandler.contains("menuBarController?.\(method)()"))
            #expect(!menuController.contains("\(method)(setup:"))
        }
        #expect(!actionHandler.contains("private func showPairingInfo()"))
        #expect(!actionHandler.contains("private func viewLogs()"))

        let project = try Self.read(macRoot, "project.yml")
        for owner in [
            "Debug:\n          PRODUCT_BUNDLE_IDENTIFIER: com.tron.mac.dev",
            "Release:\n          PRODUCT_BUNDLE_IDENTIFIER: com.tron.mac",
            "PRODUCT_BUNDLE_IDENTIFIER: com.tron.mac.tests",
        ] {
            #expect(project.contains(owner), "project.yml must own \(owner)")
        }
        for configuration in ["Debug", "Release"] {
            let xcconfig = try Self.read(macRoot, "Configuration/\(configuration).xcconfig")
            #expect(!xcconfig.contains("PRODUCT_BUNDLE_IDENTIFIER"))
        }
    }

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
