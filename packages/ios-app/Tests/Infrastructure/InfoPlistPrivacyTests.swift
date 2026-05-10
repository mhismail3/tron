import Foundation
import Testing

@Suite("Info.plist privacy declarations")
struct InfoPlistPrivacyTests {

    @Test("declares local network use for Mac pairing")
    func declaresLocalNetworkUseForMacPairing() throws {
        let plist = try Self.sourceInfoPlist()
        let message = try #require(plist["NSLocalNetworkUsageDescription"] as? String)
        #expect(message.contains("Mac"))
        #expect(message.contains("Tailscale"))
    }

    private static func sourceInfoPlist() throws -> [String: Any] {
        let testFile = URL(fileURLWithPath: #filePath)
        let plistURL = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Info.plist")
        let data = try Data(contentsOf: plistURL)
        let object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        return try #require(object as? [String: Any])
    }
}
