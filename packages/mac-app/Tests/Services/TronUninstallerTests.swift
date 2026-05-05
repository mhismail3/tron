import Foundation
import Testing
@testable import TronMac

@Suite("TronUninstaller")
struct TronUninstallerTests {
    @Test("unregister success removes runtime files and preserves durable data")
    func unregisterSuccessCleansRuntimeState() async throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let manager = MockLaunchAgentManager()
        let setup = makeSetup(tmp: tmp, manager: manager)
        let runtimeFiles = TronUninstaller.runtimeCleanupPaths(setup: setup)
        for path in runtimeFiles {
            try FileManager.default.createDirectory(
                at: path.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            _ = FileManager.default.createFile(atPath: path.path, contents: Data("x".utf8))
        }
        try createFixtureFile(setup.settingsPath, contents: "settings")
        try createFixtureFile(setup.bearerTokenPath, contents: "auth")

        let outcome = await TronUninstaller.unregisterAndClean(setup: setup)

        #expect(outcome == .ok)
        #expect(manager.calls.map(\.kind) == [.unload])
        for path in runtimeFiles {
            #expect(!FileManager.default.fileExists(atPath: path.path))
        }
        #expect(FileManager.default.fileExists(atPath: setup.settingsPath.path))
        #expect(FileManager.default.fileExists(atPath: setup.bearerTokenPath.path))
    }

    @Test("reset options remove settings and credentials after unregister")
    func resetOptionsRemoveDurableFiles() async throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let manager = MockLaunchAgentManager()
        let setup = makeSetup(tmp: tmp, manager: manager)
        try createFixtureFile(setup.settingsPath, contents: "settings")
        try createFixtureFile(setup.bearerTokenPath, contents: "auth")

        let outcome = await TronUninstaller.unregisterAndClean(
            setup: setup,
            options: TronUninstaller.Options(resetSettings: true, resetCredentials: true)
        )

        #expect(outcome == .ok)
        #expect(!FileManager.default.fileExists(atPath: setup.settingsPath.path))
        #expect(!FileManager.default.fileExists(atPath: setup.bearerTokenPath.path))
    }

    @Test("unregister failure leaves files untouched")
    func unregisterFailureDoesNotCleanFiles() async throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let manager = MockLaunchAgentManager()
        manager.unloadOutcome = .launchdRefused(message: "nope")
        let setup = makeSetup(tmp: tmp, manager: manager)
        let marker = setup.onboardedMarkerPath
        try FileManager.default.createDirectory(
            at: marker.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        _ = FileManager.default.createFile(atPath: marker.path, contents: Data("x".utf8))

        let outcome = await TronUninstaller.unregisterAndClean(setup: setup)

        #expect(outcome == .launchdRefused(message: "nope"))
        #expect(FileManager.default.fileExists(atPath: marker.path))
    }

    @Test("debug companion cannot unregister production service")
    func companionCannotUnregisterProductionService() async throws {
        let tmp = TestTempDir.make()
        defer { TestTempDir.cleanup(tmp) }
        let manager = MockLaunchAgentManager()
        var setup = makeSetup(tmp: tmp, manager: manager)
        setup.canManageLaunchAgent = false

        let outcome = await TronUninstaller.unregisterAndClean(setup: setup)

        if case .launchdRefused(let message) = outcome {
            #expect(message.contains("companion mode"))
        } else {
            Issue.record("companion uninstall should be refused")
        }
        #expect(manager.calls.isEmpty)
    }

    private func makeSetup(tmp: URL, manager: MockLaunchAgentManager) -> EnvironmentSetup {
        let internalDir = tmp.appendingPathComponent("internal", isDirectory: true)
        let run = internalDir.appendingPathComponent("run", isDirectory: true)
        let profiles = tmp.appendingPathComponent("profiles", isDirectory: true)
        let userProfile = profiles.appendingPathComponent("user", isDirectory: true)
        return EnvironmentSetup(
            tronHome: tmp,
            applicationBundle: tmp.appendingPathComponent("Tron.app", isDirectory: true),
            serverHelperBundle: tmp.appendingPathComponent("Tron.app/Contents/Library/LoginItems/Tron Server.app", isDirectory: true),
            serverHelperBinary: tmp.appendingPathComponent("Tron.app/Contents/Library/LoginItems/Tron Server.app/Contents/MacOS/tron"),
            bearerTokenPath: profiles.appendingPathComponent("auth.json", isDirectory: false),
            onboardedMarkerPath: run.appendingPathComponent(".onboarded", isDirectory: false),
            settingsPath: userProfile.appendingPathComponent("settings.json", isDirectory: false),
            launchAgentPlistPath: tmp.appendingPathComponent("Tron.app/Contents/Library/LaunchAgents/com.tron.server.plist"),
            launchAgentLabel: "com.tron.server",
            serverPort: 9847,
            canManageLaunchAgent: true,
            wrapperLockPath: run.appendingPathComponent(".mac-wrapper.com.tron.mac.lock"),
            onboardedSentinelExists: { false },
            readBearerToken: { nil },
            readTailscaleIPFromSettings: { nil },
            cacheTailscaleIP: { _ in },
            probeTailscale: { .notInstalled },
            probePermissions: { [:] },
            detectExistingInstall: { .none },
            validateApplicationLocation: { nil },
            validateBundledHelper: { nil },
            pingServer: { _ in .unreachable },
            launchAgentManager: manager,
            applyTranscriptionPreference: { _ in .disabled },
            touchOnboardedSentinel: { }
        )
    }

    private func createFixtureFile(_ path: URL, contents: String) throws {
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        _ = FileManager.default.createFile(atPath: path.path, contents: Data(contents.utf8))
    }
}
