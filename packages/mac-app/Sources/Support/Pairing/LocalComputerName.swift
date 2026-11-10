import Foundation
import SystemConfiguration

enum LocalComputerName {
    static let defaultName = "My Mac"

    static func current() -> String {
        preferredName(
            computerName: systemComputerName(),
            localizedHostName: Host.current().localizedName,
            hostName: Host.current().name
        )
    }

    static func pairingName(_ name: String, isDev: Bool) -> String {
        isDev ? "\(name) (Dev)" : name
    }

    static func preferredName(
        computerName: String?,
        localizedHostName: String?,
        hostName: String?,
        defaultName: String = defaultName
    ) -> String {
        for candidate in [computerName, localizedHostName, hostName] {
            if let normalized = normalize(candidate) {
                return normalized
            }
        }
        return normalize(defaultName) ?? Self.defaultName
    }

    private static func systemComputerName() -> String? {
        guard let name = SCDynamicStoreCopyComputerName(nil, nil) else {
            return nil
        }
        return name as String
    }

    private static func normalize(_ value: String?) -> String? {
        let trimmed = value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}
