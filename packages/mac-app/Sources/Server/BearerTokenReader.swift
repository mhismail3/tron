import Foundation

/// Reads the wrapper-only bearer token from
/// `~/.tron/gateway/local-auth.json`. This credential authenticates the signed
/// Mac wrapper and is never included in pairing invitations.
///
/// Gateway-owned file format:
/// ```json
/// {
///   "version": 2,
///   "bearerToken": "trn_<random token>",
///   "purpose": "local-wrapper-health",
///   "lastUpdated": "..."
/// }
/// ```
///
/// Security INVARIANT: `local-auth.json` MUST have owner-only permissions. Any
/// group or other permission bit indicates either a tampered file or a buggy
/// writer; in either case the token is treated as untrusted and `read` returns
/// nil with an `NSLog` audit line. No caller may bypass this check.
///
/// Tests in `Tests/Server/BearerTokenReaderTests.swift` cover happy
/// path, missing file, malformed JSON, missing `bearerToken`, and the
/// permission guard. The gateway creates this file with mode `0o600`.
enum BearerTokenReader {
    private struct AuthFile: Decodable {
        let bearerToken: String?
    }

    /// Reads the token file. Returns nil if missing, empty, malformed,
    /// or has unsafe permissions.
    static func read(at path: URL) -> String? {
        if !permissionsAreSafe(at: path) {
            return nil
        }
        guard let data = try? Data(contentsOf: path), !data.isEmpty else {
            return nil
        }

        guard let decoded = try? JSONDecoder().decode(AuthFile.self, from: data) else {
            return nil
        }
        return nonEmpty(decoded.bearerToken ?? "")
    }

    /// Returns true when the file has no group or other permission bits.
    /// A missing file returns true (caller surfaces the
    /// "missing" case via `read` returning nil for empty data).
    private static func permissionsAreSafe(at path: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path.path) else {
            return true
        }
        let attrs: [FileAttributeKey: Any]
        do {
            attrs = try fm.attributesOfItem(atPath: path.path)
        } catch {
            NSLog("[BearerTokenReader] cannot stat %@: %@", path.path, error.localizedDescription)
            return false
        }
        let mode = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        let unsafeMask = 0o077
        if mode & unsafeMask != 0 {
            NSLog(
                "[BearerTokenReader] refusing to read %@: mode 0o%o exposes group/other permissions. Re-run `tron auth rotate`.",
                path.path,
                mode & 0o777
            )
            return false
        }
        return true
    }

    private static func nonEmpty(_ string: String) -> String? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
