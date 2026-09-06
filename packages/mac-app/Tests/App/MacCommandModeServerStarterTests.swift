import Foundation
import Testing
@testable import TronMac

@Suite("MacCommandModeServerStarter")
struct MacCommandModeServerStarterTests {
    @Test("successful command-mode start records finalized app version")
    func successfulStartRecordsFinalizedVersion() async throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let current = MacAppVersionIdentity(canonicalVersion: "0.1.0-beta.7", buildNumber: "7")
        let mock = MockLaunchAgentManager()
        mock.loadOutcome = .alreadyLoaded
        let setup = MacAppStartupMaintenanceTests.makeSetup(
            tmp: tmp,
            currentVersion: current,
            launchAgentManager: mock
        )

        let result = await MacCommandModeServerStarter.start(setup: setup)

        #expect(result == .ok)
        #expect(setup.readRecordedAppVersion() == current)
    }

    @Test("async helper validation failure stops command-mode admission")
    func helperFailureStopsAdmission() async throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let current = MacAppVersionIdentity(canonicalVersion: "fixture", buildNumber: "1")
        let mock = MockLaunchAgentManager()
        var setup = MacAppStartupMaintenanceTests.makeSetup(tmp: tmp, currentVersion: current, launchAgentManager: mock)
        setup.validateBundledHelper = { "signature unavailable" }
        #expect(await MacCommandModeServerStarter.start(setup: setup) == .invalidBundledHelper("signature unavailable"))
        #expect(mock.calls.isEmpty)
        #expect(setup.readRecordedAppVersion() == nil)
    }

    @Test("unhealthy command-mode start does not record finalized version")
    func unhealthyStartDoesNotRecordFinalizedVersion() async throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let current = MacAppVersionIdentity(canonicalVersion: "0.1.0-beta.7", buildNumber: "7")
        let mock = MockLaunchAgentManager()
        mock.loadOutcome = .alreadyLoaded
        let setup = MacAppStartupMaintenanceTests.makeSetup(
            tmp: tmp,
            currentVersion: current,
            pingResult: .unreachable,
            launchAgentManager: mock
        )

        let result = await MacCommandModeServerStarter.start(setup: setup)

        #expect(result == .unhealthy(.unreachable))
        #expect(setup.readRecordedAppVersion() == nil)
    }
}
