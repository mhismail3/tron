import Darwin
import Foundation
import Testing
@testable import TronMac

@Suite("Gateway network cache files")
struct GatewayNetworkCacheFilesystemTests {
    private func publish(_ version: String, at path: URL) throws -> Data {
        let data = Data("{\"version\":\(version),\"tailscaleIP\":\"100.64.0.1\",\"updatedAt\":\"2026-10-25T12:00:00Z\"}".utf8)
        try data.write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        return data
    }

    @Test(arguments: ["1", "1.0", "1e0"])
    func numericVersionOneRemainsReadable(_ version: String) throws {
        let root = TestTempDir.make()
        defer { TestTempDir.cleanup(root) }
        let path = root.appendingPathComponent("network.json")
        let prior = try publish(version, at: path)
        #expect(GatewayNetworkCacheReader.tailscaleIP(at: path) == "100.64.0.1")
        #expect(try Data(contentsOf: path) == prior)
    }

    @Test(arguments: ["true", "false", "2", "\"1\"", "null", "1.5"])
    func unsupportedVersionsAreIgnoredWithoutRewriting(_ version: String) throws {
        let root = TestTempDir.make()
        defer { TestTempDir.cleanup(root) }
        let path = root.appendingPathComponent("network.json")
        let prior = try publish(version, at: path)
        #expect(GatewayNetworkCacheReader.tailscaleIP(at: path) == nil)
        #expect(try Data(contentsOf: path) == prior)
    }

    @Test func writerRoundTripKeepsOwnerOnlyCanonicalFile() throws {
        let root = TestTempDir.make()
        defer { TestTempDir.cleanup(root) }
        let path = root.appendingPathComponent("cache/network.json")
        try GatewayNetworkCacheWriter.cacheTailscaleIP(" 100.64.0.1\n", at: path)
        #expect(GatewayNetworkCacheReader.tailscaleIP(at: path) == "100.64.0.1")
        let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect((attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid())
        let document = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any]
        #expect(document?["tailscaleIP"] as? String == "100.64.0.1")
        #expect(try FileManager.default.contentsOfDirectory(atPath: path.deletingLastPathComponent().path) == ["network.json"])
    }

    @Test func broadPermissionsAndSymlinksRemainRefused() throws {
        let root = TestTempDir.make()
        defer { TestTempDir.cleanup(root) }
        let path = root.appendingPathComponent("network.json")
        let prior = try publish("1", at: path)
        #expect(GatewayNetworkCacheReader.tailscaleIP(at: path) == "100.64.0.1")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path.path)
        #expect(GatewayNetworkCacheReader.tailscaleIP(at: path) == nil)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        #expect(GatewayNetworkCacheReader.tailscaleIP(at: path) == "100.64.0.1")
        let link = root.appendingPathComponent("linked.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: path)
        #expect(GatewayNetworkCacheReader.tailscaleIP(at: link) == nil)
        #expect(try Data(contentsOf: path) == prior)
    }
}
