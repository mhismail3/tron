import SwiftUI
import TronMobileCore

/// Edits a tool selection (a `catalog.tools` setting) with the same groups, rows
/// and detail sheet as Manage Session → Available Tools. Like every checklist
/// it edits a draft committed with Save; the order chosen is kept.
struct SettingsToolsEditor: View {
    let title: String
    let options: [SettingsOption]
    let onSave: ([String]) -> Void
    @Environment(\.tronSettingsVisualTheme) private var settingsTheme
    @Environment(\.dismiss) private var dismiss
    @State private var chosen: [String]
    @State private var detail: ProjectResourceSelection?
    private let initial: [String]

    init(title: String, selected: [String], options: [SettingsOption], onSave: @escaping ([String]) -> Void) {
        self.title = title; self.options = options; self.onSave = onSave
        initial = selected
        _chosen = State(initialValue: selected)
    }

    private var accent: Color { settingsTheme?.accent ?? .tronEmerald }
    private var rows: [AvailableToolRow] {
        options.compactMap { option in
            guard let name = option.value.stringValue else { return nil }
            // A chosen tool the catalog no longer offers has no record; it stays
            // listed with its reason so it can be turned off.
            let reason = option.disabledReason.map { ["description": JSONValue.string($0)] } ?? [:]
            return AvailableToolRow(name: name, title: option.label, detail: option.disabledReason ?? option.detail,
                                    value: option.resource ?? .object(["name": .string(name)].merging(reason) { $1 }))
        }
    }
    private var groups: [AvailableToolGroup] {
        AvailableToolsPresentation.groups(from: .object(["tools": .array(rows.map(\.value))]))
    }

    var body: some View {
        ScrollView {
            AvailableToolsList(groups: groups, active: Set(chosen), accent: accent,
                               onToggle: { tool, enabled in
                if enabled { if !chosen.contains(tool.name) { chosen.append(tool.name) } }
                else { chosen.removeAll { $0 == tool.name } }
            }, onSelect: { tool in
                detail = ProjectResourceSelection(kind: .tools, title: tool.title, value: tool.value)
            })
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
        }
        .tronScrollEdgeChrome()
        .tronNavigationTitle(title)
        .tronSaveToolbar(enabled: chosen != initial) {
            onSave(chosen)
            dismiss()
        }
        .tronManagedSheet(item: $detail, identity: { _ in "settings.tool-detail" }) { selection in
            ProjectResourceDetailSheet(sessionID: "", selection: selection, accentOverride: accent) { detail = nil }
        }
    }
}
