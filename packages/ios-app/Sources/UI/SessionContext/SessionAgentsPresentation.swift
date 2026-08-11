import SwiftUI

/// Pure presentation policy for the session-scoped agent manager. Lifecycle
/// values stay forward-compatible: unknown values remain visible with neutral
/// styling instead of disappearing from the operator's audit surface.
enum SessionAgentsPresentation {
    static func isActive(status: String) -> Bool {
        switch status {
        case "provisioning", "offered", "accepted", "queued", "active", "running", "waiting":
            true
        default:
            false
        }
    }

    static func isChild(relationship: String) -> Bool {
        switch relationship {
        case "child", "descendant", "owned", "managed_descendant": true
        default: false
        }
    }

    static func statusColor(_ status: String) -> Color {
        switch status {
        case "active", "running": .tronEmerald
        case "provisioning", "accepted", "queued", "offered": .tronAmber
        case "waiting", "idle": .tronCyan
        case "failed", "timed_out", "autonomy_paused": .tronError
        case "cancelled", "declined", "expired", "closed": .tronTextMuted
        default: .tronPurple
        }
    }

    static func statusSymbol(_ status: String) -> String {
        switch status {
        case "active", "running": "sparkles"
        case "provisioning": "circle.dotted"
        case "offered": "tray.and.arrow.down"
        case "accepted", "queued": "clock"
        case "waiting": "hourglass"
        case "idle": "pause.circle"
        case "completed": "checkmark.circle.fill"
        case "failed", "timed_out", "autonomy_paused": "exclamationmark.triangle.fill"
        case "cancelled", "declined", "expired": "xmark.circle"
        case "closed": "archivebox"
        default: "circle.fill"
        }
    }

    static func displayLabel(_ raw: String) -> String {
        WorkerConsolePresentation.displayLabel(raw)
    }

    static func relationLabel(_ relation: AgentRelationDTO) -> String {
        let base = displayLabel(relation.relationship)
        return relation.depth > 1 ? "\(base) · depth \(relation.depth)" : base
    }

    static func orderedChildren(_ agents: [AgentRelationDTO]) -> [AgentRelationDTO] {
        let children = agents.filter { isChild(relationship: $0.relationship) }
        let identifiers = Set(children.map(\.agentId))
        let byParent = Dictionary(grouping: children.compactMap { agent in
            agent.parentAgentId.map { ($0, agent) }
        }, by: \.0)
        let roots = children.filter {
            $0.parentAgentId == nil || !identifiers.contains($0.parentAgentId ?? "")
        }.sorted(by: order)
        var ordered: [AgentRelationDTO] = []
        var visited: Set<String> = []

        func append(_ agent: AgentRelationDTO) {
            guard visited.insert(agent.agentId).inserted else { return }
            ordered.append(agent)
            for child in (byParent[agent.agentId] ?? []).map(\.1).sorted(by: order) {
                append(child)
            }
        }
        roots.forEach(append)
        children.sorted(by: order).forEach(append)
        return ordered
    }

    static func orderedContacts(_ agents: [AgentRelationDTO]) -> [AgentRelationDTO] {
        agents.filter { !isChild(relationship: $0.relationship) }.sorted(by: order)
    }

    static func order(_ lhs: AgentRelationDTO, _ rhs: AgentRelationDTO) -> Bool {
        let lhsActive = isActive(status: lhs.status)
        let rhsActive = isActive(status: rhs.status)
        if lhsActive != rhsActive { return lhsActive }
        if lhs.depth != rhs.depth { return lhs.depth < rhs.depth }
        if lhs.lastActivityAt != rhs.lastActivityAt {
            return lhs.lastActivityAt > rhs.lastActivityAt
        }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }

    static func usageSummary(_ usage: AgentUsageDTO?) -> String? {
        guard let usage else { return nil }
        let total = usage.inputTokens + usage.outputTokens
        var parts: [String] = []
        if total > 0 {
            parts.append("\(TokenFormatter.format(Int(clamping: total), style: .withSuffix)) tokens")
        }
        if usage.cost > 0 {
            parts.append(formatCost(usage.cost))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func action(
        _ name: String,
        in actions: [AgentAllowedActionDTO]
    ) -> AgentAllowedActionDTO? {
        actions.first { $0.action == name }
    }

    static func actionIsEnabled(
        _ name: String,
        in actions: [AgentAllowedActionDTO],
        isConnected: Bool
    ) -> Bool {
        isConnected && action(name, in: actions)?.enabled == true
    }

    static func actionReason(
        _ name: String,
        in actions: [AgentAllowedActionDTO],
        isConnected: Bool
    ) -> String? {
        if !isConnected { return "Available after reconnection" }
        return action(name, in: actions)?.disabledReason
    }
}
