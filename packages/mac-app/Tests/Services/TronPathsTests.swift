import Foundation
import Testing
@testable import TronMac

@Suite("TronPaths constants")
struct TronPathsTests {
    @Test("LaunchAgent label matches the canonical label")
    func launchAgentLabelMatches() {
        #expect(TronPaths.launchAgentLabel == "com.tron.server")
    }

    @Test("default port matches the agent default")
    func defaultPortMatches() {
        #expect(TronPaths.defaultServerPort == 9847)
    }

    @Test("bundle ID matches the LaunchAgent label")
    func bundleIDMatches() {
        // The agent's CFBundleIdentifier MUST equal the LaunchAgent
        // label so SMAppService registration and launchctl diagnostics
        // always refer to the same service. Historical mismatch
        // (bundleID="com.tron.agent", label="com.tron.server") caused
        // status checks to report the wrong service; the two unified
        // as `com.tron.server`.
        #expect(TronPaths.bundleID == "com.tron.server")
        #expect(TronPaths.bundleID == TronPaths.launchAgentLabel)
    }

    @Test("agent display name is 'Tron Server'")
    func agentDisplayNameMatches() {
        // System Settings lists CFBundleDisplayName (fallback
        // CFBundleName). Calling the agent "Tron Server" keeps the
        // Accessibility entry distinct from the responsible wrapper
        // entry used by FDA / Screen Recording.
        #expect(TronPaths.agentDisplayName == "Tron Server")
    }

    @Test("LaunchAgent associates with wrapper variants")
    func associatedWrapperBundleIDsMatchVariants() {
        #expect(TronPaths.associatedWrapperBundleIDs == [
            MacRuntimeVariant.releaseBundleIdentifier,
            MacRuntimeVariant.debugBundleIdentifier,
        ])
    }

    @Test("server helper binary lives inside the bundled Login Item")
    func serverHelperBinaryShape() {
        let bin = TronPaths.serverHelperBinary.path
        #expect(bin.hasSuffix("/Contents/Library/LoginItems/Tron Server.app/Contents/MacOS/tron"))
    }

    @Test("runtime locks live in system/run")
    func runDirShape() {
        #expect(TronPaths.runDir.path.hasSuffix("/system/run"))
    }

    @Test("database lock stays beside log.db")
    func databaseLockShape() {
        #expect(TronPaths.databaseLockPath.path.hasSuffix("/system/database/log.db.lock"))
    }

    @Test("LaunchAgent plist is bundled in Contents/Library/LaunchAgents")
    func launchAgentPlistShape() {
        let plist = TronPaths.launchAgentPlistPath.path
        #expect(plist.contains("/Contents/Library/LaunchAgents/com.tron.server.plist"))
    }

    @Test("auth.json lives in system/")
    func bearerTokenShape() {
        let tok = TronPaths.bearerTokenPath.path
        #expect(tok.hasSuffix("/system/auth.json"))
    }

    @Test("onboarded sentinel lives in system/run/")
    func onboardedShape() {
        let s = TronPaths.onboardedMarkerPath.path
        #expect(s.hasSuffix("/system/run/.onboarded"))
    }

    @Test("runtime uninstall files live in system/run/")
    func runtimeUninstallFilesShape() {
        #expect(TronPaths.updaterStatePath.path.hasSuffix("/system/run/updater-state.json"))
        #expect(TronPaths.authLockPath.path.hasSuffix("/system/run/auth.lock"))
        #expect(TronPaths.macWrapperLockPath.path.hasSuffix("/system/run/.mac-wrapper.lock"))
    }

    @Test("settings.json lives in system/")
    func settingsShape() {
        let s = TronPaths.settingsPath.path
        #expect(s.hasSuffix("/system/settings.json"))
    }

    @Test("transcription sidecar files live under system/transcription")
    func transcriptionShape() {
        #expect(TronPaths.transcriptionDir.path.hasSuffix("/system/transcription"))
        #expect(TronPaths.transcriptionResourceDir.path.hasSuffix("/Contents/Resources/Transcription")
                || TronPaths.transcriptionResourceDir.path.contains("/Resources/Transcription"))
    }
}
