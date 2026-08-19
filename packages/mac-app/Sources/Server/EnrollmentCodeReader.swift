import Foundation

/// Reads the gateway's short-lived, one-time enrollment code. The permanent
/// local health token in `auth.json` never enters a QR code or presentation state.
enum EnrollmentCodeReader {
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
              let expires = expirationDate(from: document.expiresAt),
              expires > now else { return nil }
        let code = document.code.trimmingCharacters(in: .whitespacesAndNewlines)
        return (8...32).contains(code.count) ? code : nil
    }

    private static func expirationDate(from value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) {
            return date
        }
        return ISO8601DateFormatter().date(from: value)
    }
}
