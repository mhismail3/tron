import Foundation
import Darwin

/// Reads the wrapper-only bearer token from `gateway/local-auth.json`.
/// The file is treated as hostile input: symlinks, non-regular files,
/// oversized data, broad permissions, and any credential shape drift fail closed.
enum BearerTokenReader {
    private static let maximumBytes = 64 * 1024
    private static let expectedKeys: Set<String> = ["version", "bearerToken", "purpose", "lastUpdated"]

    /// Reads the token only when the Gateway-owned credential is an owner-only,
    /// regular file with the exact version-2 local-wrapper-health shape.
    static func read(at path: URL) -> String? {
        var info = stat()
        guard lstat(path.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              (info.st_mode & 0o077) == 0,
              info.st_size > 0,
              info.st_size <= off_t(maximumBytes) else {
            return nil
        }
        guard let data = try? Data(contentsOf: path), data.count <= maximumBytes,
              let object = try? JSONSerialization.jsonObject(with: data),
              let document = object as? [String: Any],
              Set(document.keys) == expectedKeys,
              let version = document["version"] as? Int, version == 2,
              let token = document["bearerToken"] as? String,
              token.utf8.count >= 32, token.utf8.count <= 256,
              let purpose = document["purpose"] as? String, purpose == "local-wrapper-health",
              let timestamp = document["lastUpdated"] as? String,
              isGatewayTimestamp(timestamp) else {
            return nil
        }
        return token
    }

    private static func isGatewayTimestamp(_ value: String) -> Bool {
        guard value.utf8.count <= 64,
              value.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?(?:Z|[+-]\d{2}:\d{2})$"#, options: .regularExpression) != nil else {
            return false
        }
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: value) != nil
    }
}
