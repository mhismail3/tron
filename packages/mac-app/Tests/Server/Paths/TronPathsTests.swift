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

}
