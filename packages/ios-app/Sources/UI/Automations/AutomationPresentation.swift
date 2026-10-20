import SwiftUI
import TronMobileCore

/// A value projection only: inventory uses its catalog summary, while the open
/// detail uses the authoritative record read. Neither surface caches the other.
struct AutomationSummaryPresentation {
    let name: String
    let actionKind: AutomationActionKind?
    var icon: String { actionKind?.icon ?? "clock" }
    let activation: AutomationActivation
    let currentState: AutomationRunState?
    let cadence: String
    let lastRunAt: String?
    let updatedAt: String
    let server: String
    let failureCount: Int
    let blockedReason: String?

    var status: String {
        currentState.map { "\(activation.label) · \($0.label)" } ?? activation.label
    }
    var needsAttention: Bool {
        activation == .blocked || currentState == .outcomeUnknown || failureCount > 0
    }
    var accessibilityLabel: String {
        var text = "\(name), \(actionKind?.label ?? "Action"), \(status), \(cadence), Server, \(server), Last run, \(lastRunAt.map { AutomationDateFormatting.date($0) } ?? "No runs yet"), Updated, \(AutomationDateFormatting.date(updatedAt))"
        if failureCount > 0 { text += ", \(failureCount) consecutive failures" }
        if let blockedReason { text += ", \(blockedReason)" }
        return text
    }
}

extension AutomationSummaryPresentation {
    init(summary: GatewayAutomationSummary, server: String) {
        self.init(
            name: summary.name, actionKind: summary.typedActionKind,
            activation: summary.activation, currentState: summary.currentRun?.state,
            cadence: summary.trigger.summary,
            // A running execution is newer than the previous terminal run.
            // Never substitute a future occurrence for the last execution.
            lastRunAt: summary.currentRun?.startedAt ?? summary.lastRun?.startedAt
                ?? summary.lastRun?.terminalAt ?? summary.lastRun?.scheduledFor,
            updatedAt: summary.updatedAt, server: server,
            failureCount: summary.consecutiveFailureCount, blockedReason: summary.blockedReason
        )
    }

    init(record: GatewayAutomationRecord, server: String) {
        self.init(
            name: record.name, actionKind: record.action.typedKind,
            activation: record.activation, currentState: record.currentRun?.state,
            cadence: record.trigger.summary,
            lastRunAt: record.currentRun?.startedAt ?? record.lastRun?.startedAt
                ?? record.lastRun?.terminalAt ?? record.lastRun?.scheduledFor,
            updatedAt: record.updatedAt, server: server,
            failureCount: record.consecutiveFailureCount, blockedReason: record.blockedReason
        )
    }
}

/// One Automation in the inventory, drawn through the dashboard's shared list
/// row: its action icon in the status colour, the name, schedule · server, and
/// a trailing state or last-run time.
struct AutomationSummaryRow: View {
    let presentation: AutomationSummaryPresentation

    var body: some View {
        DashboardListRow(
            title: presentation.name,
            subtitle: "\(presentation.cadence) · \(presentation.server)",
            accent: presentation.needsAttention ? .tronError : .tronAutomation
        ) {
            Image(systemName: presentation.icon)
                .font(TronTypography.sans(size: TronTypography.sizeBody3, weight: .semibold))
                .foregroundStyle(presentation.statusColor)
        } trailing: {
            SessionRowRelativeTime(text: presentation.trailingStatus, isWaiting: presentation.needsAttention)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.accessibilityLabel)
    }
}

extension AutomationSummaryPresentation {
    var statusColor: Color {
        needsAttention ? .tronError : AutomationStatusPresentation.color(activation, run: currentState)
    }

    /// A state worth reading first (blocked, unresolved, in flight, not
    /// active), otherwise when it last ran.
    var trailingStatus: String {
        if activation == .blocked { return activation.label }
        if let currentState, [.queued, .waiting, .admitting, .running, .cancelling, .outcomeUnknown].contains(currentState) {
            return currentState.label
        }
        if activation != .enabled { return activation.label }
        return lastRunAt.map { AutomationDateFormatting.relative($0) } ?? "No runs yet"
    }
}

/// The expanded summary at the top of an Automation's detail.
/// The caller supplies the appropriate glass surface.
struct AutomationSummaryCard: View {
    let presentation: AutomationSummaryPresentation
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        expandedContent
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: presentation.icon)
                    .font(TronTypography.sans(size: 22, weight: .medium))
                    .foregroundStyle(Color.tronAutomation)
                    .frame(width: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text(presentation.name)
                        .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .bold))
                        .foregroundStyle(Color.tronTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            status.fixedSize()
                            Text("·").foregroundStyle(Color.tronTextMuted)
                            cadence.fixedSize()
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            status
                            cadence
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            Divider().overlay(Color.tronAutomation.opacity(0.18))
                .padding(.vertical, 1)
            server

            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
                : AnyLayout(HStackLayout(alignment: .top, spacing: 16))
            layout {
                metric("Last run", value: presentation.lastRunAt.map(timestamp) ?? "No runs yet")
                metric("Updated", value: timestamp(presentation.updatedAt))
            }
            attentionReason
        }
    }

    private var server: some View {
        Label {
            Text(presentation.server).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "server.rack").accessibilityHidden(true)
        }
        .font(TronTypography.secondaryDescription)
        .foregroundStyle(Color.tronTextSecondary)
        .accessibilityLabel("Server, \(presentation.server)")
    }

    @ViewBuilder private var attentionReason: some View {
        if let reason = presentation.blockedReason {
            Text(reason)
                .font(TronTypography.secondaryDescription)
                .foregroundStyle(Color.tronError)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var status: some View {
        Text(presentation.status)
            .font(TronTypography.secondaryDescription)
            .foregroundStyle(presentation.statusColor)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var cadence: some View {
        Text(presentation.cadence)
            .font(TronTypography.secondaryDescription)
            .foregroundStyle(Color.tronTextSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func timestamp(_ value: String) -> String {
        AutomationDateFormatting.date(value)
    }

    private func metric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(TronTypography.secondaryDescription)
                .foregroundStyle(Color.tronTextMuted)
            Text(value)
                .font(TronTypography.secondaryCodeDescription)
                .foregroundStyle(Color.tronTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// Only facts not already carried by the summary belong in the detail tables.
struct AutomationDetailMetadata: Identifiable {
    let title: String
    let rows: [TronMetadataTableRow]
    var id: String { title }

    static func sections(record: GatewayAutomationRecord, targetLabel: String) -> [Self] {
        func row(_ title: String, _ value: String) -> TronMetadataTableRow {
            TronMetadataTableRow(id: title, title: title, value: value)
        }
        var sections: [Self] = []
        if let description = record.description, !description.isEmpty {
            sections.append(Self(title: "Description", rows: [row("Description", description)]))
        }
        var action = [row(record.action.typedKind == .notification ? "Message" : "Prompt",
                          record.action.content.isEmpty ? "No action content returned." : record.action.content)]
        if let invocation = record.action.resourceInvocation {
            action.append(TronMetadataTableRow(
                id: "resource", title: invocation.source == .prompt ? "Prompt template" : invocation.source.rawValue.capitalized,
                value: invocation.name
            ))
        }
        sections.append(Self(title: "Action", rows: action))
        var schedule = [
            row("Series", record.trigger.kind == "once" ? "One time" : "Repeating"),
            row("Timezone", record.trigger.timezone ?? TimeZone.current.identifier),
            row("After downtime", record.misfirePolicy == "latest" ? "Run latest missed occurrence" : "Skip missed occurrences"),
            row("While running", record.overlapPolicy == "queueLatest" ? "Queue latest occurrence" : "Skip overlapping occurrences"),
            row("Deadline", "\(record.executionDeadlineSeconds / 60) minutes"),
        ]
        if let next = record.nextOccurrenceAt { schedule.append(row("Next", AutomationDateFormatting.date(next))) }
        sections.append(Self(title: "Schedule", rows: schedule))
        var target = [row("Session", targetLabel)]
        if case let .workspace(cwd, _) = record.target { target.append(row("Workspace", cwd)) }
        sections.append(Self(title: "Target", rows: target))
        if let run = record.currentRun {
            sections.append(Self(title: "Current run", rows: [row("Scheduled", AutomationDateFormatting.date(run.scheduledFor))]))
        }
        let creator: String
        switch record.provenance.kind {
        case "mobile": creator = "iPhone"
        case "local": creator = "Mac"
        case "assistant": creator = "Tron assistant"
        default: creator = record.provenance.kind
        }
        sections.append(Self(title: "About", rows: [
            row("Created", AutomationDateFormatting.date(record.createdAt)),
            row("Created by", creator), row("Revision", "\(record.revision)"),
        ]))
        return sections
    }
}
