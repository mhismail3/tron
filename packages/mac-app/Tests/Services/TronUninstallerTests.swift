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
        _ = FileManager.default.createFile(atPath: setup.settingsPath.path, contents: Data("settings".utf8))
        _ = FileManager.default.createFile(atPath: setup.bearerTokenPath.path, contents: Data("auth".utf8))

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
        try FileManager.default.createDirectory(
            at: setup.settingsPath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        _ = FileManager.default.createFile(atPath: setup.settingsPath.path, contents: Data("settings".utf8))
        _ = FileManager.default.createFile(atPath: setup.bearerTokenPath.path, contents: Data("auth".utf8))

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

    private func makeSetup(tmp: URL, manager: MockLaunchAgentManager) -> EnvironmentSetup {
        let system = tmp.appendingPathComponent("system", isDirectory: true)
        let run = system.appendingPathComponent("run", isDirectory: true)
        return EnvironmentSetup(
            tronHome: tmp,
            applicationBundle: tmp.appendingPathComponent("Tron.app", isDirectory: true),
            serverHelperBundle: tmp.appendingPathComponent("Tron.app/Contents/Library/LoginItems/Tron Server.app", isDirectory: true),
            serverHelperBinary: tmp.appendingPathComponent("Tron.app/Contents/Library/LoginItems/Tron Server.app/Contents/MacOS/tron"),
            bearerTokenPath: system.appendingPathComponent("auth.json", isDirectory: false),
            onboardedMarkerPath: run.appendingPathComponent(".onboarded", isDirectory: false),
            settingsPath: system.appendingPathComponent("settings.json", isDirectory: false),
            launchAgentPlistPath: tmp.appendingPathComponent("Tron.app/Contents/Library/LaunchAgents/com.tron.server.plist"),
            serverPort: 9847,
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
            touchOnboardedSentinel: { }
        )
    }
}
