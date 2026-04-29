import Foundation
import Testing
@testable import TronMac

@Suite("MacAppStartupMaintenance")
struct MacAppStartupMaintenanceTests {
    static func makeSetup(
        tmp: URL,
        currentVersion: MacAppVersionIdentity,
        recordedVersion: MacAppVersionIdentity? = nil,
        onboarded: Bool = true,
        canManageLaunchAgent: Bool = true,
        serverProcess: ServerProcessInfo? = nil,
        launchAgentManager: MockLaunchAgentManager = MockLaunchAgentManager()
    ) -> EnvironmentSetup {
        let marker = tmp.appendingPathComponent("system/run/mac-app-version.json", isDirectory: false)
        if let recordedVersion {
            try? MacAppVersionMarkerStore.write(recordedVersion, at: marker)
        }
        return EnvironmentSetup(
            tronHome: tmp,
            applicationBundle: tmp.appendingPathComponent("Tron.app", isDirectory: true),
            serverHelperBundle: tmp.appendingPathComponent("Tron.app/Contents/Library/LoginItems/Tron Server.app", isDirectory: true),
            serverHelperBinary: tmp.appendingPathComponent("Tron.app/Contents/Library/LoginItems/Tron Server.app/Contents/MacOS/tron", isDirectory: false),
            bearerTokenPath: tmp.appendingPathComponent("system/auth.json", isDirectory: false),
            onboardedMarkerPath: tmp.appendingPathComponent("system/run/.onboarded", isDirectory: false),
            settingsPath: tmp.appendingPathComponent("system/settings.json", isDirectory: false),
            launchAgentPlistPath: tmp.appendingPathComponent("Tron.app/Contents/Library/LaunchAgents/com.tron.server.plist", isDirectory: false),
            launchAgentLabel: "com.tron.server",
            serverPort: 9847,
            canManageLaunchAgent: canManageLaunchAgent,
            wrapperLockPath: tmp.appendingPathComponent("system/run/.mac-wrapper.com.tron.mac.lock", isDirectory: false),
            onboardedSentinelExists: { onboarded },
            readBearerToken: { nil },
            readTailscaleIPFromSettings: { nil },
            cacheTailscaleIP: { _ in },
            probeTailscale: { .notInstalled },
            probePermissions: { [:] },
            detectExistingInstall: { .none },
            validateApplicationLocation: { nil },
            validateBundledHelper: { nil },
            pingServer: { _ in .success(ServerInfo(version: currentVersion.canonicalVersion, port: 9847, paired: true)) },
            launchAgentManager: launchAgentManager,
            probeServerProcess: { _ in serverProcess },
            syncManagedSkills: {
                .synced(ManagedSkillSyncSummary(synced: 1, skippedUserOwned: 0, removedStale: 0))
            },
            applyTranscriptionPreference: { _ in .disabled },
            touchOnboardedSentinel: { },
            currentAppVersion: { currentVersion },
            readRecordedAppVersion: {
                MacAppVersionMarkerStore.read(at: marker)
            },
            writeRecordedAppVersion: { version in
                try MacAppVersionMarkerStore.write(version, at: marker)
            }
        )
    }

    @Test("version marker round-trips JSON")
    func versionMarkerRoundTrips() throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let marker = tmp.appendingPathComponent("system/run/mac-app-version.json")
        let version = MacAppVersionIdentity(canonicalVersion: "0.1.0-beta.3", buildNumber: "3")

        try MacAppVersionMarkerStore.write(version, at: marker)

        #expect(MacAppVersionMarkerStore.read(at: marker) == version)
    }

    @Test("existing onboarded launch restarts once when version marker is missing")
    func missingMarkerRestartsAndRecords() async throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let current = MacAppVersionIdentity(canonicalVersion: "0.1.0-beta.3", buildNumber: "3")
        let mock = MockLaunchAgentManager()
        mock.loadOutcome = .alreadyLoaded
        let setup = Self.makeSetup(tmp: tmp, currentVersion: current, launchAgentManager: mock)

        let result = await MacAppStartupMaintenance.run(
            setup: setup,
            controller: nil,
            context: .existingOnboardedLaunch
        )

        #expect(result == .restarted(.ok))
        #expect(mock.calls.map(\.kind) == [.load, .restart, .runtimeInfo])
        #expect(setup.readRecordedAppVersion() == current)
    }

    @Test("existing onboarded launch skips when version is already recorded")
    func recordedVersionSkipsRestart() async throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let current = MacAppVersionIdentity(canonicalVersion: "0.1.0-beta.3", buildNumber: "3")
        let mock = MockLaunchAgentManager()
        let setup = Self.makeSetup(
            tmp: tmp,
            currentVersion: current,
            recordedVersion: current,
            launchAgentManager: mock
        )

        let result = await MacAppStartupMaintenance.run(
            setup: setup,
            controller: nil,
            context: .existingOnboardedLaunch
        )

        #expect(result == .skipped(.versionAlreadyRecorded))
        #expect(mock.calls.isEmpty)
    }

    @Test("dev server takeover defers update restart and does not record marker")
    func devServerDefersRestart() async throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let current = MacAppVersionIdentity(canonicalVersion: "0.1.0-beta.3", buildNumber: "3")
        let mock = MockLaunchAgentManager()
        let setup = Self.makeSetup(
            tmp: tmp,
            currentVersion: current,
            serverProcess: ServerProcessInfo(
                pid: 42,
                uptime: "00:01",
                command: "\(tmp.path)/system/run/Tron-Dev.app/Contents/MacOS/tron --port 9847",
                isDevServer: true
            ),
            launchAgentManager: mock
        )

        let result = await MacAppStartupMaintenance.run(
            setup: setup,
            controller: nil,
            context: .existingOnboardedLaunch
        )

        #expect(result == .skipped(.devServerActive))
        #expect(mock.calls.isEmpty)
        #expect(setup.readRecordedAppVersion() == nil)
    }

    @Test("wizard completion records current version without restarting")
    func wizardCompletionRecordsWithoutRestarting() async throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let current = MacAppVersionIdentity(canonicalVersion: "0.1.0-beta.3", buildNumber: "3")
        let mock = MockLaunchAgentManager()
        let setup = Self.makeSetup(
            tmp: tmp,
            currentVersion: current,
            onboarded: false,
            launchAgentManager: mock
        )

        let result = await MacAppStartupMaintenance.run(
            setup: setup,
            controller: nil,
            context: .wizardCompletion
        )

        #expect(result == .recordedCurrentVersion)
        #expect(mock.calls.isEmpty)
        #expect(setup.readRecordedAppVersion() == current)
    }
}
