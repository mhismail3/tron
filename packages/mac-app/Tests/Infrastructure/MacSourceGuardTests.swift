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
            "Sources/Resources/Library/LoginItems/Tron Agent.app/Contents/Info.plist",
            "Sources/Resources/Library/LoginItems/Tron Agent Dev.app/Contents/Info.plist",
        ]

        for relativePath in trackedResources {
            #expect(
                FileManager.default.fileExists(atPath: macRoot.appendingPathComponent(relativePath).path),
                "tracked helper-resource layout missing \(relativePath)"
            )
            let repoRelativePath = "packages/mac-app/\(relativePath)"
            let isIgnored = try Self.gitIgnores(repoRelativePath, repoRoot: repoRoot)
            #expect(!isIgnored)
        }

        for (relativePath, identifier, displayName) in [
            ("Sources/Resources/Library/LoginItems/Tron Agent.app/Contents/Info.plist", "com.tron.server", "Tron Agent"),
            ("Sources/Resources/Library/LoginItems/Tron Agent Dev.app/Contents/Info.plist", "com.tron.server.dev", "Tron Agent Dev"),
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
        #expect(releaseLaunchAgent.contains("<key>TRON_GATEWAY_SUPERVISED</key>\n        <string>1</string>"))
        #expect(releaseLaunchAgent.contains("<key>TRON_GATEWAY_CHANNEL</key>\n        <string>stable</string>"))
        #expect(
            releaseLaunchAgent.contains(
                "<string>Contents/Library/LoginItems/Tron Agent.app/Contents/MacOS/tron</string>"
            )
        )

        let devLaunchAgent = try Self.read(
            macRoot,
            "Sources/Resources/Library/LaunchAgents/com.tron.server.dev.plist"
        )
        #expect(devLaunchAgent.contains("<string>com.tron.server.dev</string>"))
        #expect(devLaunchAgent.contains("<key>TRON_GATEWAY_SUPERVISED</key>\n        <string>1</string>"))
        #expect(devLaunchAgent.contains("<key>TRON_GATEWAY_CHANNEL</key>\n        <string>dev</string>"))
        #expect(devLaunchAgent.contains("<key>TRON_AGENT_DIR_NAME</key>\n        <string>agent-dev</string>"))
        #expect(
            devLaunchAgent.contains(
                "<string>Contents/Library/LoginItems/Tron Agent Dev.app/Contents/MacOS/tron</string>"
            )
        )

        let ensureScript = try Self.read(macRoot, "scripts/ensure-gateway-bundle.sh")
        #expect(ensureScript.contains("bundle-gateway.sh"))
        #expect(ensureScript.contains("manifest.json"))
        #expect(ensureScript.contains("tron-gateway-payload"))
        #expect(ensureScript.contains("node-arm64"))
        #expect(ensureScript.contains("node-x64"))
        #expect(ensureScript.contains("node_modules"))

        let bundleScript = try Self.read(macRoot, "scripts/bundle-gateway.sh")
        #expect(bundleScript.contains("NODE_VERSION=\"22.22.0\""))
        #expect(bundleScript.contains("NODE_ARM64_SHA256="))
        #expect(bundleScript.contains("NODE_X64_SHA256="))
        #expect(bundleScript.contains("npm ci --omit=dev"))
        #expect(bundleScript.contains("tron-gateway-launcher.c"))
        #expect(bundleScript.contains("hash-gateway-payload.sh"))
        #expect(bundleScript.contains("gateway-payload-deploy.mjs"))
        #expect(bundleScript.contains("dependencyTreeCoverage"))
        #expect(bundleScript.contains("runtimeEpoch"))
        #expect(bundleScript.contains("-arch arm64 -arch x86_64"))
        #expect(!bundleScript.contains("cargo build"))

        let hashScript = try Self.read(macRoot, "scripts/hash-gateway-payload.sh")
        #expect(hashScript.contains("find app runtime -type f"))
        #expect(hashScript.contains("shasum -a 256"))

        let launcher = try Self.read(macRoot, "scripts/tron-gateway-launcher.c")
        for required in ["TRON_GATEWAY_CHANNEL", "current.json", "realpath", "O_NOFOLLOW", "MAX_MANIFEST_BYTES", "tron-gateway-selection", "TRON_GATEWAY_SOURCE_REVISION", "TRON_GATEWAY_BUILD_FINGERPRINT", "TRON_GATEWAY_RUNTIME_EPOCH", "TRON_GATEWAY_UPDATE_HELPER", "gateway-payload-deploy.mjs", "immutable_tree", "S_IWUSR"] {
            #expect(launcher.contains(required), "launcher missing external payload safety marker: \(required)")
        }

        let project = try Self.read(macRoot, "project.yml")
        #expect(project.contains("name: Ensure Bundled Gateway Payload"))
        #expect(project.contains("ensure-gateway-bundle.sh"))
        #expect(project.contains("- \"Gateway/**\""))
        #expect(project.contains("ditto \"$GATEWAY_SRC\" \"$GATEWAY_DST\""))
        #expect(project.contains("find \"$GATEWAY_DST\" -type f"))
        #expect(project.contains("NODE_ENTITLEMENTS=\"$SRCROOT/TronNode.entitlements\""))
        #expect(project.contains("--entitlements \"$NODE_ENTITLEMENTS\""))

        let nodeEntitlements = try Self.read(macRoot, "TronNode.entitlements")
        #expect(nodeEntitlements.contains("com.apple.security.cs.allow-jit"))
    }

    @Test("generated helper payload policy keeps outputs ignored")
    func generatedHelperPayloadPolicyKeepsOutputsIgnored() throws {
        let macRoot = try Self.macAppRoot()
        let repoRoot = macRoot
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let ignoredPayloads = [
            "Sources/Resources/Library/LoginItems/Tron Agent.app/Contents/MacOS/tron",
            "Sources/Resources/Library/LoginItems/Tron Agent Dev.app/Contents/MacOS/tron",
            "Sources/Resources/Library/LoginItems/Tron Agent.app/Contents/Resources/AppIcon.icns",
            "Sources/Resources/Library/LoginItems/Tron Agent Dev.app/Contents/Resources/AppIcon.icns",
            "Sources/Resources/Gateway/",
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

    @Test("bundle-gateway --clean removes only generated payloads")
    func bundleGatewayCleanRemovesOnlyGeneratedPayloads() throws {
        let macRoot = try Self.macAppRoot()
        let script = try Self.read(macRoot, "scripts/bundle-gateway.sh")
        let packageScript = try Self.read(macRoot, "scripts/package-dmg.sh")
        #expect(packageScript.contains("verify_app_bundle"))
        #expect(packageScript.contains("com.tron.server.plist"))
        #expect(packageScript.contains("node-arm64"))
        #expect(packageScript.contains("node-x64"))
        #expect(packageScript.contains("app/node_modules"))
        #expect(packageScript.contains("mounted DMG"))
        let cleanBlock = try #require(script.range(of: "if ((clean)); then"))
        let requiredSources = try #require(script.range(of: "required=("))
        let block = String(script[cleanBlock.lowerBound..<requiredSources.lowerBound])

        #expect(script.contains("--clean"))
        #expect(block.contains("rm -rf \"$PAYLOAD_DIR\""))
        #expect(block.contains("rm -f \"${launchers[@]}\""))
        #expect(!block.contains("Info.plist"))
        #expect(!block.contains("LaunchAgents"))
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
