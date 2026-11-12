import SwiftUI
import TronMobileCore

struct SettingsChangeRow: Identifiable, Equatable, Sendable {
    let entry: SettingsChangeHistoryEntry
    let date: Date?
    let valueChange: String
    let newValue: String
    let actor: String
    let scope: String
    let accessibilityLabel: String

    var id: String { entry.changeId }
    var status: String { entry.status.capitalized }
    var failed: Bool { entry.status == "failed" }

    func retitled(_ workerTitles: [String: String]) -> SettingsChangeRow {
        SettingsChangeRow(entry, workerTitles: workerTitles)
    }

    init(_ entry: SettingsChangeHistoryEntry, workerTitles: [String: String]) {
        self.entry = entry
        date = entry.date
        valueChange = "\(entry.presentation.display.before) → \(entry.presentation.display.after)"
        newValue = "→ \(entry.presentation.display.after)"
        let taskTitle = entry.actor.taskId.flatMap { workerTitles[$0] }
        actor = Self.conciseActor(entry, taskTitle: taskTitle)
        scope = entry.presentation.layer
        let fullActor = entry.presentation.actor
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
        default: entry.presentation.actor
        }
    }

    static func workerTitles(_ sessions: [CatalogSession]) -> [String: String] {
        var titles: [String: String] = [:]
        for session in sessions {
            guard let task = session.homeTaskId, let name = session.name?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty else { continue }
            titles[task] = name
        }
        return titles
    }
}

struct SettingsChangeRowView: View, Equatable {
    static let spacing: CGFloat = TronSpacing.xl

    let row: SettingsChangeRow
    let isNew: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.row == rhs.row && lhs.isNew == rhs.isNew }

    private var accent: Color { row.failed ? .tronError : .tronPrimary }

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

    @ViewBuilder private var summary: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: TronSpacing.xxs) {
                Text(row.valueChange).lineLimit(2).truncationMode(.tail)
                Text("\(row.actor) · \(row.scope)").lineLimit(2).truncationMode(.tail)
            }
        } else {
            ViewThatFits(in: .horizontal) {
                Text([row.valueChange, row.actor, row.scope].joined(separator: " · ")).lineLimit(1)
                Text([row.newValue, row.actor, row.scope].joined(separator: " · ")).lineLimit(1)
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
                    .foregroundStyle(Color.tronPrimary).accessibilityLabel("Since you last looked")
            }
        }
        .lineLimit(1)
    }
}
