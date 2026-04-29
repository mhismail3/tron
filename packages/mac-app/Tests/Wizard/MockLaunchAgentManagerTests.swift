import Foundation
import Testing
@testable import TronMac

/// Sanity-check that the test fixture itself behaves predictably so
/// downstream tests (eventual InstallStep flow + MenuBar Restart) can
/// rely on it.
@Suite("MockLaunchAgentManager")
struct MockLaunchAgentManagerTests {
    @Test("records the load call with plist path and label")
    func recordsLoad() async throws {
        let mock = MockLaunchAgentManager()
        let url = URL(fileURLWithPath: "/tmp/p.plist")
        let outcome = await mock.load(plistPath: url, label: "com.tron.server")
        #expect(outcome == .ok)
        #expect(mock.calls.count == 1)
        #expect(mock.calls[0].kind == .load)
        #expect(mock.calls[0].label == "com.tron.server")
        #expect(mock.calls[0].plistPath == url)
    }

    @Test("returns configured outcomes")
    func configurableOutcomes() async throws {
        let mock = MockLaunchAgentManager()
        mock.loadOutcome = .launchdRefused(message: "nope")
        let outcome = await mock.load(plistPath: URL(fileURLWithPath: "/x"), label: "y")
        #expect(outcome == .launchdRefused(message: "nope"))
    }

    @Test("isLoaded honors the loaded property")
    func isLoadedHonored() async throws {
        let mock = MockLaunchAgentManager()
        mock.loaded = true
        let result = await mock.isLoaded(label: "x")
        #expect(result == true)
    }

    @Test("calls accumulate across operations")
    func callsAccumulate() async throws {
        let mock = MockLaunchAgentManager()
        _ = await mock.load(plistPath: URL(fileURLWithPath: "/a"), label: "x")
        _ = await mock.unload(label: "x")
        _ = await mock.restart(label: "x")
        _ = await mock.isLoaded(label: "x")
        #expect(mock.calls.map(\.kind) == [.load, .unload, .restart, .isLoaded])
    }

    @Test("live manager attempts registration when preflight status is notFound")
    func liveManagerAttemptsRegisterOnNotFoundAfterDiskValidation() {
        let outcome = LiveLaunchAgentManager.preRegistrationOutcome(for: .notFound)
        #expect(outcome == nil)
    }

    @Test("live manager short-circuits already enabled or approval-required services")
    func liveManagerShortCircuitsTerminalPreflightStates() {
        #expect(
            LiveLaunchAgentManager.preRegistrationOutcome(
                for: .enabled,
                currentVariant: .installedRelease,
                runningParentBundleIdentifier: "com.tron.mac"
            ) == .alreadyLoaded
        )
        #expect(
            LiveLaunchAgentManager.preRegistrationOutcome(for: .requiresApproval)
                == .requiresApproval(message: "Approve Tron Server in Login Items to finish installation.")
        )
    }

    @Test("enabled service without loaded launchd job is re-registered")
    func enabledServiceWithoutLoadedJobIsNotReady() {
        #expect(
            LiveLaunchAgentManager.preRegistrationOutcome(
                for: .enabled,
                currentVariant: .xcodeDebug(bundlePath: "/tmp/Debug/TronMac.app"),
                runningParentBundleIdentifier: nil
            ) == nil
        )
    }

    @Test("debug companion treats an installed release service as already loaded")
    func debugCompanionWrapsReleaseService() {
        let variant = MacRuntimeVariant.xcodeDebug(bundlePath: "/tmp/Debug/Tron.app")
        #expect(
            LiveLaunchAgentManager.preRegistrationOutcome(
                for: .notRegistered,
                currentVariant: variant,
                runningParentBundleIdentifier: "com.tron.mac",
                canManageLaunchAgent: false
            ) == .alreadyLoaded
        )
        #expect(
            !LiveLaunchAgentManager.shouldBootoutForTakeover(
                status: .notRegistered,
                currentVariant: variant,
                runningParentBundleIdentifier: "com.tron.mac",
                canManageLaunchAgent: false
            )
        )
    }

    @Test("installed release does not take over debug wrapper")
    func installedReleaseDoesNotTakeOverDebugWrapper() {
        #expect(
            LiveLaunchAgentManager.preRegistrationOutcome(
                for: .notRegistered,
                currentVariant: .installedRelease,
                runningParentBundleIdentifier: "com.tron.mac.dev"
            ) == .launchdRefused(message: "Tron Server is currently managed by com.tron.mac.dev. Stop that build before installing this one.")
        )
        #expect(
            !LiveLaunchAgentManager.shouldBootoutForTakeover(
                status: .enabled,
                currentVariant: .installedRelease,
                runningParentBundleIdentifier: "com.tron.mac.dev"
            )
        )
    }

    @Test("stale missing runtime is repaired by a manager build")
    func staleRuntimeIsRepairedByManagerBuild() {
        let runtime = LaunchAgentRuntimeInfo(
            pid: nil,
            parentBundleIdentifier: "com.tron.mac.dev",
            executablePath: "/tmp/DerivedData/Deleted.app/Contents/MacOS/tron"
        )
        #expect(
            LiveLaunchAgentManager.runtimeRequiresReplacement(
                runtimeInfo: runtime,
                expectedHelperPath: "/Applications/Tron.app/Contents/Library/LoginItems/Tron Server.app/Contents/MacOS/tron",
                fileExists: { _ in false }
            )
        )
        #expect(
            LiveLaunchAgentManager.preRegistrationOutcome(
                for: .enabled,
                currentVariant: .installedRelease,
                runtimeInfo: runtime,
                expectedHelperPath: "/Applications/Tron.app/Contents/Library/LoginItems/Tron Server.app/Contents/MacOS/tron"
            ) == nil
        )
    }

    @Test("debug companion cannot repair stale production registration")
    func debugCompanionCannotRepairProductionRegistration() {
        let runtime = LaunchAgentRuntimeInfo(
            pid: nil,
            parentBundleIdentifier: "com.tron.mac.dev",
            executablePath: "/tmp/DerivedData/Deleted.app/Contents/MacOS/tron"
        )
        let outcome = LiveLaunchAgentManager.preRegistrationOutcome(
            for: .enabled,
            currentVariant: .xcodeDebug(bundlePath: "/tmp/Debug/TronMac.app"),
            runtimeInfo: runtime,
            canManageLaunchAgent: false,
            expectedHelperPath: "/tmp/Debug/TronMac.app/Contents/Library/LoginItems/Tron Server.app/Contents/MacOS/tron"
        )
        if case .launchdRefused(let message) = outcome {
            #expect(message.contains("companion mode"))
        } else {
            Issue.record("debug companion should refuse stale production repair")
        }
    }

    @Test("external direct server blocks registration")
    func externalDirectServerBlocksRegistration() {
        #expect(
            LiveLaunchAgentManager.shouldRefuseExternalServer(
                status: .notRegistered,
                runningParentBundleIdentifier: nil,
                portBound: true,
                databaseLockHeld: false
            )
        )
        #expect(
            LiveLaunchAgentManager.shouldRefuseExternalServer(
                status: .notFound,
                runningParentBundleIdentifier: nil,
                portBound: false,
                databaseLockHeld: true
            )
        )
        #expect(
            !LiveLaunchAgentManager.shouldRefuseExternalServer(
                status: .notRegistered,
                runningParentBundleIdentifier: "com.tron.mac",
                portBound: true,
                databaseLockHeld: true
            )
        )
    }

    @Test("unregistration is idempotent when ServiceManagement is already clear")
    func unregistrationPreflightHandlesAlreadyClearState() {
        #expect(
            LiveLaunchAgentManager.preUnregistrationOutcome(for: .notRegistered) == .ok
        )
        if case .binaryMissing(let path) = LiveLaunchAgentManager.preUnregistrationOutcome(for: .notFound) {
            #expect(path.hasSuffix("/Contents/Library/LaunchAgents/com.tron.server.plist"))
        } else {
            Issue.record("Expected missing LaunchAgent plist to block unregister")
        }
        #expect(LiveLaunchAgentManager.preUnregistrationOutcome(for: .enabled) == nil)
        #expect(LiveLaunchAgentManager.preUnregistrationOutcome(for: .requiresApproval) == nil)
    }
}

@Suite("InstallLaunchAgentRunner")
struct InstallLaunchAgentRunnerTests {
    @Test("bootstrap success does not restart")
    func bootstrapSuccessDoesNotRestart() async throws {
        let mock = MockLaunchAgentManager()
        let outcome = await InstallLaunchAgentRunner.ensureLoaded(
            manager: mock,
            plistPath: URL(fileURLWithPath: "/tmp/com.tron.server.plist"),
            label: "com.tron.server"
        )

        #expect(outcome == .ok)
        #expect(mock.calls.map(\.kind) == [.load])
    }

    @Test("already-loaded label is kickstarted after plist write")
    func alreadyLoadedRestarts() async throws {
        let mock = MockLaunchAgentManager()
        mock.loadOutcome = .alreadyLoaded

        let outcome = await InstallLaunchAgentRunner.ensureLoaded(
            manager: mock,
            plistPath: URL(fileURLWithPath: "/tmp/com.tron.server.plist"),
            label: "com.tron.server"
        )

        #expect(outcome == .ok)
        #expect(mock.calls.map(\.kind) == [.load, .restart])
    }

    @Test("restart failure is surfaced to the install step")
    func restartFailureSurfaces() async throws {
        let mock = MockLaunchAgentManager()
        mock.loadOutcome = .alreadyLoaded
        mock.restartOutcome = .launchdRefused(message: "stale job would not restart")

        let outcome = await InstallLaunchAgentRunner.ensureLoaded(
            manager: mock,
            plistPath: URL(fileURLWithPath: "/tmp/com.tron.server.plist"),
            label: "com.tron.server"
        )

        #expect(outcome == .launchdRefused(message: "stale job would not restart"))
        #expect(mock.calls.map(\.kind) == [.load, .restart])
    }
}
