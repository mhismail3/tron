import Foundation

/// Reads the gateway's short-lived, one-time enrollment code. The permanent
/// local health token in `local-auth.json` never enters a QR code or presentation state.
enum GatewayEnrollmentCodeReader {
    private struct Document: Decodable {
        let version: Int
        let code: String
        let expiresAt: String
        let machineId: String
    }

    static func read(at url: URL, now: Date = Date()) -> String? {
        guard url.isFileURL,
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let permissions = attributes[.posixPermissions] as? NSNumber,
              permissions.intValue & 0o077 == 0,
              let data = try? Data(contentsOf: url),
              let document = try? JSONDecoder().decode(Document.self, from: data),
              document.version == 1,
              !document.machineId.isEmpty,
              let expires = ISO8601DateFormatter().date(from: document.expiresAt),
              expires > now else { return nil }
        let code = document.code.trimmingCharacters(in: .whitespacesAndNewlines)
        return (8...32).contains(code.count) ? code : nil
    }
}
