import Foundation
import Testing
@testable import TronMobile

@Suite("APNs Environment Tests")
struct APNsEnvironmentTests {
    @Test("embedded profile parser reads development entitlement")
    func parsesDevelopmentEntitlement() throws {
        let profile = """
        prefix
        <plist version="1.0"><dict><key>Entitlements</key><dict>
        <key>aps-environment</key><string>development</string>
        </dict></dict></plist>
        suffix
        """
        let data = try #require(profile.data(using: .isoLatin1))
        #expect(APNsEnvironment.parseEntitlement(fromProfileData: data) == "development")
    }

    @Test("embedded profile parser rejects unsupported entitlement")
    func rejectsUnsupportedEntitlement() throws {
        let profile = """
        <plist version="1.0"><dict><key>Entitlements</key><dict>
        <key>aps-environment</key><string>sandbox</string>
        </dict></dict></plist>
        """
        let data = try #require(profile.data(using: .isoLatin1))
        #expect(APNsEnvironment.parseEntitlement(fromProfileData: data) == nil)
    }
}
