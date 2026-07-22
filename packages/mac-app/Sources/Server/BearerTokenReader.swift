import Foundation

/// Reads the bearer token from `bearerToken` in `~/.tron/auth.json`.
/// This is the same file written by the Rust agent's
/// `app::lifecycle::onboarding` module through the shared auth-storage atomic
/// writer.
///
/// File format (matches `packages/agent/src/app/lifecycle/onboarding.rs`):
/// ```json
/// {
///   "version": 1,
///   "bearerToken": "<url-safe base64, 32 bytes>",
///   "providers": {},
///   "lastUpdated": "..."
/// }
/// ```
///
/// Security INVARIANT: `auth.json` MUST have owner-only permissions. Any group
/// or other permission bit indicates either a tampered file or a buggy writer;
/// in either case the token is treated as untrusted and `read` returns nil with
/// an `NSLog` audit line. No caller may bypass this check. The Rust writer uses
/// mode `0o600` at write time (see
/// `packages/agent/src/domains/auth/credentials/storage/mod.rs::save_auth_storage`).
///
/// Tests in `Tests/Server/BearerTokenReaderTests.swift` cover happy
/// path, missing file, malformed JSON, missing `bearerToken`, and the
/// permission guard.
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
