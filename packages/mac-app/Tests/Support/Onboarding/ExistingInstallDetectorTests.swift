import Foundation
import Testing
@testable import TronMac

@Suite("ExistingInstallDetector")
struct ExistingInstallDetectorTests {
    @Test("clean app bundle with unregistered service is not installed")
    func cleanUnregisteredService() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let paths = try makeHelperFixture(in: tmp)

        let result = ExistingInstallDetector.detect(
            helperBundle: paths.helperBundle,
            helperBinary: paths.helperBinary,
            plistPath: paths.plistPath,
            bundleVersionResolver: { _ in nil },
            bundleSignatureProblemResolver: { _ in nil },
            serviceStatusResolver: { .notRegistered }
        )

        #expect(result == .none)
    }

    @Test("enabled service reports registered version")
    func enabledServiceIsRegistered() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let paths = try makeHelperFixture(in: tmp)

        let result = ExistingInstallDetector.detect(
            helperBundle: paths.helperBundle,
            helperBinary: paths.helperBinary,
            plistPath: paths.plistPath,
            bundleVersionResolver: { _ in "0.5.0" },
            bundleSignatureProblemResolver: { _ in nil },
            serviceStatusResolver: { .enabled }
        )

        #expect(result == .registered(version: "0.5.0"))
    }

    @Test("incomplete Gateway payload is surfaced before registration state")
    func incompleteGatewayPayloadIsPartial() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let paths = try makeHelperFixture(in: tmp)

        let result = ExistingInstallDetector.detect(
            helperBundle: paths.helperBundle,
            helperBinary: paths.helperBinary,
            plistPath: paths.plistPath,
            bundleVersionResolver: { _ in nil },
            bundleSignatureProblemResolver: { _ in nil },
            gatewayPayloadProblemResolver: { "The bundled Gateway is incomplete" },
            serviceStatusResolver: { .enabled }
        )

        if case .partial(let reason) = result {
            #expect(reason.contains("Gateway"))
        } else {
            Issue.record("expected partial")
        }
    }

    @Test("requiresApproval maps to install blocking state")
    func requiresApproval() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let paths = try makeHelperFixture(in: tmp)

        let result = ExistingInstallDetector.detect(
            helperBundle: paths.helperBundle,
            helperBinary: paths.helperBinary,
            plistPath: paths.plistPath,
            bundleVersionResolver: { _ in nil },
            bundleSignatureProblemResolver: { _ in nil },
            serviceStatusResolver: { .requiresApproval }
        )

        #expect(result == .requiresApproval)
    }

    @Test("missing bundled plist is partial")
    func missingPlistIsPartial() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let paths = try makeHelperFixture(in: tmp, includePlist: false)

        let result = ExistingInstallDetector.detect(
            helperBundle: paths.helperBundle,
            helperBinary: paths.helperBinary,
            plistPath: paths.plistPath,
            bundleVersionResolver: { _ in nil },
            bundleSignatureProblemResolver: { _ in nil },
            serviceStatusResolver: { .notRegistered }
        )

        if case .partial(let reason) = result {
            #expect(reason.contains("LaunchAgent"))
        } else {
            Issue.record("expected partial")
        }
    }

    @Test("bundled helper validation owns file and signature failures")
    func bundledHelperValidationOwnsFailures() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let helper = tmp.appendingPathComponent("Tron Agent.app", isDirectory: true)
        let binary = helper.appendingPathComponent("Contents/MacOS/tron", isDirectory: false)
        let plist = tmp.appendingPathComponent("com.tron.server.plist", isDirectory: false)

        func validate(signatureProblem: String? = nil) -> String? {
            ExistingInstallDetector.validateBundledHelper(
                helperBundle: helper,
                helperBinary: binary,
                plistPath: plist,
                signatureProblemResolver: { _ in signatureProblem }
            )
        }

        #expect(validate() == "Tron Agent.app is missing from the application bundle.")

        try FileManager.default.createDirectory(at: helper, withIntermediateDirectories: true)
        #expect(validate() == "Tron Agent.app is missing its tron executable.")

        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: binary)
        #expect(validate() == "The bundled LaunchAgent plist is missing.")

        try Data("<plist/>".utf8).write(to: plist)
        #expect(validate() == nil)
        #expect(
            validate(signatureProblem: "Tron Agent.app signature is invalid")
                == "Tron Agent.app signature is invalid"
        )
    }

    @Test("invalid helper signature is partial")
    func invalidSignatureIsPartial() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let paths = try makeHelperFixture(in: tmp)

        let result = ExistingInstallDetector.detect(
            helperBundle: paths.helperBundle,
            helperBinary: paths.helperBinary,
            plistPath: paths.plistPath,
            bundleVersionResolver: { _ in nil },
            bundleSignatureProblemResolver: { _ in "Tron Agent.app signature is invalid" },
            serviceStatusResolver: { .enabled }
        )

        if case .partial(let reason) = result {
            #expect(reason.contains("signature"))
        } else {
            Issue.record("expected partial")
        }
    }

    @Test("Gateway payload validation requires embedded runtime and production dependencies")
    func gatewayPayloadValidation() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let payload = tmp.appendingPathComponent("Gateway", isDirectory: true)
        let entrypoint = payload.appendingPathComponent("app/dist/index.js", isDirectory: false)
        let packageManifest = payload.appendingPathComponent("app/package.json", isDirectory: false)
        let packageLock = payload.appendingPathComponent("app/package-lock.json", isDirectory: false)
        let dependencies = payload.appendingPathComponent("app/node_modules", isDirectory: true)
        let runtime = payload.appendingPathComponent("runtime", isDirectory: true)
        try FileManager.default.createDirectory(at: entrypoint.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x2f, count: 1_024).write(to: entrypoint)
        #expect(ExistingInstallDetector.validateGatewayPayload(payloadRoot: payload) != nil)

        try Data("{}".utf8).write(to: packageManifest)
        try Data("{}".utf8).write(to: packageLock)
        try FileManager.default.createDirectory(at: dependencies, withIntermediateDirectories: true)
        for relativePath in [
            "@earendil-works/pi-agent-core/package.json",
            "@earendil-works/pi-ai/package.json",
            "@earendil-works/pi-coding-agent/package.json",
            "@earendil-works/pi-tui/package.json",
            "node-pty/package.json",
            "proper-lockfile/package.json",
            "ws/package.json",
        ] {
            let dependency = dependencies.appendingPathComponent(relativePath, isDirectory: false)
            try FileManager.default.createDirectory(at: dependency.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: dependency)
        }
        let helper = payload.appendingPathComponent("app/scripts/ensure-node-pty-helper.mjs", isDirectory: false)
        let updateHelper = payload.appendingPathComponent("app/scripts/gateway-payload-deploy.mjs", isDirectory: false)
        try FileManager.default.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("// test".utf8).write(to: helper)
        try Data("// update test".utf8).write(to: updateHelper)
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
        for architecture in ["arm64", "x64"] {
            try Data(repeating: 0, count: 1_048_576).write(to: runtime.appendingPathComponent("node-\(architecture)"))
        }

        try JSONEncoder().encode(
            GatewayPayloadManifest(
                channel: "stable",
                version: "1",
                gatewayVersion: "1",
                nodeVersion: "22",
                sourceRevision: "test-revision",
                runtimeEpoch: "test-epoch",
                payloadFingerprint: String(repeating: "a", count: 64)
            )
        ).write(to: payload.appendingPathComponent("manifest.json"))
        #expect(
            ExistingInstallDetector.validateGatewayPayload(
                payloadRoot: payload,
                isExecutable: { _ in true }
            ) == nil
        )
    }

    @Test("LaunchAgent plist requires current BundleProgram and associated wrapper IDs")
    func launchAgentPlistIsCurrent() {
        let plist = trackedLaunchAgentPlist(named: "com.tron.server.plist")

        #expect(ExistingInstallDetector.launchAgentPlistIsCurrent(
            plistPath: plist,
            label: "com.tron.server",
            port: 9847,
            bundleProgram: "Contents/Library/LoginItems/Tron Agent.app/Contents/MacOS/tron",
            environmentVariables: [
                TronPaths.gatewaySupervisionEnv: TronPaths.gatewaySupervisionValue,
                TronPaths.gatewayChannelEnv: TronPaths.productionGatewayChannel,
            ],
            associatedBundleIDs: ["com.tron.mac"]
        ))
    }

    @Test("LaunchAgent plist rejects retired log environment overrides")
    func launchAgentPlistRejectsRetiredLogEnvironmentOverride() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let plist = tmp.appendingPathComponent("com.tron.server.plist")
        let trackedPlist = trackedLaunchAgentPlist(named: "com.tron.server.plist")
        let data = try Data(contentsOf: trackedPlist)
        var decoded = try #require(
            PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        )
        decoded["EnvironmentVariables"] = ["RUST_LOG": "debug"]
        let modifiedData = try PropertyListSerialization.data(
            fromPropertyList: decoded,
            format: .xml,
            options: 0
        )
        try modifiedData.write(to: plist)

        #expect(!ExistingInstallDetector.launchAgentPlistIsCurrent(plistPath: plist))
    }

    @Test("ad-hoc helper signature is rejected before SMAppService registration")
    func adhocHelperSignatureRejected() {
        let problem = ExistingInstallDetector.codeSignatureIdentityProblem("""
        Executable=/tmp/Tron Agent.app/Contents/MacOS/tron
        Identifier=com.tron.server
        Signature=adhoc
        TeamIdentifier=not set
        """, expectedBundleIdentifier: "com.tron.server", helperName: "Tron Agent.app")

        #expect(problem?.contains("ad-hoc signed") == true)
    }

    @Test("helper signature identifier is exact for Stable")
    func helperSignatureIdentifierIsExactForStable() {
        #expect(ExistingInstallDetector.codeSignatureIdentityProblem(
            "Identifier=com.tron.server.dev\nTeamIdentifier=TEAM",
            expectedBundleIdentifier: TronGatewayProfile.stable.launchAgentLabel
        ) != nil)
    }

    @Test("team-signed helper identity is accepted")
    func teamSignedHelperIdentityAccepted() {
        let problem = ExistingInstallDetector.codeSignatureIdentityProblem("""
        Executable=/tmp/Tron Agent.app/Contents/MacOS/tron
        Identifier=com.tron.server
        TeamIdentifier=MYGKXH6TY4
        """)

        #expect(problem == nil)
    }

    private typealias HelperFixture = (helperBundle: URL, helperBinary: URL, plistPath: URL)

    private func makeHelperFixture(in tmp: URL, includePlist: Bool = true) throws -> HelperFixture {
        let helper = tmp.appendingPathComponent("Tron.app/Contents/Library/LoginItems/Tron Agent.app", isDirectory: true)
        let binary = helper.appendingPathComponent("Contents/MacOS/tron", isDirectory: false)
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: binary.path, contents: Data())
        let plist = tmp.appendingPathComponent("Tron.app/Contents/Library/LaunchAgents/com.tron.server.plist", isDirectory: false)
        if includePlist {
            try FileManager.default.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("<plist/>".utf8).write(to: plist)
        }
        return (helper, binary, plist)
    }

    private func trackedLaunchAgentPlist(named fileName: String) -> URL {
        macAppRoot()
            .appendingPathComponent("Sources/Resources/Library/LaunchAgents/\(fileName)")
    }
}
