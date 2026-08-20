import Foundation
import Testing
@testable import TronMac

@Suite("LiveLaunchAgentManager")
struct LiveLaunchAgentManagerTests {
    @Test("live manager attempts registration when preflight status is notFound")
    func attemptsRegisterOnNotFoundAfterDiskValidation() {
        let outcome = LiveLaunchAgentManager.preRegistrationOutcome(for: .notFound)
        #expect(outcome == nil)
    }

    @Test("live manager short-circuits already enabled or approval-required services")
    func shortCircuitsTerminalPreflightStates() {
        #expect(
            LiveLaunchAgentManager.preRegistrationOutcome(
                for: .enabled,
                currentVariant: .installedRelease,
                runningParentBundleIdentifier: "com.tron.mac"
            ) == .alreadyLoaded
        )
        #expect(
            LiveLaunchAgentManager.preRegistrationOutcome(for: .requiresApproval)
                == .requiresApproval(message: "Approve Tron Agent in Login Items to finish installation.")
        )
    }

    @Test("enabled service without loaded launchd job is re-registered")
    func enabledServiceWithoutLoadedJobIsNotReady() {
        #expect(
            LiveLaunchAgentManager.preRegistrationOutcome(
                for: .enabled,
                currentVariant: .xcodeDebug,
                runningParentBundleIdentifier: nil
            ) == nil
        )
    }

    @Test("debug companion treats an installed release service as already loaded")
    func debugCompanionWrapsReleaseService() {
        let variant = MacRuntimeVariant.xcodeDebug
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

    @Test("installed release reclaims stale debug production registration")
    func installedReleaseReclaimsDebugProductionRegistration() {
        #expect(
            LiveLaunchAgentManager.preRegistrationOutcome(
                for: .notRegistered,
                currentVariant: .installedRelease,
                runningParentBundleIdentifier: "com.tron.mac.dev"
            ) == nil
        )
        #expect(
            LiveLaunchAgentManager.shouldBootoutForTakeover(
                status: .enabled,
                currentVariant: .installedRelease,
                runningParentBundleIdentifier: "com.tron.mac.dev"
            )
        )
    }

    @Test("debug companion never reclaims installed release registration")
    func debugCompanionDoesNotReclaimInstalledReleaseRegistration() {
        #expect(
            !LiveLaunchAgentManager.shouldBootoutForTakeover(
                status: .enabled,
                currentVariant: .xcodeDebug,
                runningParentBundleIdentifier: "com.tron.mac",
                canManageLaunchAgent: false
            )
        )
    }

    @Test("runtime ownership requires exact profile, supervision, channel, and helper path")
    func runtimeOwnershipProjectionIsExact() {
        let runtime = LaunchAgentRuntimeInfo(
            pid: 42,
            parentBundleIdentifier: MacRuntimeVariant.releaseBundleIdentifier,
            executablePath: "/Applications/Tron.app/Contents/Library/LoginItems/Tron Agent Dev.app/Contents/MacOS/tron",
            gatewaySupervisionMarker: TronPaths.gatewaySupervisionValue,
            gatewayChannelMarker: TronGatewayProfile.preview.channel
        )
        #expect(LiveLaunchAgentManager.runtimeOwnsProfile(
            runtimeInfo: runtime,
            profile: .preview,
            expectedParentBundleIdentifier: MacRuntimeVariant.releaseBundleIdentifier,
            expectedHelperPath: runtime.executablePath!,
            fileExists: { _ in true }
        ))
        #expect(!LiveLaunchAgentManager.runtimeOwnsProfile(
            runtimeInfo: runtime,
            profile: .stable,
            expectedParentBundleIdentifier: MacRuntimeVariant.releaseBundleIdentifier,
            expectedHelperPath: runtime.executablePath!
        ))
        #expect(!LiveLaunchAgentManager.runtimeOwnsProfile(
            runtimeInfo: runtime,
            profile: .preview,
            expectedParentBundleIdentifier: MacRuntimeVariant.releaseBundleIdentifier,
            expectedHelperPath: runtime.executablePath!,
            expectedSupervisionMarker: "0"
        ))
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
                expectedHelperPath: "/Applications/Tron.app/Contents/Library/LoginItems/Tron Agent.app/Contents/MacOS/tron",
                fileExists: { _ in false }
            )
        )
        #expect(
            LiveLaunchAgentManager.preRegistrationOutcome(
                for: .enabled,
                currentVariant: .installedRelease,
                runtimeInfo: runtime,
                expectedHelperPath: "/Applications/Tron.app/Contents/Library/LoginItems/Tron Agent.app/Contents/MacOS/tron"
            ) == nil
        )
    }

    @Test("a running helper at an old path is still repaired")
    func runningStaleRuntimeIsRepaired() {
        let runtime = LaunchAgentRuntimeInfo(
            pid: 123,
            executablePath: "/tmp/old/Tron Agent.app/Contents/MacOS/tron"
        )
        #expect(LiveLaunchAgentManager.runtimeRequiresReplacement(
            runtimeInfo: runtime,
            expectedHelperPath: "/Applications/Tron.app/Contents/Library/LoginItems/Tron Agent.app/Contents/MacOS/tron",
            fileExists: { _ in true }
        ))
    }

    @Test("takeover unregisters stale enabled registration before register")
    func takeoverUnregistersEnabledRegistrationBeforeRegister() {
        #expect(
            LiveLaunchAgentManager.shouldUnregisterBeforeRegister(
                status: .enabled,
                runningParentBundleIdentifier: "com.tron.mac.dev",
                shouldReplaceStaleRuntime: false,
                shouldTakeOverRuntime: true,
                shouldRefreshCurrentRegistration: false
            )
        )
        #expect(
            !LiveLaunchAgentManager.shouldUnregisterBeforeRegister(
                status: .notRegistered,
                runningParentBundleIdentifier: "com.tron.mac.dev",
                shouldReplaceStaleRuntime: false,
                shouldTakeOverRuntime: true,
                shouldRefreshCurrentRegistration: false
            )
        )
        #expect(
            !LiveLaunchAgentManager.shouldUnregisterBeforeRegister(
                status: .enabled,
                runningParentBundleIdentifier: "com.tron.mac",
                shouldReplaceStaleRuntime: false,
                shouldTakeOverRuntime: false,
                shouldRefreshCurrentRegistration: false
            )
        )
        #expect(
            LiveLaunchAgentManager.shouldUnregisterBeforeRegister(
                status: .unknown("foreign registration"),
                runningParentBundleIdentifier: "com.tron.mac.dev",
                shouldReplaceStaleRuntime: false,
                shouldTakeOverRuntime: true,
                shouldRefreshCurrentRegistration: false
            )
        )
    }

    @Test("installed release refreshes same-bundle registration when parent build is stale")
    func installedReleaseRefreshesStaleParentBundleVersion() {
        let runtime = LaunchAgentRuntimeInfo(
            pid: 123,
            parentBundleIdentifier: "com.tron.mac",
            parentBundleVersion: "1"
        )
        #expect(
            LiveLaunchAgentManager.shouldRefreshRegistrationForCurrentBundle(
                status: .enabled,
                currentVariant: .installedRelease,
                runtimeInfo: runtime,
                currentParentBundleVersion: "3"
            )
        )
        #expect(
            LiveLaunchAgentManager.preRegistrationOutcome(
                for: .enabled,
                currentVariant: .installedRelease,
                runtimeInfo: runtime,
                shouldRefreshCurrentRegistration: true
            ) == nil
        )
        #expect(
            LiveLaunchAgentManager.shouldUnregisterBeforeRegister(
                status: .enabled,
                runningParentBundleIdentifier: "com.tron.mac",
                shouldReplaceStaleRuntime: false,
                shouldTakeOverRuntime: false,
                shouldRefreshCurrentRegistration: true
            )
        )
    }

    @Test("current parent bundle version is not refreshed")
    func currentParentBundleVersionDoesNotRefresh() {
        let runtime = LaunchAgentRuntimeInfo(
            parentBundleIdentifier: "com.tron.mac",
            parentBundleVersion: "3"
        )
        #expect(
            !LiveLaunchAgentManager.shouldRefreshRegistrationForCurrentBundle(
                status: .enabled,
                currentVariant: .installedRelease,
                runtimeInfo: runtime,
                currentParentBundleVersion: "3"
            )
        )
    }

    @Test("installed release refreshes same-bundle registration when supervision marker is stale")
    func installedReleaseRefreshesStaleGatewaySupervision() {
        let runtime = LaunchAgentRuntimeInfo(
            parentBundleIdentifier: "com.tron.mac",
            gatewaySupervisionMarker: nil
        )
        #expect(
            LiveLaunchAgentManager.shouldRefreshRegistrationForGatewaySupervision(
                status: .enabled,
                currentVariant: .installedRelease,
                runtimeInfo: runtime
            )
        )
        #expect(
            !LiveLaunchAgentManager.shouldRefreshRegistrationForGatewaySupervision(
                status: .enabled,
                currentVariant: .installedRelease,
                runtimeInfo: LaunchAgentRuntimeInfo(
                    parentBundleIdentifier: "com.tron.mac",
                    gatewaySupervisionMarker: TronPaths.gatewaySupervisionValue
                )
            )
        )
    }

    @Test("installed release refreshes same-bundle registration when launch constraints are stale")
    func installedReleaseRefreshesStaleLaunchConstraints() {
        let runtime = LaunchAgentRuntimeInfo(
            parentBundleIdentifier: "com.tron.mac",
            parentBundleVersion: "7",
            needsLaunchConstraintRefresh: true
        )
        #expect(
            LiveLaunchAgentManager.shouldRefreshRegistrationForLaunchConstraints(
                status: .enabled,
                currentVariant: .installedRelease,
                runtimeInfo: runtime
            )
        )
        #expect(
            LiveLaunchAgentManager.preRegistrationOutcome(
                for: .enabled,
                currentVariant: .installedRelease,
                runtimeInfo: runtime,
                shouldRefreshCurrentRegistration: true
            ) == nil
        )
        #expect(
            LiveLaunchAgentManager.shouldUnregisterBeforeRegister(
                status: .enabled,
                runningParentBundleIdentifier: "com.tron.mac",
                shouldReplaceStaleRuntime: false,
                shouldTakeOverRuntime: false,
                shouldRefreshCurrentRegistration: true
            )
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
            currentVariant: .xcodeDebug,
            runtimeInfo: runtime,
            canManageLaunchAgent: false,
            expectedHelperPath: "/tmp/Debug/TronMac.app/Contents/Library/LoginItems/Tron Agent.app/Contents/MacOS/tron"
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
                portBound: true
            )
        )
        #expect(
            !LiveLaunchAgentManager.shouldRefuseExternalServer(
                status: .notFound,
                runningParentBundleIdentifier: nil,
                portBound: false
            )
        )
        #expect(
            !LiveLaunchAgentManager.shouldRefuseExternalServer(
                status: .notRegistered,
                runningParentBundleIdentifier: "com.tron.mac",
                portBound: true
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

@Suite("LaunchAgentLoader")
struct LaunchAgentLoaderTests {
    @Test("bootstrap success does not restart")
    func bootstrapSuccessDoesNotRestart() async throws {
        let mock = MockLaunchAgentManager()
        let outcome = await LaunchAgentLoader.ensureLoaded(
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

        let outcome = await LaunchAgentLoader.ensureLoaded(
            manager: mock,
            plistPath: URL(fileURLWithPath: "/tmp/com.tron.server.plist"),
            label: "com.tron.server"
        )

        #expect(outcome == .ok)
        #expect(mock.calls.map(\.kind) == [.load, .restart])
    }

    @Test("restart failure is surfaced to the caller")
    func restartFailureSurfaces() async throws {
        let mock = MockLaunchAgentManager()
        mock.loadOutcome = .alreadyLoaded
        mock.restartOutcome = .launchdRefused(message: "stale job would not restart")

        let outcome = await LaunchAgentLoader.ensureLoaded(
            manager: mock,
            plistPath: URL(fileURLWithPath: "/tmp/com.tron.server.plist"),
            label: "com.tron.server"
        )

        #expect(outcome == .launchdRefused(message: "stale job would not restart"))
        #expect(mock.calls.map(\.kind) == [.load, .restart])
    }
}
