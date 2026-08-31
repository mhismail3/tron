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

    @Test("Stable transport never falls back to loopback")
    func stableTransportNeverFallsBackToLoopback() throws {
        let macRoot = try Self.macAppRoot()
        let source = try Self.read(macRoot, "Sources/App/EnvironmentSetup.swift")
        #expect(source.contains("resolveTailscaleHost"))
        #expect(!source.contains("?? \"127.0.0.1\""))
        #expect(source.contains("guard let host else { return .unreachable }"))
        #expect(source.contains("throw GatewayRestartClient.Failure.transport"))
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
            "Sources/Resources/Library/LoginItems/Tron Agent.app/Contents/Info.plist",
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
        #expect(releaseLaunchAgent.contains("<key>RunAtLoad</key>\n    <true/>"))
        #expect(releaseLaunchAgent.contains("<key>KeepAlive</key>\n    <true/>"))
        #expect(!releaseLaunchAgent.contains("SuccessfulExit"))
        #expect(!releaseLaunchAgent.contains("Crashed"))
        #expect(
            releaseLaunchAgent.contains(
                "<string>Contents/Library/LoginItems/Tron Agent.app/Contents/MacOS/tron</string>"
            )
        )

        #expect(!FileManager.default.fileExists(
            atPath: macRoot.appendingPathComponent("Sources/Resources/Library/LaunchAgents/com.tron.server.dev.plist").path
        ))
        #expect(!FileManager.default.fileExists(
            atPath: macRoot.appendingPathComponent("Sources/Resources/Library/LoginItems/Tron Agent Dev.app").path
        ))

        let ensureScript = try Self.read(macRoot, "scripts/ensure-gateway-bundle.sh")
        #expect(ensureScript.contains("bundle-gateway.sh"))
        #expect(ensureScript.contains("--verify-only"))
        #expect(ensureScript.contains("failed verification; explicitly rebuilding"))
        #expect(!ensureScript.contains("exec \"$SCRIPT_DIR/bundle-gateway.sh\""))

        let bundleScript = try Self.read(macRoot, "scripts/bundle-gateway.sh")
        #expect(bundleScript.contains("manifest.json"))
        #expect(bundleScript.contains("tron-gateway-payload"))
        #expect(bundleScript.contains("node-arm64"))
        #expect(bundleScript.contains("node-x64"))
        #expect(bundleScript.contains("stage_xcodegen"))
        #expect(bundleScript.contains("TRON_CI_XCODEGEN_BINARY_SHA256"))
        #expect(bundleScript.contains("TRON_CI_XCODEGEN_PRESETS_SHA256"))
        #expect(bundleScript.contains("bin-$arch"))
        #expect(bundleScript.contains("$alias_dir/node"))
        #expect(bundleScript.contains("safe_remove_tree \"$alias_dir\"\n    mkdir -p \"$alias_dir\""))
        #expect(bundleScript.contains("../node-$arch"))
        #expect(bundleScript.contains("$alias_dir/pi"))
        #expect(bundleScript.contains("pi-coding-agent/dist/cli.js"))
        #expect(bundleScript.contains("node_modules"))
        #expect(bundleScript.contains("NODE_VERSION_FILE=\"$REPO_ROOT/.node-version\""))
        #expect(bundleScript.contains("NODE_VERSION=\"$(<\"$NODE_VERSION_FILE\")\""))
        #expect(!bundleScript.contains("NODE_VERSION=\"22.22.0\""))
        #expect(bundleScript.contains("NODE_ARM64_SHA256=\"913b144fdb40638b1acef7974ab3c33fbd527cc0974cb5da467ab1e6ac51b4d4\""))
        #expect(bundleScript.contains("NODE_X64_SHA256=\"bf0e0ff20d4e5a16436d1ec372e47161e52be8e487db8070ae3f06b01efbba0c\""))
        #expect(bundleScript.contains("validate_node_runtime"))
        #expect(!bundleScript.contains("$destination --version"))
        #expect(bundleScript.contains("Mach-O"))
        #expect(bundleScript.contains("lipo -archs"))
        #expect(bundleScript.contains("checksum mismatch"))
        #expect(bundleScript.contains("architecture mismatch"))
        #expect(bundleScript.contains("TRON_NODE_BIN"))
        #expect(!bundleScript.contains("TRON_NPM_BIN"))
        #expect(bundleScript.contains("command -v node"))
        #expect(bundleScript.contains("${NVM_DIR:-${HOME:-}/.nvm}/versions/node/v${NODE_VERSION}/bin/node"))
        #expect(bundleScript.contains("/opt/homebrew/bin/node"))
        #expect(bundleScript.contains("/usr/local/bin/node"))
        #expect(bundleScript.contains("\"$NPM_BIN\" ci --omit=dev"))
        #expect(bundleScript.contains("\"$NODE_BIN\" -p"))
        #expect(!bundleScript.contains("&& npm "))
        #expect(!bundleScript.contains("$(node "))
        #expect(bundleScript.contains("tron-gateway-launcher.c"))
        #expect(bundleScript.contains("--fingerprint \"$PAYLOAD_DIR\""))
        #expect(bundleScript.contains("gateway-payload-deploy.mjs"))
        #expect(bundleScript.contains("cmp -s \"$REPO_ROOT/scripts/gateway-payload-deploy.mjs\" \"$APP_DIR/scripts/gateway-payload-deploy.mjs\""))
        #expect(bundleScript.contains("staged Gateway deployment helper does not match canonical source"))
        #expect(bundleScript.contains("dependencyTreeCoverage"))
        #expect(bundleScript.contains("protocolVersion"))
        #expect(bundleScript.contains("minProtocolVersion"))
        #expect(bundleScript.contains("verify-gateway-protocol-contract.py"))
        #expect(bundleScript.contains("runtimeEpoch"))
        #expect(bundleScript.contains("--verify-only"))
        #expect(bundleScript.contains("verify-gateway-payload.sh"))
        #expect(bundleScript.contains("-arch arm64 -arch x86_64"))
        #expect(bundleScript.contains("-arch arm64 -arch x86_64"))
        #expect(!bundleScript.contains("cargo build"))

        let launchdFixture = try Self.read(macRoot, "scripts/test-launchd-relaunch-fixture.sh")
        #expect(launchdFixture.contains("TRON_RUN_LAUNCHD_FIXTURE"))
        #expect(launchdFixture.contains("com.example.tron-gateway-relaunch"))
        #expect(launchdFixture.contains("trap cleanup EXIT INT TERM HUP"))
        #expect(launchdFixture.contains("second-selection"))
        #expect(!launchdFixture.contains("com.tron.server"))
        #expect(!launchdFixture.contains("9847"))
        #expect(!launchdFixture.contains("~/.tron"))

        let verifierScript = try Self.read(macRoot, "scripts/verify-gateway-payload.sh")
        for required in ["--verify-payload", "NODE_ARM64_SHA256", "NODE_X64_SHA256", "payload tree is writable", "Mach-O", "lipo -archs", "realpath", "runtime/bin-", "runtime/xcodegen/bin/xcodegen", "TRON_CI_XCODEGEN_VERSION", "TRON_CI_XCODEGEN_PRESETS_SHA256", "alias target is not exact", "-arch arm64 -arch x86_64", "cmp -s", "GATEWAY_VERSION", "SOURCE_REVISION"] {
            #expect(verifierScript.contains(required), "payload verifier missing marker: \(required)")
        }

        let hashScript = try Self.read(macRoot, "scripts/hash-gateway-payload.sh")
        #expect(hashScript.contains("find \"$ROOT/app\" \"$ROOT/runtime\""))
        #expect(hashScript.contains("-type f -o -type l"))
        #expect(hashScript.contains("shasum -a 256"))
        #expect(hashScript.contains("runtime/xcodegen/bin/xcodegen"))

        let installVerifier = try Self.read(repoRoot, "scripts/verify-mac-install.sh")
        #expect(installVerifier.contains("if [[ \"$payload\" == \"$bundled\" ]]; then"))
        #expect(installVerifier.contains("incompatible or invalid external selection rejected; bundled payload selected"))

        let launcher = try Self.read(macRoot, "scripts/tron-gateway-launcher.c")
        for required in ["TRON_GATEWAY_CHANNEL", "current.json", "realpath", "O_NOFOLLOW", "MAX_MANIFEST_BYTES", "tron-gateway-selection", "TRON_GATEWAY_PROTOCOL_VERSION", "TRON_GATEWAY_MIN_PROTOCOL_VERSION", "TRON_GATEWAY_SOURCE_REVISION", "TRON_GATEWAY_BUILD_FINGERPRINT", "TRON_GATEWAY_RUNTIME_EPOCH", "TRON_GATEWAY_UPDATE_HELPER", "gateway-payload-deploy.mjs", "runtime/xcodegen/bin/xcodegen", "immutable_tree", "required_runtime_alias", "required_pi_alias", "../node-%s", "pi-coding-agent/dist/cli.js", "CC_SHA256", "S_IWUSR", "--verify-payload", "nodeVersion"] {
            #expect(launcher.contains(required), "launcher missing external payload safety marker: \(required)")
        }

        let project = try Self.read(macRoot, "project.yml")
        #expect(project.contains("name: Ensure Bundled Gateway Payload"))
        #expect(project.contains("ensure-gateway-bundle.sh"))
        #expect(project.contains("TRON_GATEWAY_PROTOCOL_VERSION: \"4\""))
        #expect(project.contains("TRON_GATEWAY_MIN_PROTOCOL_VERSION: \"4\""))
        #expect(project.contains("verify-gateway-protocol-contract.py"))
        #expect(project.contains("- \"Gateway/**\""))
        #expect(project.contains("/usr/bin/rsync -a \"$GATEWAY_SRC/\" \"$GATEWAY_DST/\""))
        #expect(project.contains("find \"$GATEWAY_DST\" -type f"))
        #expect(project.contains("NODE_ENTITLEMENTS=\"$SRCROOT/TronNode.entitlements\""))
        #expect(project.contains("--entitlements \"$NODE_ENTITLEMENTS\""))

        let nodeEntitlements = try Self.read(macRoot, "TronNode.entitlements")
        #expect(nodeEntitlements.contains("com.apple.security.cs.allow-jit"))
    }

    @Test("Node runtime validation rejects tampered, wrong-version, and wrong-architecture binaries")
    func nodeRuntimeValidationRejectsInvalidBinaries() throws {
        let macRoot = try Self.macAppRoot()
        let script = try Self.read(macRoot, "scripts/bundle-gateway.sh")

        // Keep these as source guards because the generated runtime payload is
        // intentionally ignored and must not be checked into the repository.
        for rejection in [
            "[[ \"$actual\" == \"$expected\" ]] ||",
            "[[ \"$file_description\" == *\"Mach-O\"* ]] ||",
            "[[ \"$lipo_arches\" == \"$expected_arch\" ]] ||",
            "neither file nor lipo is available",
        ] {
            #expect(script.contains(rejection), "Node runtime guard missing rejection: \(rejection)")
        }
        #expect(script.components(separatedBy: "validate_node_runtime \"$arch\" \"$expected\"").count - 1 == 2)
    }

    @Test("generated helper payload policy keeps outputs ignored")
    func generatedHelperPayloadPolicyKeepsOutputsIgnored() throws {
        let macRoot = try Self.macAppRoot()
        let repoRoot = macRoot
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let ignoredPayloads = [
            "Sources/Resources/Library/LoginItems/Tron Agent.app/Contents/MacOS/tron",
            "Sources/Resources/Library/LoginItems/Tron Agent.app/Contents/Resources/AppIcon.icns",
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
        #expect(packageScript.contains("codesign --verify --deep --strict"))
        #expect(packageScript.contains("com.apple.security.cs.allow-jit"))
        #expect(packageScript.contains("--fingerprint"))
        #expect(packageScript.contains("payloadFingerprint"))
        #expect(packageScript.contains("lipo -archs"))
        #expect(!packageScript.contains("$runtime --version"))
        #expect(packageScript.contains("mounted DMG"))
        let cleanBlock = try #require(script.range(of: "if ((clean)); then"))
        let requiredSources = try #require(script.range(of: "required=("))
        let block = String(script[cleanBlock.lowerBound..<requiredSources.lowerBound])

        #expect(script.contains("--clean"))
        #expect(block.contains("safe_remove_tree \"$PAYLOAD_DIR\""))
        #expect(block.contains("safe_remove_tree \"$HELPER_DIR/MacOS/tron\""))
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
