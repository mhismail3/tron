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
            bundleSignatureProblemResolver: { _ in "Tron Server.app signature is invalid" },
            serviceStatusResolver: { .enabled }
        )

        if case .partial(let reason) = result {
            #expect(reason.contains("signature"))
        } else {
            Issue.record("expected partial")
        }
    }

    @Test("release bundle must live at /Applications/Tron.app")
    func releaseLocationGuard() {
        let problem = ExistingInstallDetector.validateApplicationLocation(
            bundleURL: URL(fileURLWithPath: "/Users/example/Downloads/Tron.app", isDirectory: true),
            bundleIdentifier: "com.tron.mac"
        )
        #expect(problem?.contains("/Applications") == true)

        let devProblem = ExistingInstallDetector.validateApplicationLocation(
            bundleURL: URL(fileURLWithPath: "/tmp/TronMac.app", isDirectory: true),
            bundleIdentifier: "com.tron.mac.dev"
        )
        #expect(devProblem == nil)
    }

    @Test("unsupported wrapper bundle ids are rejected")
    func unsupportedWrapperBundleID() {
        let problem = ExistingInstallDetector.validateApplicationLocation(
            bundleURL: URL(fileURLWithPath: "/tmp/Tron.app", isDirectory: true),
            bundleIdentifier: "example.tron"
        )

        #expect(problem?.contains("Unsupported") == true)
    }

    @Test("LaunchAgent plist requires current BundleProgram and associated wrapper IDs")
    func launchAgentPlistIsCurrent() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let plist = tmp.appendingPathComponent("com.tron.server.plist")
        try InstallPlanner.renderPlist(paths: makeTargetPaths(in: tmp)).write(to: plist, atomically: true, encoding: .utf8)

        #expect(ExistingInstallDetector.launchAgentPlistIsCurrent(plistPath: plist))
    }

    @Test("ad-hoc helper signature is rejected before SMAppService registration")
    func adhocHelperSignatureRejected() {
        let problem = ExistingInstallDetector.codeSignatureIdentityProblem("""
        Executable=/tmp/Tron Server.app/Contents/MacOS/tron
        Identifier=com.tron.server
        Signature=adhoc
        TeamIdentifier=not set
        """)

        #expect(problem?.contains("ad-hoc signed") == true)
    }

    @Test("team-signed helper identity is accepted")
    func teamSignedHelperIdentityAccepted() {
        let problem = ExistingInstallDetector.codeSignatureIdentityProblem("""
        Executable=/tmp/Tron Server.app/Contents/MacOS/tron
        Identifier=com.tron.server
        TeamIdentifier=MYGKXH6TY4
        """)

        #expect(problem == nil)
    }

    private typealias HelperFixture = (helperBundle: URL, helperBinary: URL, plistPath: URL)

    private func makeHelperFixture(in tmp: URL, includePlist: Bool = true) throws -> HelperFixture {
        let helper = tmp.appendingPathComponent("Tron.app/Contents/Library/LoginItems/Tron Server.app", isDirectory: true)
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

    private func makeTargetPaths(in tmp: URL) -> InstallPlanner.TargetPaths {
        let app = tmp.appendingPathComponent("Tron.app", isDirectory: true)
        let helper = app.appendingPathComponent("Contents/Library/LoginItems/Tron Server.app", isDirectory: true)
        return InstallPlanner.TargetPaths(
            helperBundle: helper,
            helperBinary: helper.appendingPathComponent("Contents/MacOS/tron", isDirectory: false),
            plistPath: app.appendingPathComponent("Contents/Library/LaunchAgents/com.tron.server.plist", isDirectory: false),
            label: "com.tron.server",
            port: 9847
        )
    }
}
