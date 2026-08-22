import Foundation

/// Reads the gateway's short-lived, one-time enrollment code. The permanent
/// local health token never enters a QR code or presentation state.
enum EnrollmentCodeReader {
    private static let maximumBytes = 64 * 1024
    private struct Document: Decodable {
        let version: Int
        let code: String
        let expiresAt: String
        let machineId: String
    }
    private static let expectedKeys: Set<String> = ["version", "code", "expiresAt", "machineId"]

    static func read(at url: URL, now: Date = Date()) -> String? {
        guard let data = OwnerOnlyJSONReader.readData(at: url, maximumBytes: maximumBytes),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any],
              Set(dictionary.keys) == expectedKeys,
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
        if let date = fractional.date(from: value) { return date }
        return ISO8601DateFormatter().date(from: value)
    }
}
