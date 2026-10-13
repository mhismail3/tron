import SwiftUI
import TronMobileCore

/// Edits the tools.active setting with the same catalog groups, rows and detail
/// surface used by Manage Session → Available Tools.
struct SettingsToolsEditor: View {
    let title: String
    let selected: [String]
    let options: [SettingsOption]
    let onChange: ([String]) -> Void
    @Environment(\.tronSettingsVisualTheme) private var settingsTheme
    @State private var detail: ProjectResourceSelection?

    private var accent: Color { settingsTheme?.accent ?? .tronEmerald }
    private var rows: [AvailableToolRow] {
        options.compactMap { option in
            guard let name = option.value.stringValue, let value = option.resource else { return nil }
            return AvailableToolRow(name: name, title: option.label, detail: option.detail, value: value)
        }
    }
    private var groups: [AvailableToolGroup] {
        let values = JSONValue.object(["tools": .array(rows.map(\.value))])
        return AvailableToolsPresentation.groups(from: values)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                AvailableToolsList(groups: groups, active: Set(selected), accent: accent,
                                   onToggle: { tool, enabled in
                    var next = Set(selected)
                    if enabled { next.insert(tool.name) } else { next.remove(tool.name) }
                    onChange(options.compactMap { $0.value.stringValue }.filter(next.contains))
                }, onSelect: { tool in
                    detail = ProjectResourceSelection(kind: .tools, title: tool.title, value: tool.value)
                })
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
            }
            .tronScrollEdgeChrome()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { TronSheetTitle(title: title, accent: accent) }
            }
        }
        .tronManagedSheet(item: $detail, identity: { _ in "settings.tool-detail" }) { selection in
            ProjectResourceDetailSheet(sessionID: "", selection: selection, accentOverride: accent) { detail = nil }
        }
        .tronSettingsVisualTheme(accent: accent)
        .tint(accent)
    }
}
