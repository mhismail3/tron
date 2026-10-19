import SwiftUI
import TronMobileCore

/// One Changes feed row's display facts, derived once when its page installs
/// rather than on every render of the feed. The entry itself stays whole for
/// Details; the row only chooses what the compact card shows.
struct SettingsChangeRow: Identifiable, Equatable, Sendable {
    let entry: SettingsChangeHistoryEntry
    let date: Date?
    /// "before → after", from the Gateway's formatted values.
    let valueChange: String?
    /// The new value alone, for a line too narrow for "before → after".
    let newValue: String?
    /// Who, in a word or a known task title: never a raw task ID.
    let actor: String
    let scope: String
    /// Every fact the card shortens or omits, for VoiceOver.
    let accessibilityLabel: String

    var id: String { entry.changeId }
    var status: String { entry.status.capitalized }
    var failed: Bool { entry.status == "failed" }

    /// Session-catalog titles are a separate, live source: re-derive when they change.
    func retitled(_ workerTitles: [String: String]) -> SettingsChangeRow {
        SettingsChangeRow(entry, workerTitles: workerTitles)
    }

    init(_ entry: SettingsChangeHistoryEntry, workerTitles: [String: String]) {
        self.entry = entry
        date = entry.date
        valueChange = entry.presentation.map { "\($0.display.before) → \($0.display.after)" }
        newValue = entry.presentation.map { "→ \($0.display.after)" }
        let taskTitle = entry.actor.taskId.flatMap { workerTitles[$0] }
        actor = Self.conciseActor(entry, taskTitle: taskTitle)
        scope = entry.presentation?.layer ?? settingsLayerLabel(entry.layer)
        // The Gateway's actor label is the full audit fact (it names the task).
        let fullActor = entry.presentation?.actor ?? entry.actor.kind.capitalized
        accessibilityLabel = [
            entry.title, entry.status.capitalized, valueChange,
            "Changed by \(fullActor)" + (taskTitle.map { ", \($0)" } ?? ""),
            scope, date?.formatted(date: .abbreviated, time: .shortened),
        ].compactMap { $0 }.joined(separator: ", ")
    }

    private static func conciseActor(_ entry: SettingsChangeHistoryEntry, taskTitle: String?) -> String {
        switch entry.actor.kind {
        case "ui": "You"
        case "home": "Home"
        case "worker": taskTitle ?? "Worker"
        case "agent": "Chat agent"
        case "outside": "Outside Tron"
        default: entry.presentation?.actor ?? entry.actor.kind.capitalized
        }
    }

    /// Task titles the session catalog already holds, by Home task ID.
    static func workerTitles(_ sessions: [SessionSummary]) -> [String: String] {
        var titles: [String: String] = [:]
        for session in sessions {
            guard let task = session.homeTaskId, let name = session.name?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty else { continue }
            titles[task] = name
        }
        return titles
    }
}

/// The compact audit card: title and status, then value change · actor · scope
/// with when (and NEW) right-aligned beneath the status.
struct SettingsChangeRowView: View, Equatable {
    /// Between cards: a little tighter than the sheet's section spacing.
    static let spacing: CGFloat = TronSpacing.xl

    let row: SettingsChangeRow
    let isNew: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.row == rhs.row && lhs.isNew == rhs.isNew }

    private var accent: Color { row.failed ? .tronError : .tronEmerald }

    var body: some View {
        TronGlassCard(accent: accent) {
            VStack(alignment: .leading, spacing: TronSpacing.xs) {
                HStack(alignment: .firstTextBaseline) {
                    Text(row.entry.title).font(TronTypography.headline).foregroundStyle(Color.tronTextPrimary)
                        .lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 8)
                    Text(row.status).font(TronTypography.buttonSM).foregroundStyle(accent)
                        .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                }
                // At accessibility sizes the summary takes the full width and
                // when/NEW drop beneath it, still trailing under the status.
                let layout = dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .trailing, spacing: TronSpacing.xxs))
                    : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: TronSpacing.md))
                layout {
                    summary.frame(maxWidth: .infinity, alignment: .leading)
                    when.fixedSize(horizontal: true, vertical: false)
                }
                .font(TronTypography.settingsRowSubtext).foregroundStyle(Color.tronTextSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, TronSettingsLayoutPolicy.rowHorizontalPadding)
            .padding(.vertical, TronSpacing.md)
            .contentShape(Rectangle())
        }
    }

    /// The most informative line that fits whole: the full change, then the new
    /// value alone, else who and where with the actor truncating at its tail (a
    /// value too long for the line is left to Details and VoiceOver rather than
    /// cut to an unreadable stub). Accessibility sizes wrap instead.
    @ViewBuilder private var summary: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: TronSpacing.xxs) {
                if let value = row.valueChange { Text(value).lineLimit(2).truncationMode(.tail) }
                Text("\(row.actor) · \(row.scope)").lineLimit(2).truncationMode(.tail)
            }
        } else {
            ViewThatFits(in: .horizontal) {
                Text(([row.valueChange, row.actor, row.scope].compactMap { $0 }).joined(separator: " · ")).lineLimit(1)
                Text(([row.newValue, row.actor, row.scope].compactMap { $0 }).joined(separator: " · ")).lineLimit(1)
                HStack(spacing: 0) {
                    Text(row.actor).lineLimit(1).truncationMode(.tail)
                    Text(" · \(row.scope)").lineLimit(1).fixedSize()
                }
            }
        }
    }

    private var when: some View {
        HStack(spacing: TronSpacing.sm) {
            if let date = row.date {
                Text(date, format: .relative(presentation: .named))
            }
            if isNew {
                Text("NEW").font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .bold))
                    .foregroundStyle(Color.tronEmerald)
            }
        }
        .lineLimit(1)
    }
}
