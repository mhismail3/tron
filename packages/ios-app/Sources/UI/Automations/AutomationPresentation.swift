import SwiftUI

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

/// Shared hierarchy for the inventory card and its expanded detail summary.
/// The caller owns navigation and supplies the appropriate glass surface.
struct AutomationSummaryCard: View {
    let presentation: AutomationSummaryPresentation
    var expanded = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if expanded { expandedContent }
            else { compactContent }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var compactContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            let headerLayout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
                : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 10))
            headerLayout {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: presentation.icon)
                        .font(TronTypography.sans(size: 18, weight: .medium))
                        .foregroundStyle(Color.tronAutomation)
                        .frame(width: 20)
                        .accessibilityHidden(true)
                    Text(presentation.name)
                        .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .bold))
                        .foregroundStyle(Color.tronTextPrimary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 0) }
                status
                    .multilineTextAlignment(dynamicTypeSize.isAccessibilitySize ? .leading : .trailing)
                    .fixedSize(horizontal: !dynamicTypeSize.isAccessibilitySize, vertical: true)
            }
            compactRow {
                cadence
            } trailing: {
                server
            }
            compactRow {
                inlineMetric("Last run", value: presentation.lastRunAt.map(timestamp) ?? "No runs yet")
            } trailing: {
                inlineMetric("Updated", value: timestamp(presentation.updatedAt))
            }
            attentionReason
        }
    }

    /// Compact rows use both edges when they fit, but never truncate a server
    /// name or squeeze metadata into narrow columns at larger text sizes.
    private func compactRow<Leading: View, Trailing: View>(
        @ViewBuilder leading: () -> Leading, @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        let stacked = VStack(alignment: .leading, spacing: 4) {
            leading()
            trailing()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        return Group {
            if dynamicTypeSize.isAccessibilitySize { stacked }
            else {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        leading().fixedSize()
                        Spacer(minLength: 0)
                        trailing().fixedSize()
                    }
                    stacked
                }
            }
        }
    }

    private func inlineMetric(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title)
                .font(TronTypography.secondaryDescription)
                .foregroundStyle(Color.tronTextMuted)
                .fixedSize()
            Text(value)
                .font(TronTypography.secondaryCodeDescription)
                .foregroundStyle(Color.tronTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(value)")
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
        .font(expanded ? TronTypography.secondaryDescription : TronTypography.secondaryDescription)
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

    private var statusColor: Color {
        presentation.needsAttention ? .tronError
            : AutomationStatusPresentation.color(presentation.activation, run: presentation.currentState)
    }

    private var status: some View {
        Text(presentation.status)
            .font(TronTypography.secondaryDescription)
            .foregroundStyle(statusColor)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var cadence: some View {
        Text(presentation.cadence)
            .font(TronTypography.secondaryDescription)
            .foregroundStyle(Color.tronTextSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func timestamp(_ value: String) -> String {
        expanded ? AutomationDateFormatting.date(value) : AutomationDateFormatting.relative(value)
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
