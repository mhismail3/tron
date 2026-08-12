import Foundation

/// Disposable wrapper presentation cache. Agent settings remain owned by the
/// embedded runtime under its canonical agent directory.
enum GatewayNetworkCacheReader {
    private struct Document: Decodable {
        let version: Int
        let tailscaleIP: String
    }

    static func tailscaleIP(at path: URL) -> String? {
        guard let data = try? Data(contentsOf: path),
              let document = try? JSONDecoder().decode(Document.self, from: data),
              document.version == 1 else { return nil }
        let value = document.tailscaleIP.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

enum GatewayNetworkCacheWriter {
    private struct Document: Encodable {
        let version = 1
        let tailscaleIP: String
        let updatedAt: String
    }

    static func cacheTailscaleIP(_ value: String, at path: URL) throws {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let document = Document(tailscaleIP: value, updatedAt: ISO8601DateFormatter().string(from: Date()))
        let data = try JSONEncoder().encode(document)
        try data.write(to: path, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }

    static func deleteCache(at path: URL) throws {
        guard FileManager.default.fileExists(atPath: path.path) else { return }
        try FileManager.default.removeItem(at: path)
    }
}
