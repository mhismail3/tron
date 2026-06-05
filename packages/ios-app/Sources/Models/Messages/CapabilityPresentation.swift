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
            case "execute": return "Work"
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
        if id.hasPrefix("filesystem::") { return "doc.text.magnifyingglass" }
        if id.hasPrefix("process::") { return "terminal" }
        if id.hasPrefix("web::") { return "globe" }
        if id.hasPrefix("agent::") { return "person.crop.circle.badge.plus" }
        if id.hasPrefix("sandbox::") { return "shippingbox" }
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
        case .approvalRequired, .paused:
            return .tronAmber
        case .error, .unavailable:
            return .tronError
        case .generating, .running, .success:
            return primitiveColor(for: identity, targetId: targetId)
        }
    }

    static func sourceColor(for identity: CapabilityIdentity) -> Color {
        let trustTier = identity.trustTier?.lowercased() ?? ""
        let pluginId = identity.pluginId?.lowercased() ?? ""

        if trustTier.contains("external_mcp") || pluginId.contains("mcp") {
            return .tronTeal
        }
        if trustTier.contains("external_openapi") || pluginId.contains("openapi") {
            return .tronCyan
        }
        if trustTier.contains("session_generated") || pluginId.contains("sandbox") {
            return .tronPurple
        }
        if trustTier.contains("user_installed") {
            return .tronAmber
        }
        if trustTier.contains("trusted_signed") {
            return .tronIndigo
        }
        if trustTier.contains("first_party") || pluginId.hasPrefix("first_party") {
            return .tronEmerald
        }
        return .tronSlate
    }

    static func sourceLabel(for identity: CapabilityIdentity) -> String {
        let trustTier = identity.trustTier?.lowercased() ?? ""
        let pluginId = identity.pluginId?.lowercased() ?? ""

        if trustTier.contains("external_mcp") || pluginId.contains("mcp") {
            return "MCP"
        }
        if trustTier.contains("external_openapi") || pluginId.contains("openapi") {
            return "OpenAPI"
        }
        if trustTier.contains("session_generated") || pluginId.contains("sandbox") {
            return "Session"
        }
        if trustTier.contains("user_installed") {
            return "Installed"
        }
        if trustTier.contains("trusted_signed") {
            return "Trusted"
        }
        if trustTier.contains("first_party") || pluginId.hasPrefix("first_party") {
            return "First-party"
        }
        return "Capability"
    }

    static func pluginLabel(for identity: CapabilityIdentity) -> String? {
        guard let pluginId = identity.pluginId?.nilIfEmpty else { return nil }
        let source = sourceLabel(for: identity)
        let display = pluginDisplayName(pluginId)
        if source == "Capability" {
            return display
        }
        return "\(display) (\(source))"
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
            ?? identity.contractId?.split(separator: "::").first.map(String.init),
           let friendly = friendlyWorkerNames[namespace] {
            return friendly
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
        "agent::ask_user": "Ask User",
        "agent::cancel_subagent": "Cancel Subagent",
        "agent::spawn_subagent": "Spawn Subagent",
        "agent::submit_answers": "Submit Answers",
        "agent::subagent_result": "Subagent Result",
        "agent::subagent_status": "Subagent Status",
        "capability::execute": "Work",
        "capability::inspect": "Check capability",
        "capability::search": "Find capabilities",
        "catalog::list": "Check capabilities",
        "catalog::watch_snapshot": "Check capabilities",
        "display::show": "Display",
        "filesystem::apply_patch": "Apply Patch",
        "filesystem::diff": "Diff Files",
        "filesystem::edit_file": "Edit File",
        "filesystem::find": "Find Files",
        "filesystem::glob": "Glob Files",
        "filesystem::list_dir": "List Directory",
        "filesystem::read_file": "Read File",
        "filesystem::search_text": "Search Text",
        "filesystem::write_file": "Write File",
        "job::cancel": "Cancel Job",
        "job::list": "List Jobs",
        "job::stream_output": "Stream Job Output",
        "job::wait": "Wait For Job",
        "notifications::send": "Send Notification",
        "process::cancel": "Cancel Process",
        "process::run": "Run Command",
        "process::start_job": "Start Background Job",
        "process::stream_output": "Stream Process Output",
        "process::wait": "Wait For Process",
        "sandbox::promote_worker": "Promote Worker",
        "sandbox::list_spawned_workers": "Check helper capabilities",
        "sandbox::get_spawned_worker": "Check helper capability",
        "self_extension::grant_workspace_autonomy": "Allow local capability work",
        "worker::spawn": "Create helper capability",
        "worker::disconnect": "Stop helper capability",
        "worker::health": "Check helper capability",
        "worker::protocol_guide": "Prepare helper capability",
        "sandbox::stop_spawned_worker": "Stop helper capability",
        "web::fetch": "Fetch Web Page",
        "web::scrape": "Scrape Web Page",
        "web::search": "Search Web"
    ]

    private static func pluginDisplayName(_ pluginId: String) -> String {
        let stripped = pluginId
            .replacingOccurrences(of: "first_party.", with: "")
            .replacingOccurrences(of: "external_mcp.", with: "")
            .replacingOccurrences(of: "external_openapi.", with: "")
            .replacingOccurrences(of: "user_installed.", with: "")
            .replacingOccurrences(of: "session_generated.", with: "")
        if let known = friendlyPluginNames[stripped] {
            return known
        }
        return stripped
            .split(separator: ".")
            .last
            .map(String.init)
            .map(humanizeCapabilityId) ?? humanizeCapabilityId(pluginId)
    }

    private static let friendlyPluginNames: [String: String] = [
        "agent": "Agent",
        "browser": "Browser",
        "capability": "Capabilities",
        "display": "Display",
        "filesystem": "File System",
        "github": "GitHub",
        "job": "Jobs",
        "mcp": "MCP",
        "notifications": "Notifications",
        "process": "Process",
        "sandbox": "Sandbox",
        "web": "Web"
    ]

    private static let friendlyWorkerNames: [String: String] = [
        "agent": "Agent",
        "catalog": "Catalog",
        "display": "Display",
        "filesystem": "File System",
        "job": "Jobs",
        "notifications": "Notifications",
        "process": "Process",
        "sandbox": "Sandbox",
        "self_extension": "Autonomy",
        "web": "Web",
        "worker": "Worker"
    ]

    private static func humanizeWorkerId(_ workerId: String) -> String {
        let tail = workerId.split(separator: ":").last.map(String.init) ?? workerId
        return tail
            .replacingOccurrences(of: "first_party.", with: "")
            .replacingOccurrences(of: "external_mcp.", with: "")
            .replacingOccurrences(of: "external_openapi.", with: "")
            .replacingOccurrences(of: "session_generated.", with: "")
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
        case "subagent":
            return "person.2"
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
            let stripped = stripKnownSourcePrefix(implementationId)
            if let namespace = stripped.split(separator: ".").first,
               let color = themeColorForNamespace(String(namespace)) {
                return color
            }
        }
        if let pluginId = identity.pluginId?.nilIfEmpty {
            let stripped = stripKnownSourcePrefix(pluginId)
            if let namespace = stripped.split(separator: ".").first,
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
        let stripped = stripKnownSourcePrefix(id)
        if let namespace = stripped.split(separator: ".").first {
            return themeColorForNamespace(String(namespace))
        }
        return themeColorForNamespace(id)
    }

    private static func themeColorForNamespace(_ namespace: String) -> String? {
        switch String(namespace) {
        case "capability":
            return "#10B981"
        case "filesystem":
            return "#10B981"
        case "process":
            return "#38BDF8"
        case "web":
            return "#3B82F6"
        case "notifications":
            return "#EC4899"
        case "agent":
            return "#8B5CF6"
        case "job":
            return "#F59E0B"
        case "sandbox":
            return "#A97BFF"
        case "display":
            return "#818CF8"
        case "browser":
            return "#06B6D4"
        case "mcp":
            return "#2DD4BF"
        default:
            return nil
        }
    }

    private static func stripKnownSourcePrefix(_ id: String) -> String {
        id
            .replacingOccurrences(of: "first_party.", with: "")
            .replacingOccurrences(of: "external_mcp.", with: "")
            .replacingOccurrences(of: "external_openapi.", with: "")
            .replacingOccurrences(of: "user_installed.", with: "")
            .replacingOccurrences(of: "session_generated.", with: "")
    }
}
