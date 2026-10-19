import SwiftUI
import TronMobileCore

/// Built-in extension switches for one scope. The scope's own layer stays
/// authoritative; loading never writes, and unrelated selectors are preserved.
struct BuiltinExtensionsSettingsSection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.tronPresentationActivity) private var activity
    let projectCWD: String?
    @State private var entries: [String] = []
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

    private var target: SettingsTarget { projectCWD.map(SettingsTarget.project(cwd:)) ?? .global }
    private var scopeName: String { projectCWD == nil ? "all sessions" : "this project" }

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
                target: target.gatewayTarget, keys: [Self.extensionsKey]
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
}
