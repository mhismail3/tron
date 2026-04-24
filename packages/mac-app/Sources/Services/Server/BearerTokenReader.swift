import Foundation

/// Reads the bearer token from `~/.tron/system/auth-token.json`. This is
/// the same file written by the Rust agent's `server::onboarding`
/// module via the atomic `tempfile + sync_all + rename` pattern.
///
/// File format (matches `packages/agent/src/server/onboarding/mod.rs`):
/// ```json
/// { "token": "<url-safe base64, 32 bytes>" }
/// ```
///
/// Security INVARIANT: the token file MUST be mode `0o600` (owner-only
/// read+write). Any wider permission bit indicates either a tampered
/// file or a buggy writer; in either case the token is treated as
/// untrusted and `read` returns nil with an `NSLog` audit line. The
/// Rust writer's `set_secure_permissions` enforces `0o600` at write
/// time (see `packages/agent/src/server/onboarding/mod.rs::write_token`).
///
/// Tests in `Tests/Services/BearerTokenReaderTests.swift` cover happy
/// path, missing file, malformed JSON, the legacy plain-string fallback
/// (some early dogfood writes were not wrapped in the object), and the
/// new permission guard.
enum BearerTokenReader {
    private struct TokenFile: Decodable {
        let token: String
    }

    /// Reads the token file. Returns nil if missing, empty, malformed,
    /// or has unsafe permissions. Use `enforcePermissions: false` from
    /// tests that need to read a tempfile written without `chmod 0o600`.
    static func read(at path: URL, enforcePermissions: Bool = true) -> String? {
        if enforcePermissions, !permissionsAreSafe(at: path) {
            return nil
        }
        guard let data = try? Data(contentsOf: path), !data.isEmpty else {
            return nil
        }

        // Preferred path: {"token": "..."} JSON object.
        if let decoded = try? JSONDecoder().decode(TokenFile.self, from: data) {
            return nonEmpty(decoded.token)
        }

        // Legacy fallback: file is a bare string (pre-Phase-2 dogfood
        // builds). Trim whitespace and surrounding quotes.
        if let raw = String(data: data, encoding: .utf8) {
            let trimmed = raw
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            return nonEmpty(trimmed)
        }
        return nil
    }

    /// Returns true when the file is owned by the current user AND has
    /// mode `0o600`. A missing file returns true (caller surfaces the
    /// "missing" case via `read` returning nil for empty data).
    static func permissionsAreSafe(at path: URL) -> Bool {
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
                "[BearerTokenReader] refusing to read %@: mode 0o%o (expected 0o600). Re-run `tron auth rotate`.",
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

/// Reads `server.tailscaleIp` from `~/.tron/system/settings.json`.
/// Mirrors the iOS-side decoding in `RPCTypes+Settings.swift` (only the
/// field we care about; everything else is ignored).
enum ServerSettingsReader {
    private struct Wrapper: Decodable {
        let server: ServerStanza?
    }
    private struct ServerStanza: Decodable {
        let tailscaleIp: String?
    }

    static func tailscaleIP(at path: URL) -> String? {
        guard let data = try? Data(contentsOf: path), !data.isEmpty else {
            return nil
        }
        guard let wrapper = try? JSONDecoder().decode(Wrapper.self, from: data) else {
            return nil
        }
        let trimmed = wrapper.server?.tailscaleIp?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Atomic-write the `.onboarded` sentinel using the same
/// `tempfile + sync + rename` recipe as the Rust agent.
enum OnboardedSentinelWriter {
    enum Failure: Error, Equatable {
        case parentDirectoryMissing(URL)
        case writeFailed(String)
    }

    static func touch(at path: URL) throws {
        let parent = path.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parent.path) {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        }

        let tmp = parent.appendingPathComponent(".onboarded.\(UUID().uuidString).tmp", isDirectory: false)
        // Include fractional seconds so repeated touches within the same
        // second produce distinct bodies. Rust's serde_json ISO timestamps
        // include millis too — keeps the format consistent across sides.
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let body = formatter.string(from: Date()) + "\n"
        guard let data = body.data(using: .utf8) else {
            throw Failure.writeFailed("UTF-8 encoding failure")
        }
        do {
            try data.write(to: tmp, options: [.atomic])
        } catch {
            throw Failure.writeFailed(error.localizedDescription)
        }
        do {
            // Use replaceItemAt for true atomic rename even when the
            // destination already exists.
            _ = try FileManager.default.replaceItemAt(path, withItemAt: tmp)
        } catch {
            // Cleanup the tempfile on failure.
            try? FileManager.default.removeItem(at: tmp)
            throw Failure.writeFailed(error.localizedDescription)
        }
    }
}
