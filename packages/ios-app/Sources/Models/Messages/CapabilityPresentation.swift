import SwiftUI

enum CapabilityPresentation {
    static func primitiveName(for identity: CapabilityIdentity) -> String {
        if let modelPrimitiveName = identity.modelPrimitiveName?.lowercased(),
           ["search", "inspect", "execute"].contains(modelPrimitiveName) {
            return modelPrimitiveName
        }
        let id = identity.contractId ?? identity.functionId ?? ""
        if id == "capability::search" { return "search" }
        if id == "capability::inspect" { return "inspect" }
        return "execute"
    }

    static func title(for identity: CapabilityIdentity, targetId: String? = nil) -> String {
        if let displayName = presentationString("displayName", for: identity)
            ?? presentationString("title", for: identity) {
            return displayName
        }
        if let targetId, targetId != "capability::execute" {
            return humanizeCapabilityId(targetId)
        }
        if let contractId = identity.contractId, identity.modelPrimitiveName != contractId {
            return humanizeCapabilityId(contractId)
        }
        if let functionId = identity.functionId {
            return humanizeCapabilityId(functionId)
        }
        if let modelPrimitiveName = identity.modelPrimitiveName {
            switch modelPrimitiveName {
            case "search": return "Search capabilities"
            case "inspect": return "Inspect capability"
            case "execute": return "Action"
            default: return humanizeCapabilityId(modelPrimitiveName)
            }
        }
        return "Capability"
    }

    static func symbol(for identity: CapabilityIdentity, targetId: String? = nil) -> String {
        if let icon = presentationString("sfSymbol", for: identity)
            ?? presentationString("symbol", for: identity)
            ?? presentationString("icon", for: identity),
           let symbol = nativeSymbolName(for: icon) {
            return symbol
        }
        let id = targetId?.nilIfEmpty ?? identity.contractId ?? identity.functionId ?? identity.modelPrimitiveName ?? ""
        if id.hasPrefix("capability::search") || identity.modelPrimitiveName == "search" { return "magnifyingglass" }
        if id.hasPrefix("capability::inspect") || identity.modelPrimitiveName == "inspect" { return "info.circle" }
        if id.hasPrefix("capability::execute") || identity.modelPrimitiveName == "execute" { return "play.circle" }
        return "puzzlepiece.extension"
    }

    static func primitiveColor(for identity: CapabilityIdentity, targetId: String? = nil) -> Color {
        if let color = colorFromTheme(themeColorHex(for: identity, targetId: targetId)) {
            return color
        }
        switch primitiveName(for: identity) {
        case "search":
            return .tronBlue
        case "inspect":
            return .tronPurple
        default:
            return .tronEmerald
        }
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

    static func sourceLabel(for identity: CapabilityIdentity) -> String {
        identity.pluginId?.nilIfEmpty.map(pluginDisplayName) ?? "Runtime"
    }

    static func pluginLabel(for identity: CapabilityIdentity) -> String? {
        guard let pluginId = identity.pluginId?.nilIfEmpty else { return nil }
        return pluginDisplayName(pluginId)
    }

    static func workerLabel(for identity: CapabilityIdentity, targetId: String? = nil) -> String? {
        if let workerName = presentationString("workerName", for: identity)
            ?? presentationString("workerLabel", for: identity)
            ?? presentationString("worker", for: identity) {
            return workerName
        }
        if let workerId = identity.workerId?.nilIfEmpty {
            return humanizeWorkerId(workerId)
        }
        if let namespace = targetId?.split(separator: "::").first.map(String.init)
            ?? identity.functionId?.split(separator: "::").first.map(String.init)
            ?? identity.contractId?.split(separator: "::").first.map(String.init) {
            return humanizeWorkerId(namespace)
        }
        if let pluginId = identity.pluginId?.nilIfEmpty {
            return pluginDisplayName(pluginId)
        }
        return nil
    }

    static func color(for identity: CapabilityIdentity) -> Color {
        switch identity.riskLevel?.lowercased() {
        case "critical", "high":
            return .tronError
        case "medium":
            return .tronAmber
        default:
            return .tronBlue
        }
    }

    static func themeColorHex(for identity: CapabilityIdentity, targetId: String? = nil) -> String? {
        identity.themeColor?.nilIfEmpty
            ?? presentationString("themeColor", for: identity)
            ?? targetId.flatMap(themeColorForCapabilityId)
            ?? themeColorForCapabilityNamespace(identity)
    }

    static func presentationString(_ key: String, for identity: CapabilityIdentity) -> String? {
        identity.presentationHints?[key]?.stringValue?.nilIfEmpty
    }

    static func humanizeCapabilityId(_ id: String) -> String {
        if let known = friendlyCapabilityNames[id] {
            return known
        }
        let tail = id.split(separator: "::").last.map(String.init) ?? id
        return tail
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { word in
                guard let first = word.first else { return "" }
                return first.uppercased() + word.dropFirst()
            }
            .joined(separator: " ")
    }

    private static let friendlyCapabilityNames: [String: String] = [
        "capability::execute": "Action",
        "capability::inspect": "Inspect capability",
        "capability::search": "Search capabilities"
    ]

    private static func pluginDisplayName(_ pluginId: String) -> String {
        pluginId
            .split(separator: ".")
            .last
            .map(String.init)
            .map(humanizeCapabilityId) ?? humanizeCapabilityId(pluginId)
    }

    private static func humanizeWorkerId(_ workerId: String) -> String {
        let tail = workerId.split(separator: ":").last.map(String.init) ?? workerId
        return tail
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: ".", with: " ")
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
        case "search":
            return "magnifyingglass"
        case "inspect":
            return "info.circle"
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

    private static func themeColorForCapabilityNamespace(_ identity: CapabilityIdentity) -> String? {
        if let color = identity.contractId.flatMap(themeColorForCapabilityId) {
            return color
        }
        if let color = identity.functionId.flatMap(themeColorForCapabilityId) {
            return color
        }
        if let implementationId = identity.implementationId?.nilIfEmpty {
            if let namespace = implementationId.split(separator: ".").first,
               let color = themeColorForNamespace(String(namespace)) {
                return color
            }
        }
        if let pluginId = identity.pluginId?.nilIfEmpty {
            if let namespace = pluginId.split(separator: ".").first,
               let color = themeColorForNamespace(String(namespace)) {
                return color
            }
        }
        return identity.modelPrimitiveName.flatMap(themeColorForCapabilityId)
    }

    private static func themeColorForCapabilityId(_ id: String) -> String? {
        guard let id = id.nilIfEmpty else { return nil }
        if let namespace = id.split(separator: "::").first {
            return themeColorForNamespace(String(namespace))
        }
        if let namespace = id.split(separator: ".").first {
            return themeColorForNamespace(String(namespace))
        }
        return themeColorForNamespace(id)
    }

    private static func themeColorForNamespace(_ namespace: String) -> String? {
        switch String(namespace) {
        case "capability":
            return "#10B981"
        case "mcp":
            return "#2DD4BF"
        default:
            return nil
        }
    }

}
