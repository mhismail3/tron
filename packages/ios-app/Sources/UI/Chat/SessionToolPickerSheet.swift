import SwiftUI
import TronMobileCore

/// One tool the user can turn on or off for this chat.
struct AvailableToolRow: Identifiable, Equatable, Sendable {
    let name: String
    let title: String
    let detail: String?
    /// The runtime's tool record, shown in full by the detail sheet.
    let value: JSONValue
    var id: String { name }
}

/// Tools of one origin: Pi's built-ins, Tron's own modules, one installed
/// package, local extensions, or one MCP server.
struct AvailableToolGroup: Identifiable, Equatable, Sendable {
    enum Origin: Hashable, Sendable {
        case builtIn, tron, package(String), local, mcp(String)
    }
    let origin: Origin
    let tools: [AvailableToolRow]
    var id: Origin { origin }

    var title: String {
        switch origin {
        case .builtIn: "Built-in"
        case .tron: "Tron"
        case .package(let name): name
        case .local: "Local Extensions"
        case .mcp(let server): "\(server) (MCP)"
        }
    }

    fileprivate var order: Int {
        switch origin {
        case .builtIn: 0
        case .tron: 1
        case .package: 2
        case .local: 3
        case .mcp: 4
        }
    }
}

/// Projects `session.resources` tool rows into the Available Tools groups.
/// Pi sends `namespace` as an object (`{ name: "mcp__server", description }`),
/// never a string; an MCP namespace names the server group.
enum AvailableToolsPresentation {
    static func groups(from resources: JSONValue?) -> [AvailableToolGroup] {
        let values = resources?.objectValue?["tools"]?.arrayValue ?? []
        var grouped: [AvailableToolGroup.Origin: [AvailableToolRow]] = [:]
        for value in values {
            guard let object = value.objectValue,
                  let name = object["name"]?.stringValue, !name.isEmpty,
                  object["exposure"]?.stringValue != "hidden" else { continue }
            let row = AvailableToolRow(
                name: name,
                title: title(name: name, value: value),
                detail: object["description"]?.stringValue
                    .map(ProjectResourceTextPresentation.readableDescription)
                    .flatMap { $0.isEmpty ? nil : $0 },
                value: value
            )
            grouped[origin(object), default: []].append(row)
        }
        return grouped.map { origin, rows in
            AvailableToolGroup(
                origin: origin,
                tools: rows.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            )
        }.sorted {
            $0.order != $1.order
                ? $0.order < $1.order
                : $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    private static func origin(_ object: [String: JSONValue]) -> AvailableToolGroup.Origin {
        if let namespace = object["namespace"]?.objectValue?["name"]?.stringValue,
           namespace.hasPrefix("mcp__") {
            return .mcp(String(namespace.dropFirst("mcp__".count)))
        }
        switch object["distribution"]?.stringValue {
        case "module": return .tron
        case "local": return .local
        case "external": return .package(packageName(object["source"]?.stringValue ?? ""))
        default: return .builtIn
        }
    }

    /// MCP tools are registered as `mcp__<server>__<tool>`; within their
    /// server group only the tool part is meaningful.
    private static func title(name: String, value: JSONValue) -> String {
        let title = ProjectResourceTitlePresentation.title(kind: .tools, value: value)
        guard name.hasPrefix("mcp__"), let range = name.range(of: "__", range: name.index(name.startIndex, offsetBy: 5)..<name.endIndex)
        else { return title }
        let label = value.objectValue?["label"]?.stringValue
        return label == nil || label == name
            ? ComposerResourceNameFormatter.friendly(String(name[range.upperBound...]))
            : title
    }

    /// `npm:@scope/name@1.2.3` → `@scope/name`; `git:github.com/o/repo@sha` → `repo`.
    static func packageName(_ source: String) -> String {
        var spec = source
        for prefix in ["npm:", "git:", "github:", "https://", "http://"] where spec.hasPrefix(prefix) {
            spec.removeFirst(prefix.count)
        }
        let searchStart = spec.hasPrefix("@") ? spec.index(after: spec.startIndex) : spec.startIndex
        if let at = spec[searchStart...].firstIndex(of: "@") { spec = String(spec[..<at]) }
        if source.hasPrefix("npm:") { return spec.isEmpty ? "Package" : spec }
        let last = (spec as NSString).lastPathComponent
        let name = last.hasSuffix(".git") ? String(last.dropLast(4)) : last
        return name.isEmpty ? "Package" : name
    }
}

/// The grouped tools surface used by the settings renderer.
/// The caller owns selection and mutation.
struct AvailableToolsList: View {
    let groups: [AvailableToolGroup]
    let active: Set<String>
    let accent: Color
    var isSaving = false
    var onToggle: ((AvailableToolRow, Bool) -> Void)? = nil
    let onSelect: (AvailableToolRow) -> Void

    var body: some View {
        TronSettingsSections(alignment: .leading, spacing: 18, lazy: true) {
            ForEach(groups) { group in
                let enabled = group.tools.filter { active.contains($0.name) }.count
                TronSettingsGroup(group.title, detail: "\(enabled) of \(group.tools.count) on", accent: accent,
                                  surfaceStyle: .scrollOptimized) {
                    ForEach(Array(group.tools.enumerated()), id: \.element.id) { index, tool in
                        if index > 0 { TronSettingsDivider(accent: accent) }
                        HStack(spacing: 0) {
                            Button { onSelect(tool) } label: {
                                TronSettingsRow(icon: nil, title: tool.title, subtitle: tool.detail, accent: accent)
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("Shows the tool's description and inputs")
                            if let onToggle {
                            Button { onToggle(tool, !active.contains(tool.name)) } label: {
                                TronToggleControl(isOn: active.contains(tool.name), accent: accent)
                                    .padding(.trailing, TronSettingsLayoutPolicy.rowHorizontalPadding)
                                    .frame(minHeight: TronSettingsLayoutPolicy.rowMinimumHeight)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(isSaving)
                            .opacity(isSaving ? 0.62 : 1)
                            .accessibilityRepresentation {
                                Toggle(isOn: Binding(get: { active.contains(tool.name) },
                                                     set: { onToggle(tool, $0) })) { Text(tool.title) }
                                    .disabled(isSaving)
                            }
                            }
                        }
                    }
                }
            }
        }
    }
}
