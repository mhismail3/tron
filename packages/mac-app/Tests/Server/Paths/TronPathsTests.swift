import Foundation
import Testing
@testable import TronMac

@Suite("TronPaths constants")
struct TronPathsTests {
    @Test("LaunchAgent label matches the canonical label")
    func launchAgentLabelMatches() {
        #expect(TronPaths.launchAgentLabel(environment: [:]) == "com.tron.server")
    }

    @Test("default port matches the agent default")
    func defaultPortMatches() {
        #expect(TronPaths.defaultServerPort(environment: [:]) == 9847)
    }

    @Test("helper bundle ID matches the production LaunchAgent label")
    func bundleIDMatches() {
        // The agent's CFBundleIdentifier MUST equal the LaunchAgent
        // production label so SMAppService registration and launchctl diagnostics
        // refer to the same production service. Historical mismatch
        // (bundleID="com.tron.agent", label="com.tron.server") caused
        // status checks to report the wrong service; the two unified
        // as `com.tron.server`.
        #expect(TronPaths.bundleID(environment: [:]) == "com.tron.server")
        #expect(TronPaths.bundleID(environment: [:]) == TronPaths.productionLaunchAgentLabel)
    }

    @Test("agent display name is 'Tron Server'")
    func agentDisplayNameMatches() {
        // System Settings lists CFBundleDisplayName, then CFBundleName.
        // Calling the agent "Tron Server" keeps the
        // helper entry distinct from the responsible wrapper entry
        // used by Full Disk Access.
        #expect(TronPaths.agentDisplayName(environment: [:]) == "Tron Server")
    }

    @Test("LaunchAgent associates with wrapper variants")
    func associatedWrapperBundleIDsMatchVariants() {
        #expect(TronPaths.associatedWrapperBundleIDs(environment: [:]) == [
            MacRuntimeVariant.releaseBundleIdentifier,
            MacRuntimeVariant.debugBundleIdentifier,
        ])
        #expect(TronPaths.associatedWrapperBundleIDs(
            environment: [TronPaths.isolatedInstallModeEnv: TronPaths.isolatedInstallModeValue]
        ) == [
            MacRuntimeVariant.debugBundleIdentifier,
            MacRuntimeVariant.releaseBundleIdentifier,
        ])
    }

    @Test("server helper binary lives inside the bundled Login Item")
    func serverHelperBinaryShape() {
        #expect(TronPaths.serverHelperBundleProgram(environment: [:]) == "Contents/Library/LoginItems/Tron Server.app/Contents/MacOS/tron")
    }

    @Test("isolated install mode uses the dev helper, port, and home")
    func isolatedInstallModeShape() {
        let environment = [TronPaths.isolatedInstallModeEnv: TronPaths.isolatedInstallModeValue]

        #expect(TronPaths.launchAgentLabel(environment: environment) == "com.tron.server.dev")
        #expect(TronPaths.defaultServerPort(environment: environment) == 9848)
        #expect(TronPaths.agentBundleName(environment: environment) == "Tron Server Dev")
        #expect(TronPaths.serverHelperBundleProgram(environment: environment) == "Contents/Library/LoginItems/Tron Server Dev.app/Contents/MacOS/tron")
        #expect(TronPaths.launchAgentEnvironmentVariables(environment: environment) == [
            "RUST_LOG": "info",
            TronPaths.tronHomeNameEnv: ".tron-dev",
        ])
        #expect(TronPaths.tronHome(environment: environment).path.hasSuffix("/.tron-dev"))
    }

    @Test("TRON_HOME_NAME overrides isolated install home with a single directory name")
    func tronHomeNameOverridesIsolatedHome() {
        let environment = [
            TronPaths.isolatedInstallModeEnv: TronPaths.isolatedInstallModeValue,
            TronPaths.tronHomeNameEnv: ".tron-sandbox",
        ]

        #expect(TronPaths.tronHome(environment: environment).path.hasSuffix("/.tron-sandbox"))
    }

    @Test("runtime locks live in internal/run")
    func runDirShape() {
        #expect(TronPaths.runDir.path.hasSuffix("/internal/run"))
    }

    @Test("database lock stays beside tron.sqlite")
    func databaseLockShape() {
        #expect(TronPaths.databaseLockPath.path.hasSuffix("/internal/database/tron.sqlite.lock"))
    }

    @Test("LaunchAgent plist is bundled in Contents/Library/LaunchAgents")
    func launchAgentPlistShape() {
        #expect(TronPaths.launchAgentLabel(environment: [:]) == "com.tron.server")
        #expect(TronPaths.launchAgentLabel(environment: [TronPaths.isolatedInstallModeEnv: TronPaths.isolatedInstallModeValue]) == "com.tron.server.dev")
    }

    @Test("auth.json lives in profiles/")
    func bearerTokenShape() {
        let tok = TronPaths.bearerTokenPath.path
        #expect(tok.hasSuffix("/profiles/auth.json"))
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

    @Test("profile settings overlay lives in the user profile")
    func settingsShape() {
        let s = TronPaths.settingsPath.path
        #expect(s.hasSuffix("/profiles/user/profile.toml"))
    }

}
