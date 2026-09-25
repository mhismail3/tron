import Darwin
import Foundation
import Testing
@testable import TronMac

/// The wrapper reads its whole-home and agent-directory overrides from the real
/// process environment, so these cases drive the variables the process reads
/// instead of injecting a dictionary. The suite is serialized and every case
/// restores the value it changes.
@Suite("TronPaths constants", .serialized)
struct TronPathsTests {
    @Test("Stable and Debug profiles have independent canonical identities")
    func profilesAreIndependent() {
        #expect(TronPaths.tronHome(profile: .debug).path.hasSuffix("/.tron-dev"))
        #expect(TronPaths.agentHome(profile: .debug).path.hasSuffix("/.tron-dev/agent"))
        #expect(TronPaths.bearerTokenPath(profile: .debug).path.hasSuffix("/.tron-dev/gateway/local-auth.json"))
        #expect(TronPaths.serverHelperBundleProgram(profile: .stable)
            == "Contents/Library/LoginItems/Tron Agent.app/Contents/MacOS/tron")
        #expect(TronPaths.serverHelperBundleProgram(profile: .debug)
            == "Contents/Library/LoginItems/Tron Agent Dev.app/Contents/MacOS/tron")
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

    @Test("the wrapper home is the whole-home override its helper receives")
    func wholeHomeOverrideIsResolved() {
        // TRON_DATA_DIR wins, then TRON_HOME_NAME, then the canonical ~/.tron.
        // The wrapper must resolve the same home the launcher and Gateway config
        // read, or it would manage a different profile than the one running.
        let environment = ProcessInfo.processInfo.environment
        if let override = environment[TronPaths.tronDataDirEnv], !override.isEmpty {
            #expect(TronPaths.tronHome.path == override)
        } else if let homeName = environment[TronPaths.tronHomeNameEnv], !homeName.isEmpty {
            #expect(TronPaths.tronHome.path == TronPaths.homeDirectory.appendingPathComponent(homeName, isDirectory: true).path)
        } else {
            #expect(TronPaths.tronHome.path == TronPaths.homeDirectory.appendingPathComponent(".tron", isDirectory: true).path)
        }
        #expect(TronPaths.tronHome(profile: .stable) == TronPaths.tronHome)
    }

    @Test("production LaunchAgent always advertises Gateway supervision")
    func productionLaunchAgentSupervisionEnvironment() {
        withAgentDirectoryOverride(nil) {
            #expect(TronPaths.launchAgentEnvironmentVariables == [
                TronPaths.gatewaySupervisionEnv: TronPaths.gatewaySupervisionValue,
                TronPaths.gatewayChannelEnv: TronPaths.productionGatewayChannel,
            ])
            #expect(TronPaths.launchAgentEnvironmentVariables(profile: .debug) == [
                TronPaths.gatewaySupervisionEnv: TronPaths.gatewaySupervisionValue,
                TronPaths.gatewayChannelEnv: TronGatewayProfile.debug.channel,
                TronPaths.tronHomeNameEnv: TronGatewayProfile.debug.homeName,
            ])
            #expect(TronPaths.agentHome(profile: .stable) == TronPaths.tronHome.appendingPathComponent("agent", isDirectory: true))
        }
    }

    @Test("Stable custom agent override is propagated without redirecting Debug")
    func stableCustomAgentOverrideIsCoherent() {
        let custom = "/private/tmp/tron-custom-agent"
        withAgentDirectoryOverride(custom) {
            #expect(TronPaths.agentHome(profile: .stable).path == custom)
            #expect(TronPaths.agentHome(profile: .debug).path.hasSuffix("/.tron-dev/agent"))
            #expect(TronPaths.launchAgentEnvironmentVariables(profile: .stable)[TronPaths.piCodingAgentDirEnv] == custom)
            #expect(TronPaths.launchAgentEnvironmentVariables(profile: .debug)[TronPaths.piCodingAgentDirEnv] == nil)
        }
    }
}

/// Sets the agent-directory override for one case and restores the process value.
private func withAgentDirectoryOverride(_ value: String?, _ body: () -> Void) {
    let key = TronPaths.piCodingAgentDirEnv
    let previous = ProcessInfo.processInfo.environment[key]
    defer {
        if let previous { setenv(key, previous, 1) } else { unsetenv(key) }
    }
    if let value { setenv(key, value, 1) } else { unsetenv(key) }
    body()
}
