import SwiftUI
import TronMobileCore

/// The existing default-tool controls, owned by the Tools sheet at its Mac or
/// Project layer. Toggling a managed entry preserves every other selector.
struct DefaultToolsSettingsSection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.tronPresentationActivity) private var activity
    let projectCWD: String?
    @PresentationState private var defaultTools: [String] = []
    @PresentationState private var mode = "on"
    @PresentationState private var loading = true
    @PresentationState private var error: String?
    @PresentationState private var generation = 0
    private static let toolsKey = "tools.active"
    private static let codemodeModeKey = "tools.codemode.mode"
    private static let managedTools = ["+codemode", "+tool_search"]
    private var target: SettingsTarget { projectCWD.map(SettingsTarget.project(cwd:)) ?? .global }
    private var otherTools: [String] { defaultTools.filter { !Self.managedTools.contains($0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
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
                // Tools is already a progressive sheet; use the shared choice
                // sheet rather than a native menu that fails at this depth.
                TronChoiceRow(
                    icon: "square.stack.3d.up",
                    title: "Other tools with codemode",
                    detail: mode == "only"
                        ? "Only reachable from codemode scripts"
                        : "Still offered to the agent directly",
                    choices: [TronChoice(id: "on", label: "Both"), TronChoice(id: "only", label: "Codemode only")],
                    selected: mode,
                    accent: .tronCyan
                ) { value in
                    Task { await saveMode(value) }
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
        .task(id: PresentationActivityTaskID(source: "default-tools/\(model.profileRevision)/\(generation)/\(projectCWD ?? "global")", presentationActive: activity.allowsPresentationPublication)) { await load() }
        .onChange(of: model.profileRevision) { _, _ in generation &+= 1 }
    }

    private func current(_ ticket: Int, _ identity: KnowledgePresentationIdentity) -> Bool {
        !Task.isCancelled && activity.allowsPresentationPublication && generation == ticket && model.knowledgePresentationIdentity == identity
    }

    private func load() async {
        guard activity.allowsPresentationPublication else { return }
        let ticket = generation, identity = model.knowledgePresentationIdentity
        loading = true
        do {
            let resolution = try await model.resolveSettingsForRenderer(
                target: target.gatewayTarget, keys: [Self.toolsKey, Self.codemodeModeKey]
            )
            guard current(ticket, identity) else { return }
            defaultTools = resolution.setting(Self.toolsKey)?.value(at: target.writeLayer)?.arrayValue?.compactMap(\.stringValue) ?? []
            mode = resolution.setting(Self.codemodeModeKey)?.value(at: target.writeLayer)?.stringValue ?? "on"
            loading = false; error = nil
        } catch is CancellationError {
        } catch {
            guard current(ticket, identity) else { return }
            loading = false
            self.error = "Default tool settings are unavailable."
        }
    }

    private func persist(_ key: String, _ value: JSONValue) async {
        // A mounted picker child accepts the command while covering this owner;
        // only the follow-up presentation read waits for the parent to uncover.
        guard activity.allowsDataPublication else { return }
        let ticket = generation, identity = model.knowledgePresentationIdentity
        do {
            try await model.changeSetting(target: target.gatewayTarget, change: target.keyChange(key, value: value))
            guard current(ticket, identity) else { return }
            generation &+= 1
        } catch {
            guard current(ticket, identity) else { return }
            self.error = error.localizedDescription
        }
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
