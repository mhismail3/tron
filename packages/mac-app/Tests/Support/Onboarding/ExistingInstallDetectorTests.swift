import Foundation
import Testing
import Darwin
@testable import TronMac

@Suite("ExistingInstallDetector")
struct ExistingInstallDetectorTests {
    @Test("clean app bundle with unregistered service is not installed")
    func cleanUnregisteredService() async throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let paths = try makeHelperFixture(in: tmp)

        let result = await ExistingInstallDetector.detect(
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
    func enabledServiceIsRegistered() async throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let paths = try makeHelperFixture(in: tmp)

        let result = await ExistingInstallDetector.detect(
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
    func incompleteGatewayPayloadIsPartial() async throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let paths = try makeHelperFixture(in: tmp)

        let result = await ExistingInstallDetector.detect(
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
    func requiresApproval() async throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let paths = try makeHelperFixture(in: tmp)

        let result = await ExistingInstallDetector.detect(
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
    func missingPlistIsPartial() async throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let paths = try makeHelperFixture(in: tmp, includePlist: false)

        let result = await ExistingInstallDetector.detect(
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
    func bundledHelperValidationOwnsFailures() async throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let helper = tmp.appendingPathComponent("Tron Agent.app", isDirectory: true)
        let binary = helper.appendingPathComponent("Contents/MacOS/tron", isDirectory: false)
        let plist = tmp.appendingPathComponent("com.tron.server.plist", isDirectory: false)

        func validate(signatureProblem: String? = nil) async -> String? {
            await ExistingInstallDetector.validateBundledHelper(
                helperBundle: helper,
                helperBinary: binary,
                plistPath: plist,
                signatureProblemResolver: { _ in signatureProblem }
            )
        }

        #expect(await validate() == "Tron Agent.app is missing from the application bundle.")

        try FileManager.default.createDirectory(at: helper, withIntermediateDirectories: true)
        #expect(await validate() == "Tron Agent.app is missing its tron executable.")

        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: binary)
        #expect(await validate() == "The bundled LaunchAgent plist is missing.")

        try Data("<plist/>".utf8).write(to: plist)
        #expect(await validate() == nil)
        #expect(
            await validate(signatureProblem: "Tron Agent.app signature is invalid")
                == "Tron Agent.app signature is invalid"
        )
    }

    @Test("invalid helper signature is partial")
    func invalidSignatureIsPartial() async throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let paths = try makeHelperFixture(in: tmp)

        let result = await ExistingInstallDetector.detect(
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

    @Test("LaunchAgent plist requires Boolean RunAtLoad and KeepAlive")
    func launchAgentPlistRequiresBooleanSupervision() throws {
        let trackedPlist = trackedLaunchAgentPlist(named: "com.tron.server.plist")
        let data = try Data(contentsOf: trackedPlist)
        let source = try #require(
            PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        )
        for (key, value) in [
            ("RunAtLoad", false as Any),
            ("KeepAlive", false as Any),
            ("KeepAlive", ["SuccessfulExit": false] as Any),
            ("KeepAlive", "true" as Any),
        ] {
            let tmp = TestTempDir.make()
            defer { TestTempDir.cleanup(tmp) }
            let plist = tmp.appendingPathComponent("com.tron.server.plist")
            var modified = source
            modified[key] = value
            try PropertyListSerialization.data(fromPropertyList: modified, format: .xml, options: 0).write(to: plist)
            #expect(!ExistingInstallDetector.launchAgentPlistIsCurrent(plistPath: plist))
        }
        for key in ["RunAtLoad", "KeepAlive"] {
            let tmp = TestTempDir.make()
            defer { TestTempDir.cleanup(tmp) }
            let plist = tmp.appendingPathComponent("com.tron.server.plist")
            var modified = source
            modified.removeValue(forKey: key)
            try PropertyListSerialization.data(fromPropertyList: modified, format: .xml, options: 0).write(to: plist)
            #expect(!ExistingInstallDetector.launchAgentPlistIsCurrent(plistPath: plist))
        }
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

    @Test("incomplete or ambiguous signature identity cannot authorize registration", arguments: [
        "Identifier=com.tron.server",
        "Identifier=com.tron.server\nTeamIdentifier=",
        "Identifier=com.tron.server\nTeamIdentifier=TEAM123456\nIdentifier=other.bundle",
        "Identifier=com.tron.server\nTeamIdentifier=TEAM123456\nTeamIdentifier=OTHER12345"
    ])
    func incompleteIdentityRejected(_ identity: String) {
        #expect(ExistingInstallDetector.codeSignatureIdentityProblem(
            identity, expectedBundleIdentifier: "com.tron.server", helperName: "Fixture Agent.app"
        ) != nil)
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

    @Test("native host validation is offline and requires the executable")
    func nativeHostValidationUsesInjectedSignatureBoundary() async throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let bundle = tmp.appendingPathComponent("Tron Native Host.app", isDirectory: true)
        let executable = bundle.appendingPathComponent("Contents/MacOS/TronNativeHost", isDirectory: false)
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: executable.path, contents: Data([0]))
        chmod(executable.path, 0o700)

        let accepted = await ExistingInstallDetector.validateNativeHost(
            bundle: bundle,
            executable: executable,
            signatureProblemResolver: { candidate in
                #expect(candidate == bundle)
                return nil
            }
        )
        #expect(accepted == nil)

        try FileManager.default.removeItem(at: executable)
        let missing = await ExistingInstallDetector.validateNativeHost(
            bundle: bundle,
            executable: executable,
            signatureProblemResolver: { _ in nil }
        )
        #expect(missing?.contains("not executable") == true)
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
