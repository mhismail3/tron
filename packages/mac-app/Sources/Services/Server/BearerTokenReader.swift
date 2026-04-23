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
/// Tests in `Tests/Services/BearerTokenReaderTests.swift` cover happy
/// path, missing file, malformed JSON, and the legacy plain-string
/// fallback (some early dogfood writes were not wrapped in the object).
enum BearerTokenReader {
    private struct TokenFile: Decodable {
        let token: String
    }

    static func read(at path: URL) -> String? {
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
