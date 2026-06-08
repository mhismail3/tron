import SwiftUI

enum CapabilityPresentation {
    static func primitiveName(for identity: CapabilityIdentity) -> String {
        identity.modelPrimitiveName?.nilIfEmpty?.lowercased() ?? "execute"
    }

    static func title(for identity: CapabilityIdentity, targetId: String? = nil) -> String {
        if let displayName = presentationString("displayName", for: identity)
            ?? presentationString("title", for: identity) {
            return displayName
        }
        if let operation = identity.operationName?.nilIfEmpty {
            return humanizeCapabilityId(operation)
        }
        if let targetId = targetId?.nilIfEmpty {
            return humanizeCapabilityId(targetId)
        }
        if let primitive = identity.modelPrimitiveName?.nilIfEmpty, primitive != "execute" {
            return humanizeCapabilityId(primitive)
        }
        return "Action"
    }

    static func symbol(for identity: CapabilityIdentity, targetId _: String? = nil) -> String {
        if let icon = presentationString("sfSymbol", for: identity)
            ?? presentationString("symbol", for: identity)
            ?? presentationString("icon", for: identity),
            let symbol = nativeSymbolName(for: icon) {
            return symbol
        }
        return "play.circle"
    }

    static func primitiveColor(for identity: CapabilityIdentity, targetId _: String? = nil) -> Color {
        if let color = colorFromTheme(themeColorHex(for: identity)) {
            return color
        }
        return .tronEmerald
    }

    static func statusColor(
        for status: CapabilityInvocationStatus,
        identity: CapabilityIdentity,
        targetId: String? = nil
    ) -> Color {
        switch status {
        case .paused:
            return .tronAmber
        case .error, .unavailable:
            return .tronError
        case .generating, .running, .success:
            return primitiveColor(for: identity, targetId: targetId)
        }
    }

    static func sourceColor(for identity: CapabilityIdentity) -> Color {
        primitiveColor(for: identity)
    }

    static func themeColorHex(for identity: CapabilityIdentity, targetId _: String? = nil) -> String? {
        identity.themeColor?.nilIfEmpty ?? presentationString("themeColor", for: identity)
    }

    static func presentationString(_ key: String, for identity: CapabilityIdentity) -> String? {
        identity.presentationHints?[key]?.stringValue?.nilIfEmpty
    }

    static func humanizeCapabilityId(_ id: String) -> String {
        id
            .replacingOccurrences(of: "::", with: " ")
            .replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { word in
                guard let first = word.first else { return "" }
                return first.uppercased() + word.dropFirst()
            }
            .joined(separator: " ")
    }

    private static func colorFromTheme(_ themeColor: String?) -> Color? {
        guard let themeColor = themeColor?.nilIfEmpty else { return nil }
        let hex = themeColor.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        let hexDigits = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
        guard [3, 6, 8].contains(hex.count),
              hex.unicodeScalars.allSatisfy({ hexDigits.contains($0) })
        else {
            return nil
        }
        return Color(hex: themeColor)
    }

    private static func nativeSymbolName(for token: String) -> String? {
        let normalized = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        if normalized.contains(".") || normalized == "terminal" || normalized == "globe" {
            return normalized
        }
        switch normalized {
        case "question":
            return "questionmark.circle"
        case "clock", "wait":
            return "clock"
        case "output":
            return "text.alignleft"
        case "execute", "run":
            return "play.circle"
        case "file", "document":
            return "doc.text"
        case "terminal", "process":
            return "terminal"
        default:
            return normalized.contains(" ") ? nil : normalized
        }
    }
}
