import Darwin
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

    @Test("rejects hostile paths, oversized documents, unknown keys, and non-Tailscale addresses")
    func hostileCacheInputs() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let path = root.appendingPathComponent("network.json")
        let timestamp = ISO8601DateFormatter().string(from: Date())
        func write(_ contents: String, mode: Int = 0o600) throws {
            try contents.write(to: path, atomically: true, encoding: .utf8)
            chmod(path.path, mode_t(mode))
        }
        func document(address: String, unknown: Bool = false) -> String {
            let extra = unknown ? ",\"unknown\":true" : ""
            return "{\"version\":1,\"tailscaleIP\":\"\(address)\",\"updatedAt\":\"\(timestamp)\"\(extra)}"
        }
        try write(document(address: "100.64.0.1"))
        #expect(GatewayNetworkCacheReader.tailscaleIP(at: path) == "100.64.0.1")
        try write(document(address: "192.168.1.2"))
        #expect(GatewayNetworkCacheReader.tailscaleIP(at: path) == nil)
        try write(document(address: "100.64.0.1", unknown: true))
        #expect(GatewayNetworkCacheReader.tailscaleIP(at: path) == nil)
        try write(String(repeating: "x", count: GatewayNetworkCacheReader.maximumBytes + 1))
        #expect(GatewayNetworkCacheReader.tailscaleIP(at: path) == nil)

        chmod(path.path, 0o644)
        #expect(GatewayNetworkCacheReader.tailscaleIP(at: path) == nil)
        try FileManager.default.removeItem(at: path)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
        #expect(GatewayNetworkCacheReader.tailscaleIP(at: path) == nil)
    }

    @Test("rejects symlink and unsafe writer destinations")
    func hostileWriterDestinations() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        #expect(throws: Error.self) {
            try GatewayNetworkCacheWriter.cacheTailscaleIP("192.168.1.2", at: root.appendingPathComponent("invalid.json"))
        }
        let modePath = root.appendingPathComponent("mode.json")
        try "existing".write(to: modePath, atomically: true, encoding: .utf8)
        chmod(modePath.path, 0o644)
        #expect(throws: Error.self) {
            try GatewayNetworkCacheWriter.cacheTailscaleIP("100.64.0.1", at: modePath)
        }
        let directoryPath = root.appendingPathComponent("directory.json")
        try FileManager.default.createDirectory(at: directoryPath, withIntermediateDirectories: false)
        #expect(throws: Error.self) {
            try GatewayNetworkCacheWriter.cacheTailscaleIP("100.64.0.1", at: directoryPath)
        }
        let target = root.appendingPathComponent("target.json")
        try GatewayNetworkCacheWriter.cacheTailscaleIP("100.64.0.1", at: target)
        let symlinkPath = root.appendingPathComponent("symlink.json")
        try FileManager.default.createSymbolicLink(at: symlinkPath, withDestinationURL: target)
        #expect(throws: Error.self) {
            try GatewayNetworkCacheWriter.cacheTailscaleIP("100.64.0.2", at: symlinkPath)
        }
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
