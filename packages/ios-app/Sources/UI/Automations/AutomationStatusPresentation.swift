import SwiftUI

enum AutomationStatusPresentation {
    static func color(_ activation: AutomationActivation, run: AutomationRunState? = nil) -> Color {
        if run == .outcomeUnknown || activation == .blocked { return .tronError }
        if run == .running || run == .admitting || run == .queued { return .tronCoral }
        switch activation {
        case .enabled: return .tronCoral
        case .paused, .draft, .completed: return .tronTextMuted
        case .blocked: return .tronError
        }
    }
    static func icon(_ activation: AutomationActivation, run: AutomationRunState? = nil) -> String {
        if run == .outcomeUnknown || activation == .blocked { return "exclamationmark.triangle.fill" }
        if run == .running { return "play.circle.fill" }
        switch activation { case .enabled: return "checkmark.circle.fill"; case .paused: return "pause.circle.fill"; case .draft: return "pencil.circle"; case .completed: return "checkmark.seal"; case .blocked: return "exclamationmark.triangle.fill" }
    }
    static func accessible(_ summary: GatewayAutomationSummary) -> String {
        var result = "\(summary.name), \(summary.activation.label), \(summary.typedActionKind?.label ?? summary.actionKind), \(summary.trigger.summary)"
        if let next = summary.nextOccurrenceAt { result += ", next \(next)" }
        if summary.consecutiveFailureCount > 0 { result += ", \(summary.consecutiveFailureCount) consecutive failures" }
        if let blocked = summary.blockedReason { result += ", blocked: \(blocked)" }
        return result
    }
}

struct AutomationStatusBadge: View {
    let activation: AutomationActivation
    var run: AutomationRunState? = nil
    var body: some View {
        Label(run?.label ?? activation.label, systemImage: AutomationStatusPresentation.icon(activation, run: run))
            .font(TronTypography.secondaryCodeDescription)
            .foregroundStyle(AutomationStatusPresentation.color(activation, run: run))
            .lineLimit(1)
    }
}

struct AutomationDateFormatting {
    static func date(_ value: String?, style: DateFormatter.Style = .medium) -> String {
        guard let value, let date = GatewayTimestamp.parse(value) else { return value ?? "—" }
        let formatter = DateFormatter()
        formatter.dateStyle = style
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
    static func relative(_ value: String?) -> String {
        guard let value, let date = GatewayTimestamp.parse(value) else { return value ?? "—" }
        return GatewayTimestamp.relativeDescription(GatewayTimestamp.string(from: date), relativeTo: .now)
    }
}
