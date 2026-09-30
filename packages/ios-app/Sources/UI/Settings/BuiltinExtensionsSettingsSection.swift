import SwiftUI
import TronMobileCore

/// Settings projection for Pi's built-in extension switches and tool defaults.
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
    @State private var toolOverrides = ""
    private let builtins = ["codemode", "tool-search", "mcp"]

    private var target: SettingsTarget { projectCWD.map(SettingsTarget.project(cwd:)) ?? .global }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
        TronSettingsGroup("Pi Built-ins", detail: "Settings for the agent and its extensions", accent: .tronCyan, surfaceStyle: .glass) {
            if loading { ProgressView("Loading extension settings…").padding(12) }
            ForEach(builtins, id: \.self) { name in
                TronToggleRow(
                    icon: "puzzlepiece.extension",
                    title: name,
                    detail: "Disable this Pi built-in in the current scope",
                    accent: .tronCyan,
                    isOn: Binding(get: { !entries.contains("-builtin:\(name)") }, set: { enabled in Task { await setBuiltin(name, enabled: enabled) } })
                )
                if name != builtins.last { TronSettingsDivider(accent: .tronCyan) }
            }
            TronSettingsDivider(accent: .tronCyan)
            VStack(alignment: .leading, spacing: 8) {
                Text("Default tools").font(TronTypography.secondaryDescription).foregroundStyle(Color.tronTextPrimary)
                TronToggleRow(icon: "chevron.left.forwardslash.chevron.right", title: "+codemode", detail: "Include codemode by default", accent: .tronCyan, isOn: Binding(get: { defaultTools.contains("+codemode") }, set: { setDefaultTool("+codemode", enabled: $0) }))
                TronToggleRow(icon: "magnifyingglass", title: "+tool_search", detail: "Include tool search by default", accent: .tronCyan, isOn: Binding(get: { defaultTools.contains("+tool_search") }, set: { setDefaultTool("+tool_search", enabled: $0) }))
                TextField("Other tool modifiers, separated by spaces", text: $toolOverrides).textInputAutocapitalization(.never).autocorrectionDisabled()
                HStack {
                    Button("Save tools") { Task { await saveTools() } }.buttonStyle(.bordered)
                    Spacer()
                    Picker("Codemode", selection: $mode) {
                        Text("On").tag("on")
                        Text("Only").tag("only")
                    }.onChange(of: mode) { _, value in guard !loading else { return }; Task { await saveMode(value) } }
                }
            }.padding(12)
        }
        .tronSettingsCaption("Codemode and tool search activate as MCP exposure requires them. Use +name or -name entries to change the model's default tool set.")
        if let error { TronSettingsNotice(message: error) }
        }
        .task(id: PresentationActivityTaskID(source: "builtin-settings/\(model.profileRevision)/\(generation)/\(projectCWD ?? "global")", presentationActive: activity.allowsPresentationPublication)) { await load() }
        .onChange(of: model.profileRevision) { _, _ in generation &+= 1 }
    }

    private func load() async {
        guard activity.allowsPresentationPublication else { return }
        let ticket = generation, identity = model.knowledgePresentationIdentity
        loading = true
        let loaded = await model.refreshSettings(target: target)
        guard current(ticket, identity) else { return }
        guard loaded, let root = model.settings(for: target)?.objectValue,
              let scope = root["documents"]?.objectValue?[target.scope.rawValue]?.objectValue else {
            loading = false
            error = loaded ? nil : "Extension settings are unavailable."
            return
        }
        entries = scope["extensions"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let effective = root["effective"]?.objectValue ?? [:]
        defaultTools = effective["defaultTools"]?.arrayValue?.compactMap(\.stringValue) ?? []
        toolOverrides = defaultTools.joined(separator: " ")
        mode = effective["codemode"]?.objectValue?["mode"]?.stringValue ?? "on"
        loading = false; error = nil
    }

    private func current(_ ticket: Int, _ identity: KnowledgePresentationIdentity) -> Bool {
        !Task.isCancelled && activity.allowsPresentationPublication && generation == ticket && model.knowledgePresentationIdentity == identity
    }

    private func persist(_ patch: JSONValue) async {
        guard activity.allowsPresentationPublication else { return }
        do { try await model.updateSettings(patch, target: target); generation &+= 1 }
        catch { self.error = error.localizedDescription }
    }
    private func setBuiltin(_ name: String, enabled: Bool) async {
        var next = entries.filter { $0 != "-builtin:\(name)" }
        if !enabled { next.append("-builtin:\(name)") }
        await persist(.object(["extensions": .array(next.map(JSONValue.string))]))
    }
    private func setDefaultTool(_ entry: String, enabled: Bool) {
        var next = defaultTools.filter { $0 != entry }
        if enabled { next.append(entry) }
        defaultTools = next
        toolOverrides = next.joined(separator: " ")
        Task { await persist(.object(["defaultTools": .array(next.map(JSONValue.string))])) }
    }
    private func saveTools() async {
        let tools = toolOverrides.split(whereSeparator: \.isWhitespace).map(String.init)
        defaultTools = tools
        await persist(.object(["defaultTools": .array(tools.map(JSONValue.string))]))
    }
    private func saveMode(_ value: String) async {
        await persist(.object(["codemode": .object(["mode": .string(value)])]))
    }
}
