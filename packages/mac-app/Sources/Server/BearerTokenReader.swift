import Darwin
import Foundation

/// Reads the wrapper-only bearer token from `gateway/local-auth.json`.
/// Schema validation remains deliberately separate from the secure file read.
enum OwnerOnlyJSONReader {
    /// Reads one owner-only JSON file without reopening a path after checking
    /// it. The descriptor is opened without following symlinks, then every
    /// bound is checked from that descriptor before any bytes are consumed.
    static func readData(at url: URL, maximumBytes: Int) -> Data? {
        guard url.isFileURL, maximumBytes > 0,
              maximumBytes <= Int(off_t.max) else { return nil }
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { return nil }
        defer { _ = close(descriptor) }

        var before = stat()
        guard fstat(descriptor, &before) == 0,
              before.st_uid == getuid(),
              (before.st_mode & S_IFMT) == S_IFREG,
              (before.st_mode & 0o7777) == 0o600,
              before.st_size > 0,
              before.st_size <= off_t(maximumBytes) else { return nil }
        let expectedSize = Int(before.st_size)
        var data = Data(capacity: expectedSize)
        var buffer = [UInt8](repeating: 0, count: min(16 * 1024, expectedSize))
        while data.count < expectedSize {
            let remaining = expectedSize - data.count
            let count = buffer.withUnsafeMutableBytes { bytes in
                read(descriptor, bytes.baseAddress, min(remaining, bytes.count))
            }
            if count < 0 {
                guard errno == EINTR else { return nil }
                continue
            }
            guard count > 0 else { return nil }
            data.append(buffer, count: count)
        }

        // A writer racing this read must not be able to append unnoticed.
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                read(descriptor, bytes.baseAddress, 1)
            }
            if count < 0 {
                guard errno == EINTR else { return nil }
                continue
            }
            guard count == 0 else { return nil }
            break
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0,
              after.st_dev == before.st_dev,
              after.st_ino == before.st_ino,
              after.st_uid == before.st_uid,
              after.st_mode == before.st_mode,
              after.st_size == before.st_size,
              after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec,
              after.st_ctimespec.tv_sec == before.st_ctimespec.tv_sec,
              after.st_ctimespec.tv_nsec == before.st_ctimespec.tv_nsec else { return nil }
        return data
    }
}

enum BearerTokenReader {
    private static let maximumBytes = 64 * 1024
    private static let expectedKeys: Set<String> = ["version", "bearerToken", "purpose", "lastUpdated"]

    static func read(at path: URL) -> String? {
        guard let data = OwnerOnlyJSONReader.readData(at: path, maximumBytes: maximumBytes),
              let object = try? JSONSerialization.jsonObject(with: data),
              let document = object as? [String: Any],
              Set(document.keys) == expectedKeys,
              let version = document["version"] as? Int, version == 2,
              let token = document["bearerToken"] as? String,
              token.utf8.count >= 32, token.utf8.count <= 256,
              let purpose = document["purpose"] as? String, purpose == "local-wrapper-health",
              let timestamp = document["lastUpdated"] as? String,
              isGatewayTimestamp(timestamp) else { return nil }
        return token
    }

    private static func isGatewayTimestamp(_ value: String) -> Bool {
        guard value.utf8.count <= 64,
              value.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?(?:Z|[+-]\d{2}:\d{2})$"#, options: .regularExpression) != nil else {
            return false
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if formatter.date(from: value) != nil { return true }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value) != nil
    }
}
