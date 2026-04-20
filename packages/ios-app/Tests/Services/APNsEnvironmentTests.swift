import Testing
import Foundation
@testable import TronMobile

/// Tests the runtime parse of `embedded.mobileprovision`. The plist is
/// embedded inside a PKCS7-signed binary in real profiles; we only need
/// to prove the extractor + plist decode + value mapping works.
@Suite("APNsEnvironment Tests")
struct APNsEnvironmentTests {

    /// Builds a plist string wrapped in fake binary prefix/suffix to
    /// mimic the real `.mobileprovision` layout.
    private func fakeProfile(apsEnv: String?) -> String {
        let entry = apsEnv.map {
            """
                <key>aps-environment</key>
                <string>\($0)</string>
            """
        } ?? ""
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>AppIDName</key>
            <string>Test</string>
            <key>Entitlements</key>
            <dict>\(entry)
                <key>application-identifier</key>
                <string>TEAM.com.test</string>
            </dict>
            <key>Name</key>
            <string>Test Profile</string>
        </dict>
        </plist>
        """
        // Wrap in binary-ish padding so the extractor has to locate <plist> inside noise.
        return "\u{30}\u{82}BINARY_PKCS7_SIGNATURE_BYTES\(plist)BINARY_SUFFIX\u{00}\u{FF}"
    }

    @Test("parses aps-environment=production as production")
    func parsesProduction() {
        let result = APNsEnvironment.parseEntitlementFromProfileString(
            fakeProfile(apsEnv: "production")
        )
        #expect(result == "production")
    }

    @Test("parses aps-environment=development as sandbox")
    func parsesDevelopment() {
        // *** Regression test for the 2026-04-20 incident. ***
        // Xcode-signed Prod builds get `aps-environment=development` injected
        // by the Development provisioning profile, regardless of what the
        // entitlements file declares. The old `#if DEBUG` heuristic reported
        // "production" for release configs → BadDeviceToken on every send.
        let result = APNsEnvironment.parseEntitlementFromProfileString(
            fakeProfile(apsEnv: "development")
        )
        #expect(result == "sandbox")
    }

    @Test("missing aps-environment key returns nil (caller falls back)")
    func missingKey() {
        let result = APNsEnvironment.parseEntitlementFromProfileString(
            fakeProfile(apsEnv: nil)
        )
        #expect(result == nil)
    }

    @Test("unknown aps-environment value returns nil")
    func unknownValue() {
        let result = APNsEnvironment.parseEntitlementFromProfileString(
            fakeProfile(apsEnv: "some-future-value")
        )
        #expect(result == nil)
    }

    @Test("malformed input returns nil, never crashes")
    func malformedInput() {
        #expect(APNsEnvironment.parseEntitlementFromProfileString("not a profile") == nil)
        #expect(APNsEnvironment.parseEntitlementFromProfileString("") == nil)
        #expect(APNsEnvironment.parseEntitlementFromProfileString("<plist>no closing tag") == nil)
        #expect(APNsEnvironment.parseEntitlementFromProfileString("<plist></plist>") == nil)
    }

    @Test("real-world production profile shape parses correctly")
    func productionProfileRealistic() {
        let realistic = """
        garbage-PKCS7-prefix
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0">
        <dict>
            <key>Entitlements</key>
            <dict>
                <key>application-identifier</key>
                <string>MYGKXH6TY4.com.tron.mobile</string>
                <key>aps-environment</key>
                <string>production</string>
                <key>com.apple.developer.team-identifier</key>
                <string>MYGKXH6TY4</string>
            </dict>
        </dict>
        </plist>
        trailing-PKCS7-suffix
        """
        let result = APNsEnvironment.parseEntitlementFromProfileString(realistic)
        #expect(result == "production")
    }

    @Test("real-world dev-signed Prod build shape parses as sandbox")
    func devSignedProdBuildShape() {
        // What the user actually sees: Prod entitlements file declares
        // production, but Xcode's Development profile overrides to
        // development. This is what `embedded.mobileprovision` says.
        let devSignedProd = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0">
        <dict>
            <key>Entitlements</key>
            <dict>
                <key>application-identifier</key>
                <string>MYGKXH6TY4.com.tron.mobile</string>
                <key>aps-environment</key>
                <string>development</string>
            </dict>
        </dict>
        </plist>
        """
        #expect(APNsEnvironment.parseEntitlementFromProfileString(devSignedProd) == "sandbox")
    }

    @Test("Data variant decodes byte-preserving input")
    func parsesFromData() {
        let profile = fakeProfile(apsEnv: "development")
        let data = profile.data(using: .isoLatin1)!
        #expect(APNsEnvironment.parseEntitlementFromProfileData(data) == "sandbox")
    }

    @Test("current() always returns sandbox or production, never anything else")
    func currentAlwaysValid() {
        // On the simulator with no embedded.mobileprovision, current()
        // falls back to #if DEBUG → "sandbox". On a real-device test run
        // with a dev-signed build, it reads the profile → "sandbox". Either
        // way, it MUST be one of the two canonical values.
        let env = APNsEnvironment.current()
        #expect(env == "sandbox" || env == "production")
    }
}
