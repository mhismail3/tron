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
        // label so `launchctl kickstart gui/$UID/<bundleID>` after a
        // TCC grant hits the right service. Historical mismatch
        // (bundleID="com.tron.agent", label="com.tron.server") caused
        // the permissions wizard to kickstart a service that didn't
        // exist; the two unified as `com.tron.server`.
        #expect(TronPaths.bundleID == "com.tron.server")
        #expect(TronPaths.bundleID == TronPaths.launchAgentLabel)
    }

    @Test("agent display name is 'Tron Server'")
    func agentDisplayNameMatches() {
        // System Settings lists CFBundleDisplayName (fallback
        // CFBundleName). Calling the agent "Tron Server" — distinct
        // from the menu-bar wrapper's "Tron" — is what prevents the
        // FDA / Screen Recording / Accessibility panes from showing
        // two indistinguishable "Tron" entries.
        #expect(TronPaths.agentDisplayName == "Tron Server")
    }

    @Test("installed binary lives inside Tron.app/Contents/MacOS")
    func installedBinaryShape() {
        let bin = TronPaths.installedBinary.path
        #expect(bin.hasSuffix("/Tron.app/Contents/MacOS/tron"))
    }

    @Test("dev binary lives under deployment/")
    func devBinaryShape() {
        let bin = TronPaths.devBinary.path
        #expect(bin.contains("/deployment/Tron-Dev.app/Contents/MacOS/tron"))
    }

    @Test("LaunchAgent plist sits in ~/Library/LaunchAgents/")
    func launchAgentPlistShape() {
        let plist = TronPaths.launchAgentPlistPath.path
        #expect(plist.contains("/Library/LaunchAgents/com.tron.server.plist"))
    }

    @Test("auth-token.json lives in system/")
    func bearerTokenShape() {
        let tok = TronPaths.bearerTokenPath.path
        #expect(tok.hasSuffix("/system/auth-token.json"))
    }

    @Test("onboarded sentinel lives in system/")
    func onboardedShape() {
        let s = TronPaths.onboardedMarkerPath.path
        #expect(s.hasSuffix("/system/.onboarded"))
    }

    @Test("settings.json lives in system/")
    func settingsShape() {
        let s = TronPaths.settingsPath.path
        #expect(s.hasSuffix("/system/settings.json"))
    }
}
