import Darwin
import Foundation

/// Disposable wrapper presentation cache. Agent settings remain owned by the
/// embedded runtime under its canonical agent directory.
enum GatewayNetworkCacheReader {
    static let maximumBytes = 64 * 1024
    private static let expectedKeys: Set<String> = ["version", "tailscaleIP", "updatedAt"]

    static func tailscaleIP(at path: URL) -> String? {
        guard let data = OwnerOnlyJSONReader.readData(at: path, maximumBytes: maximumBytes),
              let object = try? JSONSerialization.jsonObject(with: data),
              let document = object as? [String: Any],
              Set(document.keys) == expectedKeys,
              let version = document["version"] as? Int, version == 1,
              let value = document["tailscaleIP"] as? String,
              let updatedAt = document["updatedAt"] as? String,
              isTimestamp(updatedAt) else { return nil }
        let address = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return TailscaleProbe.isTailscaleAddress(address) ? address : nil
    }

    private static func isTimestamp(_ value: String) -> Bool {
        guard value.utf8.count <= 64 else { return false }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if formatter.date(from: value) != nil { return true }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value) != nil
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
        guard TailscaleProbe.isTailscaleAddress(value) else {
            throw NSError(domain: "GatewayNetworkCache", code: 1, userInfo: [NSLocalizedDescriptionKey: "cache address is not a Tailscale address"])
        }
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try validateDestination(path)

        let document = Document(tailscaleIP: value, updatedAt: ISO8601DateFormatter().string(from: Date()))
        let data = try JSONEncoder().encode(document)
        let temporary = path.deletingLastPathComponent()
            .appendingPathComponent(".network.json-\(UUID().uuidString)")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        do {
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let written = write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    if written < 0 {
                        if errno == EINTR { continue }
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                    offset += written
                }
            }
            guard fchmod(descriptor, 0o600) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            guard fsync(descriptor) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            _ = close(descriptor)
            try validateDestination(path)
            guard rename(temporary.path, path.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            _ = close(descriptor)
            try? fileManager.removeItem(at: temporary)
            throw error
        }
    }

    private static func validateDestination(_ path: URL) throws {
        var value = stat()
        if lstat(path.path, &value) != 0 {
            guard errno == ENOENT else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            return
        }
        guard (value.st_mode & S_IFMT) == S_IFREG,
              value.st_uid == getuid(),
              (value.st_mode & 0o7777) == 0o600 else {
            throw NSError(domain: "GatewayNetworkCache", code: 2, userInfo: [NSLocalizedDescriptionKey: "cache destination is not an owner-only regular file"])
        }
    }

    static func deleteCache(at path: URL) throws {
        guard FileManager.default.fileExists(atPath: path.path) else { return }
        try FileManager.default.removeItem(at: path)
    }
}
