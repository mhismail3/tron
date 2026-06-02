import Foundation
import SystemConfiguration

/// Resolves the user-facing Mac name that should appear in pairing.
///
/// macOS exposes a few related names: the Sharing "Computer Name",
/// localized host name, and lower-level host name. Pairing wants the
/// friendly Sharing name first because that is what users recognize.
enum LocalComputerName {
    static let defaultName = "My Mac"

    static func current() -> String {
        preferredName(
            computerName: systemComputerName(),
            localizedHostName: Host.current().localizedName,
            hostName: Host.current().name
        )
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
