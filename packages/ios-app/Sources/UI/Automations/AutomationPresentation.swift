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

    var needsAttention: Bool {
        activation == .blocked || currentState == .outcomeUnknown || failureCount > 0
    }

    /// The one status word: a state worth reading first (blocked, unresolved,
    /// in flight), otherwise the lifecycle.
    var status: String {
        if activation == .blocked { return activation.label }
        if let currentState, currentState == .outcomeUnknown || currentState.isInFlight { return currentState.label }
        return activation.label
    }

    @MainActor var statusColor: Color {
        needsAttention ? .tronError : AutomationStatusPresentation.color(activation, run: currentState)
    }

    var accessibilityLabel: String {
        let state = currentState.map { "\(activation.label) · \($0.label)" } ?? activation.label
        var text = "\(name), \(actionKind?.label ?? "Action"), \(state), \(cadence), Server, \(server), Last run, \(lastRunAt.map { AutomationDateFormatting.date($0) } ?? "No runs yet"), Updated, \(AutomationDateFormatting.date(updatedAt))"
        if failureCount > 0 { text += ", \(failureCount) consecutive failures" }
        if let blockedReason { text += ", \(blockedReason)" }
        return text
    }

    /// The inventory row in the shared list anatomy: kind icon, name with its
    /// status pill, cadence, the Gateway tag and when it last ran.
    @MainActor func listContent(now: Date) -> TronListRowContent {
        TronListRowContent(
            leading: .icon(icon, needsAttention ? .tronError : .tronPrimary),
            title: name,
            status: TronListStatus(text: status, tone: statusColor, live: currentState?.isInFlight == true),
            subtext: cadence,
            tags: [TronListTag(text: server)],
            timestamp: TronListTime.short(iso: lastRunAt, now: now) ?? "No runs yet"
        )
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

extension AutomationRunState {
    var isInFlight: Bool { [.queued, .waiting, .admitting, .running, .cancelling].contains(self) }
}

/// One inventory row, projected once per catalog or filter change: every
/// string a row draws or speaks is computed here, never while it scrolls.
struct AutomationInventoryRow: Identifiable, Equatable {
    let selection: AutomationSummarySelection
    let content: TronListRowContent
    let accessibilityLabel: String
    var id: String { selection.id }
}

enum AutomationInventory {
    /// Active Automations first, then paused, then drafts, then finished ones.
    static func lifecycleRank(_ activation: AutomationActivation) -> Int {
        switch activation {
        case .enabled, .blocked: 0
        case .paused: 1
        case .draft: 2
        case .completed, .expired: 3
        }
    }

    /// Within a lifecycle group: needing attention, then running, then the
    /// soonest next occurrence, then name and identity for a stable order.
    static func precedes(_ left: GatewayAutomationSummary, _ right: GatewayAutomationSummary) -> Bool {
        func key(_ summary: GatewayAutomationSummary) -> (Int, Int, Int, String, String, String) {
            (lifecycleRank(summary.activation), summary.isAttentionRequired ? 0 : 1,
             summary.currentRun?.state == .running ? 0 : 1, summary.nextOccurrenceAt ?? "9999",
             summary.name, summary.id)
        }
        return key(left) < key(right)
    }

    @MainActor static func rows(
        buckets: [AutomationProfileCatalog],
        eligibleProfileIDs: Set<String>,
        profileID: String?,
        filter: AutomationInventoryFilter,
        action: AutomationActionKind?,
        now: Date = .now
    ) -> [AutomationInventoryRow] {
        buckets.filter { eligibleProfileIDs.contains($0.id) && (profileID == nil || profileID == $0.id) }
            .flatMap { bucket in
                bucket.summaries
                    .filter { filter.matches($0) && (action == nil || $0.typedActionKind == action) }
                    .map { (bucket.profile, $0) }
            }
            .sorted { precedes($0.1, $1.1) }
            .map { profile, summary in
                let presentation = AutomationSummaryPresentation(summary: summary, server: profile.label)
                return AutomationInventoryRow(
                    selection: AutomationSummarySelection(profileID: profile.id, summary: summary),
                    content: presentation.listContent(now: now),
                    accessibilityLabel: presentation.accessibilityLabel
                )
            }
    }
}

/// The header of an Automation or run detail: its name, one status pill and a
/// line of context, as Home's task detail opens.
struct AutomationHeaderCard: View {
    let title: String
    let status: String
    let statusColor: Color
    let detail: String?
    var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(title)
                    .font(SessionSummaryTypography.headline)
                    .foregroundStyle(Color.tronTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                TronStatusPill(text: status, accent: statusColor)
            }
            if let detail {
                Text(detail)
                    .font(SessionSummaryTypography.detail)
                    .foregroundStyle(Color.tronTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let note {
                Text(note)
                    .font(SessionSummaryTypography.detail)
                    .foregroundStyle(Color.tronError)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .tronGlassSurface(accent: .tronPrimary, tintOpacity: 0.14)
        .accessibilityElement(children: .contain)
    }
}

/// One fact of a detail sheet, read title over value.
struct AutomationFact: Identifiable {
    let icon: String
    let title: String
    let value: String
    /// IDs and paths read in mono; everything else in the row's body type.
    var isIdentifier = false
    var id: String { title }
}

struct AutomationFactSection: Identifiable {
    let title: String
    let facts: [AutomationFact]
    var id: String { title }
}

/// A titled settings group of title-over-value rows, the reading layout of
/// every Home and Settings detail.
struct AutomationFactsGroup<Footer: View>: View {
    let section: AutomationFactSection
    @ViewBuilder var footer: () -> Footer

    init(_ section: AutomationFactSection, @ViewBuilder footer: @escaping () -> Footer) {
        self.section = section
        self.footer = footer
    }

    var body: some View {
        TronSettingsGroup(section.title) {
            VStack(spacing: 0) {
                ForEach(Array(section.facts.enumerated()), id: \.element.id) { index, fact in
                    if index > 0 { TronSettingsDivider() }
                    TronSettingsRow(
                        icon: fact.icon, title: fact.title, subtitle: fact.value, subtitleLineLimit: nil,
                        subtitleFont: fact.isIdentifier ? TronTypography.code(size: TronTypography.sizeBodySM) : TronTypography.subheadline
                    )
                    .textSelection(.enabled)
                }
                footer()
            }
        }
    }
}

extension AutomationFactsGroup where Footer == EmptyView {
    init(_ section: AutomationFactSection) { self.init(section) { EmptyView() } }
}

/// One action of a detail's Controls group: a standard row that performs it,
/// red when destructive, as Manage Home's controls read.
struct AutomationActionRow: View {
    let icon: String
    let title: String
    var subtitle: String?
    var destructive = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            TronSettingsRow(icon: icon, title: title, subtitle: subtitle,
                            accent: destructive ? .tronError : .tronPrimary,
                            titleColor: destructive ? .tronError : .tronTextPrimary,
                            subtitleColor: destructive ? .tronError : .tronTextPrimary)
                .tronSettingsVisualTheme(accent: destructive ? .tronError : .tronPrimary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

extension AutomationFactSection {
    /// Facts the header does not carry, grouped as the editor's sections are.
    static func detail(record: GatewayAutomationRecord, server: String, targetLabel: String) -> [Self] {
        var basics: [AutomationFact] = []
        if let description = record.description, !description.isEmpty {
            basics.append(AutomationFact(icon: "text.alignleft", title: "Description", value: description))
        }
        basics.append(AutomationFact(icon: "desktopcomputer", title: "Gateway", value: server))

        let kind = record.action.typedKind ?? .sessionPrompt
        var action = [AutomationFact(icon: kind.icon, title: kind == .notification ? "Message" : "Prompt",
                                     value: record.action.content.isEmpty ? "No action content returned." : record.action.content)]
        if let invocation = record.action.resourceInvocation {
            action.append(AutomationFact(icon: "sparkles",
                                         title: invocation.source == .prompt ? "Prompt template" : invocation.source.rawValue.capitalized,
                                         value: invocation.name))
        }

        var target = [AutomationFact(icon: "arrow.turn.down.right", title: "Destination", value: targetLabel)]
        if case let .workspace(cwd, _) = record.target {
            target.append(AutomationFact(icon: "folder", title: "Workspace", value: cwd, isIdentifier: true))
        }

        var schedule = [
            AutomationFact(icon: "repeat", title: "Repeats", value: record.trigger.summary),
            AutomationFact(icon: "globe", title: "Timezone", value: record.trigger.timezone ?? TimeZone.current.identifier),
        ]
        if let next = record.nextOccurrenceAt {
            schedule.append(AutomationFact(icon: "calendar.badge.clock", title: "Next", value: AutomationDateFormatting.date(next)))
        }
        if let run = record.currentRun {
            schedule.append(AutomationFact(icon: "play.circle", title: "Current run", value: AutomationDateFormatting.date(run.scheduledFor)))
        }
        let lastRun = record.currentRun?.startedAt ?? record.lastRun?.startedAt ?? record.lastRun?.terminalAt ?? record.lastRun?.scheduledFor
        schedule.append(AutomationFact(icon: "clock.arrow.circlepath", title: "Last run",
                                       value: lastRun.map { AutomationDateFormatting.date($0) } ?? "No runs yet"))

        let behavior = [
            AutomationFact(icon: "clock.arrow.circlepath", title: "After downtime",
                           value: record.misfirePolicy == "latest" ? "Run latest missed occurrence" : "Skip missed occurrences"),
            AutomationFact(icon: "rectangle.stack.badge.play", title: "While running",
                           value: record.overlapPolicy == "queueLatest" ? "Queue latest occurrence" : "Skip overlapping occurrences"),
            AutomationFact(icon: "timer", title: "Deadline", value: "\(record.executionDeadlineSeconds / 60) minutes"),
        ]

        let creator = switch record.provenance.kind {
        case "mobile": "iPhone"
        case "local": "Mac"
        case "assistant": "Tron assistant"
        case "home": "Tron Home"
        default: record.provenance.kind
        }
        var about = [
            AutomationFact(icon: "calendar", title: "Created", value: AutomationDateFormatting.date(record.createdAt)),
            AutomationFact(icon: "pencil", title: "Updated", value: AutomationDateFormatting.date(record.updatedAt)),
            AutomationFact(icon: "person", title: "Created by", value: creator),
            AutomationFact(icon: "number", title: "Revision", value: "\(record.revision)"),
        ]
        if let expiresAt = record.provenance.expiresAt {
            about.append(AutomationFact(icon: "hourglass", title: "Expires", value: AutomationDateFormatting.date(expiresAt)))
        }
        return [
            Self(title: "Basics", facts: basics), Self(title: "Action", facts: action),
            Self(title: "Target", facts: target), Self(title: "Schedule", facts: schedule),
            Self(title: "Behavior", facts: behavior), Self(title: "About", facts: about),
        ]
    }
}
