import SwiftUI
import TronMobileCore

/// Edits a tool selection (a `catalog.tools` setting) with the same groups, rows
/// and detail sheet as Manage Session → Available Tools. Like every checklist
/// it edits a draft committed with Save; the order chosen is kept.
struct SettingsToolsEditor: View {
    let title: String
    let options: [SettingsOption]
    let onSave: (([String]) -> Void)?
    @Environment(\.tronSettingsVisualTheme) private var settingsTheme
    @Environment(\.dismiss) private var dismiss
    @State private var chosen: [String]
    @State private var detail: ProjectResourceSelection?
    private let initial: [String]

    init(title: String, selected: [String], options: [SettingsOption], onSave: (([String]) -> Void)? = nil) {
        self.title = title; self.options = options; self.onSave = onSave
        initial = selected
        _chosen = State(initialValue: selected)
    }

    private var accent: Color { settingsTheme?.accent ?? .tronEmerald }
    private var groups: [AvailableToolGroup] {
        let tools = options.compactMap { option -> JSONValue? in
            guard let name = option.value.stringValue, onSave != nil || chosen.contains(name) else { return nil }
            // The option owns identity. Home's curated catalog deliberately has
            // resource: {}; resource is optional detail, not a second catalog.
            var resource = option.resource?.objectValue ?? [:]
            resource["name"] = .string(name)
            if resource["label"] == nil { resource["label"] = .string(option.label) }
            if let detail = option.disabledReason ?? option.detail, resource["description"] == nil {
                resource["description"] = .string(detail)
            }
            return .object(resource)
        }
        return AvailableToolsPresentation.groups(from: .object(["tools": .array(tools)]))
    }

    var body: some View {
        Group {
            if let onSave {
                toolList.tronSaveToolbar(enabled: chosen != initial) { onSave(chosen); dismiss() }
            } else { toolList }
        }
        .tronNavigationTitle(title)
        .tronManagedSheet(item: $detail, identity: { _ in "settings.tool-detail" }) { selection in
            ProjectResourceDetailSheet(sessionID: "", selection: selection, accentOverride: accent) { detail = nil }
        }
    }

    private var toolList: some View {
        ScrollView {
            AvailableToolsList(groups: groups, active: Set(chosen), accent: accent,
                               onToggle: onSave == nil ? nil : { tool, enabled in
                if enabled { if !chosen.contains(tool.name) { chosen.append(tool.name) } }
                else { chosen.removeAll { $0 == tool.name } }
            }, onSelect: { tool in
                detail = ProjectResourceSelection(kind: .tools, title: tool.title, value: tool.value)
            })
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
        }
        .tronScrollEdgeChrome()

    }
}
