import SwiftUI
import TronMobileCore

/// Pi's built-in extension switches, default tools and code mode for one settings
/// scope. All are served schema keys (`sources.extensions`, `tools.active`,
/// `tools.codemode.mode`) read at the scope's own layer, so the screen shows what
/// this scope stores, not what a higher layer overrides.
/// Every write is an explicit user action; loading never writes back.
struct BuiltinExtensionsSettingsSection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.tronPresentationActivity) private var activity
    let projectCWD: String?
    @State private var entries: [String] = []
    @State private var defaultTools: [String] = []
    @State private var mode = "on"
    @State private var loading = true
    @State private var error: String?
    @State private var generation = 0

    private struct Builtin { let name: String; let title: String; let icon: String; let detail: String }
    private let builtins = [
        Builtin(name: "codemode", title: "Codemode", icon: "chevron.left.forwardslash.chevron.right",
                detail: "Lets the agent run a short script that calls several tools at once"),
        Builtin(name: "tool-search", title: "Tool search", icon: "magnifyingglass",
                detail: "Lets the agent find and load tools it wasn't shown up front"),
        Builtin(name: "mcp", title: "MCP", icon: "server.rack",
                detail: "Connects the servers configured in MCP Servers"),
    ]
    private static let extensionsKey = "sources.extensions"
    private static let toolsKey = "tools.active"
    private static let codemodeModeKey = "tools.codemode.mode"
    private static let managedTools = ["+codemode", "+tool_search"]

    private var target: SettingsTarget { projectCWD.map(SettingsTarget.project(cwd:)) ?? .global }
    private var scopeName: String { projectCWD == nil ? "all sessions" : "this project" }
    /// Entries this screen does not manage (for example `-bash`) stay as written.
    private var otherTools: [String] { defaultTools.filter { !Self.managedTools.contains($0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            TronSettingsGroup("Built-in Extensions", detail: "Turn a built-in off for \(scopeName).", accent: .tronCyan) {
                if loading {
                    TronLoadingState(label: "Loading extension settings…", accent: .tronCyan)
                        .padding(.vertical, TronSpacing.xl)
                } else {
                    ForEach(builtins, id: \.name) { builtin in
                        TronToggleRow(
                            icon: builtin.icon,
                            title: builtin.title,
                            detail: builtin.detail,
                            accent: .tronCyan,
                            isOn: Binding(get: { !entries.contains("-builtin:\(builtin.name)") },
                                          set: { enabled in Task { await setBuiltin(builtin.name, enabled: enabled) } })
                        )
                        if builtin.name != builtins.last?.name { TronSettingsDivider(accent: .tronCyan) }
                    }
                }
            }

            TronSettingsGroup("Default Tools", detail: "Tools the agent has in every new session. MCP servers turn codemode or tool search on by themselves when they need them.", accent: .tronCyan) {
                TronToggleRow(
                    icon: "chevron.left.forwardslash.chevron.right",
                    title: "Always include codemode",
                    detail: "Use codemode even when no MCP server needs it",
                    accent: .tronCyan,
                    isEnabled: !loading,
                    isOn: Binding(get: { defaultTools.contains("+codemode") }, set: { setDefaultTool("+codemode", enabled: $0) })
                )
                TronSettingsDivider(accent: .tronCyan)
                TronToggleRow(
                    icon: "magnifyingglass",
                    title: "Always include tool search",
                    detail: "Use tool search even when no MCP server needs it",
                    accent: .tronCyan,
                    isEnabled: !loading,
                    isOn: Binding(get: { defaultTools.contains("+tool_search") }, set: { setDefaultTool("+tool_search", enabled: $0) })
                )
                TronSettingsDivider(accent: .tronCyan)
                TronSelectionRow(
                    icon: "square.stack.3d.up",
                    title: "Other tools with codemode",
                    detail: mode == "only"
                        ? "Only reachable from codemode scripts"
                        : "Still offered to the agent directly",
                    value: mode == "only" ? "Codemode only" : "Both",
                    accent: .tronCyan
                ) {
                    Button("Both") { Task { await saveMode("on") } }
                    Button("Codemode only") { Task { await saveMode("only") } }
                }
                .disabled(loading)
                if !otherTools.isEmpty {
                    TronSettingsDivider(accent: .tronCyan)
                    TronSettingsRow(icon: "list.bullet", title: "Other entries", subtitle: otherTools.joined(separator: " "),
                                    accent: .tronCyan, subtitleColor: .tronTextSecondary)
                }
            }
            if let error { TronSettingsNotice(message: error, accent: .tronError) }
        }
        .task(id: PresentationActivityTaskID(source: "builtin-settings/\(model.profileRevision)/\(generation)/\(projectCWD ?? "global")", presentationActive: activity.allowsPresentationPublication)) { await load() }
        .onChange(of: model.profileRevision) { _, _ in generation &+= 1 }
    }

    private func load() async {
        guard activity.allowsPresentationPublication else { return }
        let ticket = generation, identity = model.knowledgePresentationIdentity
        loading = true
        let resolution: SettingsResolution
        do {
            resolution = try await model.resolveSettingsForRenderer(
                target: target.gatewayTarget, keys: [Self.extensionsKey, Self.toolsKey, Self.codemodeModeKey]
            )
        } catch is CancellationError {
            return
        } catch {
            guard current(ticket, identity) else { return }
            model.presentError(error)
            loading = false
            self.error = "Extension settings are unavailable."
            return
        }
        guard current(ticket, identity) else { return }
        entries = resolution.setting(Self.extensionsKey)?.value(at: target.writeLayer)?.arrayValue?.compactMap(\.stringValue) ?? []
        defaultTools = resolution.setting(Self.toolsKey)?.value(at: target.writeLayer)?.arrayValue?.compactMap(\.stringValue) ?? []
        mode = resolution.setting(Self.codemodeModeKey)?.value(at: target.writeLayer)?.stringValue ?? "on"
        loading = false; error = nil
    }

    private func current(_ ticket: Int, _ identity: KnowledgePresentationIdentity) -> Bool {
        !Task.isCancelled && activity.allowsPresentationPublication && generation == ticket && model.knowledgePresentationIdentity == identity
    }

    private func persist(_ key: String, _ value: JSONValue) async {
        guard activity.allowsPresentationPublication else { return }
        do {
            try await model.changeSetting(target: target.gatewayTarget, change: target.keyChange(key, value: value))
            generation &+= 1
        } catch { self.error = error.localizedDescription }
    }
    private func setBuiltin(_ name: String, enabled: Bool) async {
        var next = entries.filter { $0 != "-builtin:\(name)" }
        if !enabled { next.append("-builtin:\(name)") }
        entries = next
        await persist(Self.extensionsKey, .array(next.map(JSONValue.string)))
    }
    private func setDefaultTool(_ entry: String, enabled: Bool) {
        var next = defaultTools.filter { $0 != entry }
        if enabled { next.append(entry) }
        defaultTools = next
        Task { await persist(Self.toolsKey, .array(next.map(JSONValue.string))) }
    }
    private func saveMode(_ value: String) async {
        guard value != mode else { return }
        mode = value
        await persist(Self.codemodeModeKey, .string(value))
    }
}
