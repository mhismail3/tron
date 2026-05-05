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

    @Test("helper bundle ID matches the production LaunchAgent label")
    func bundleIDMatches() {
        // The agent's CFBundleIdentifier MUST equal the LaunchAgent
        // production label so SMAppService registration and launchctl diagnostics
        // refer to the same production service. Historical mismatch
        // (bundleID="com.tron.agent", label="com.tron.server") caused
        // status checks to report the wrong service; the two unified
        // as `com.tron.server`.
        #expect(TronPaths.bundleID == "com.tron.server")
        #expect(TronPaths.bundleID == TronPaths.productionLaunchAgentLabel)
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

    @Test("runtime locks live in internal/run")
    func runDirShape() {
        #expect(TronPaths.runDir.path.hasSuffix("/internal/run"))
    }

    @Test("database lock stays beside log.db")
    func databaseLockShape() {
        #expect(TronPaths.databaseLockPath.path.hasSuffix("/internal/database/log.db.lock"))
    }

    @Test("LaunchAgent plist is bundled in Contents/Library/LaunchAgents")
    func launchAgentPlistShape() {
        let plist = TronPaths.launchAgentPlistPath.path
        #expect(plist.contains("/Contents/Library/LaunchAgents/com.tron.server.plist"))
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
        #expect(TronPaths.updaterStatePath.path.hasSuffix("/internal/run/updater-state.json"))
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

    @Test("transcription sidecar files live under internal/transcription")
    func transcriptionShape() {
        #expect(TronPaths.transcriptionDir.path.hasSuffix("/internal/transcription"))
        #expect(TronPaths.transcriptionResourceDir.path.hasSuffix("/Contents/Resources/Transcription")
                || TronPaths.transcriptionResourceDir.path.contains("/Resources/Transcription"))
    }

    @Test("managed skills sync from bundle resources into ~/.tron/skills")
    func managedSkillsShape() {
        #expect(TronPaths.skillsDir.path.hasSuffix("/.tron/skills"))
        #expect(TronPaths.managedSkillsResourceDir.path.hasSuffix("/Contents/Resources/Skills")
                || TronPaths.managedSkillsResourceDir.path.contains("/Resources/Skills"))
    }
}
