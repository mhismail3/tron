import Foundation
import Testing
@testable import TronMac

@Suite("Gateway network cache")
struct GatewayNetworkCacheTests {
    @Test("round-trips a trimmed Tailscale address in gateway-owned JSON")
    func roundTrip() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("gateway/network.json")

        try GatewayNetworkCacheWriter.cacheTailscaleIP(" 100.95.255.62 ", at: path)

        #expect(GatewayNetworkCacheReader.tailscaleIP(at: path) == "100.95.255.62")
        let contents = try String(contentsOf: path, encoding: .utf8)
        #expect(contents.contains("\"version\":1"))
        let mode = try #require(try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? NSNumber)
        #expect(mode.intValue & 0o077 == 0)
    }

    @Test("missing and malformed caches are ignored")
    func invalidCache() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let path = root.appendingPathComponent("network.json")
        #expect(GatewayNetworkCacheReader.tailscaleIP(at: path) == nil)
        try "not-json".write(to: path, atomically: true, encoding: .utf8)
        #expect(GatewayNetworkCacheReader.tailscaleIP(at: path) == nil)
    }

    @Test("delete is idempotent")
    func deleteCache() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("network.json")
        try GatewayNetworkCacheWriter.cacheTailscaleIP("100.64.0.1", at: path)
        try GatewayNetworkCacheWriter.deleteCache(at: path)
        try GatewayNetworkCacheWriter.deleteCache(at: path)
        #expect(!FileManager.default.fileExists(atPath: path.path))
    }
}
