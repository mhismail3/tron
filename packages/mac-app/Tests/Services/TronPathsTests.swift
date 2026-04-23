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

    @Test("bundle ID matches the deployed Tron.app inner identifier")
    func bundleIDMatches() {
        #expect(TronPaths.bundleID == "com.tron.agent")
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
