import Foundation
import Testing
@testable import TronMac

@Suite("TronPaths constants")
struct TronPathsTests {
    @Test("Stable and Debug profiles have independent canonical identities")
    func profilesAreIndependent() {
        #expect(TronPaths.launchAgentLabel(profile: .stable) == "com.tron.server")
        #expect(TronPaths.launchAgentLabel(profile: .debug) == "com.tron.server.dev")
        #expect(TronPaths.defaultServerPort(profile: .stable) == 9847)
        #expect(TronPaths.defaultServerPort(profile: .debug) == 9848)
        #expect(TronPaths.tronHome(profile: .debug).path.hasSuffix("/.tron-dev"))
        #expect(TronPaths.agentHome(profile: .debug).path.hasSuffix("/.pi/agent-dev"))
        #expect(TronPaths.bearerTokenPath(profile: .debug).path.hasSuffix("/.tron-dev/gateway/local-auth.json"))
    }

    @Test("Release manages Stable only; no wrapper manages Debug")
    func lifecycleOwnershipIsDisjoint() {
        #expect(MacRuntimeVariant.installedRelease.canManageLaunchAgent(profile: .stable, isIsolatedInstallMode: false))
        #expect(!MacRuntimeVariant.installedRelease.canManageLaunchAgent(profile: .debug, isIsolatedInstallMode: false))
        #expect(!MacRuntimeVariant.xcodeDebug.canManageLaunchAgent(profile: .debug, isIsolatedInstallMode: true))
    }

    @Test("Debug observation uses separate credential and enrollment paths")
    func debugObservationIsSeparate() {
        #expect(EnvironmentSetup.live.profile == .stable)
        #expect(EnvironmentSetup.debug.profile == .debug)
        #expect(EnvironmentSetup.live.bearerTokenPath != EnvironmentSetup.debug.bearerTokenPath)
        #expect(EnvironmentSetup.live.enrollmentCodePath != EnvironmentSetup.debug.enrollmentCodePath)
        #expect(EnvironmentSetup.debug.serverPort == 9848)
        #expect(!EnvironmentSetup.debug.canManageLaunchAgent)
    }

    @Test("LaunchAgent label matches the canonical label")
    func launchAgentLabelMatches() {
        #expect(TronPaths.launchAgentLabel(environment: [:]) == "com.tron.server")
    }

    @Test("default port matches the agent default")
    func defaultPortMatches() {
        #expect(TronPaths.defaultServerPort(environment: [:]) == 9847)
    }

    @Test("Stable has one wrapper parent and Debug has none")
    func associatedWrapperBundleIDsAreDisjoint() {
        #expect(TronPaths.associatedWrapperBundleIDs(profile: .stable) == [
            MacRuntimeVariant.releaseBundleIdentifier,
        ])
        #expect(TronPaths.associatedWrapperBundleIDs(profile: .debug).isEmpty)
    }

    @Test("server helper binary lives inside the bundled Login Item")
    func serverHelperBinaryShape() {
        #expect(TronPaths.serverHelperBundleProgram(environment: [:]) == "Contents/Library/LoginItems/Tron Agent.app/Contents/MacOS/tron")
    }

    @Test("production LaunchAgent always advertises Gateway supervision")
    func productionLaunchAgentSupervisionEnvironment() {
        #expect(TronPaths.launchAgentEnvironmentVariables(environment: [:]) == [
            TronPaths.gatewaySupervisionEnv: TronPaths.gatewaySupervisionValue,
            TronPaths.gatewayChannelEnv: TronPaths.productionGatewayChannel,
        ])
    }

    @Test("Debug environment cannot change wrapper lifecycle ownership")
    func debugEnvironmentDoesNotChangeOwnership() {
        let environment = [
            TronPaths.tronHomeNameEnv: ".tron-dev",
            TronPaths.agentDirNameEnv: "agent-dev",
        ]
        #expect(TronPaths.launchAgentLabel(environment: environment) == "com.tron.server")
        #expect(TronPaths.defaultServerPort(environment: environment) == 9847)
        #expect(!TronPaths.canManageLaunchAgent(environment: environment))
        #expect(TronPaths.tronHome(environment: environment).path.hasSuffix("/.tron-dev"))
    }

    @Test("runtime locks live in internal/run")
    func runDirShape() {
        #expect(TronPaths.runDir.path.hasSuffix("/internal/run"))
    }

    @Test("LaunchAgent plist is bundled in Contents/Library/LaunchAgents")
    func launchAgentPlistShape() {
        #expect(TronPaths.launchAgentLabel(environment: [:]) == "com.tron.server")
        #expect(TronPaths.launchAgentLabel(environment: [TronPaths.tronHomeNameEnv: ".tron-dev"]) == "com.tron.server")
    }

    @Test("wrapper credential lives in gateway-owned state")
    func bearerTokenShape() {
        let token = TronPaths.bearerTokenPath.path
        #expect(token.hasSuffix("/.tron/gateway/local-auth.json"))
    }

    @Test("onboarded sentinel lives in internal/run/")
    func onboardedShape() {
        let s = TronPaths.onboardedMarkerPath.path
        #expect(s.hasSuffix("/internal/run/.onboarded"))
    }

    @Test("runtime uninstall files live in internal/run/")
    func runtimeUninstallFilesShape() {
        #expect(TronPaths.macAppVersionMarkerPath.path.hasSuffix("/internal/run/mac-app-version.json"))
        #expect(TronPaths.authLockPath.path.hasSuffix("/internal/run/auth.lock"))
        #expect(TronPaths.macWrapperLockPath.path.contains("/internal/run/.mac-wrapper."))
        #expect(TronPaths.macWrapperLockPath.path.hasSuffix(".lock"))
        #expect(TronPaths.macWrapperLockFileName(bundleIdentifier: "com.tron.mac") == ".mac-wrapper.com.tron.mac.lock")
        #expect(TronPaths.macWrapperLockFileName(bundleIdentifier: "com.tron.mac.dev") == ".mac-wrapper.com.tron.mac.dev.lock")
        #expect(TronPaths.macWrapperLockFileName(bundleIdentifier: "com/tron/mac") == ".mac-wrapper.com-tron-mac.lock")
    }

    @Test("engine settings live at the Tron home root")
    func settingsShape() {
        let s = TronPaths.networkCachePath.path
        #expect(s.hasSuffix("/.tron/gateway/network.json"))
    }

}
