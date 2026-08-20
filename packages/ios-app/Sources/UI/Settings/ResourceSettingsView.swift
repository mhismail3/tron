import SwiftUI

struct ResourceSettingsDraft: Equatable {
    var extensions = ""
    var skills = ""
    var prompts = ""
    var themes = ""
    var shellPath = ""
    var shellPrefix = ""
    var npmCommand = ""
    var proxy = ""
    var proxyConfigured = false
    var proxyEdited = false

    func patch(comparedTo baseline: Self) -> JSONValue {
        var patch: [String: JSONValue] = [:]
        if extensions != baseline.extensions {
            patch["extensions"] = .array(settingsLines(extensions).map(JSONValue.string))
        }
        if skills != baseline.skills {
            patch["skills"] = .array(settingsLines(skills).map(JSONValue.string))
        }
        if prompts != baseline.prompts {
            patch["prompts"] = .array(settingsLines(prompts).map(JSONValue.string))
        }
        if themes != baseline.themes {
            patch["themes"] = .array(settingsLines(themes).map(JSONValue.string))
        }
        if shellPath != baseline.shellPath { patch["shellPath"] = shellPath.isEmpty ? .null : .string(shellPath) }
        if shellPrefix != baseline.shellPrefix {
            patch["shellCommandPrefix"] = shellPrefix.isEmpty ? .null : .string(shellPrefix)
        }
        if npmCommand != baseline.npmCommand {
            patch["npmCommand"] = npmCommand.isEmpty
                ? .null
                : .array(npmCommand.split(separator: " ").map { .string(String($0)) })
        }
        if proxyEdited { patch["httpProxy"] = proxy.isEmpty ? .null : .string(proxy) }
        return .object(patch)
    }

    func afterSuccessfulSave() -> Self {
        var saved = self
        if proxyEdited {
            if !proxy.isEmpty { saved.proxyConfigured = true }
            saved.proxy = ""
            saved.proxyEdited = false
        }
        return saved
    }
}

private func settingsLines(_ value: String) -> [String] {
    value.split(whereSeparator: \.isNewline)
        .map(String.init)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
}

struct ResourceSettingsView: View {
    private enum Editor: String, Identifiable {
        case extensions, skills, prompts, themes, shellPath, shellPrefix, npmCommand, proxy
        var id: String { rawValue }
        var title: String {
            switch self {
            case .extensions: "Extension Locations"
            case .skills: "Skill Locations"
            case .prompts: "Prompt Locations"
            case .themes: "Terminal Theme Locations"
            case .shellPath: "Shell Executable"
            case .shellPrefix: "Shell Command Prefix"
            case .npmCommand: "Package Manager Command"
            case .proxy: "HTTP Proxy"
            }
        }
        var explanation: String {
            switch self {
            case .extensions: "Additional extension files or folders outside Tron's automatically discovered extension locations. Extensions execute with your Mac user authority."
            case .skills: "Additional skill files or folders outside the standard global and project skill locations."
            case .prompts: "Additional prompt-template files or folders. Standard prompts folders are discovered automatically."
            case .themes: "Additional terminal-only theme files or folders. These do not change the Tron app appearance."
            case .shellPath: "Overrides the shell executable used for agent shell commands. Leave empty to use the Mac account's default shell."
            case .shellPrefix: "Runs this text before every agent shell command. Leave empty unless your shell environment requires initialization."
            case .npmCommand: "Overrides the command used to install and update packages. Enter argv components separated by spaces, for example: mise exec node@20 -- npm."
            case .proxy: "Routes provider HTTP and HTTPS traffic through this proxy. The existing value is write-only and is not returned to this iPhone."
            }
        }
        var placeholder: String {
            switch self {
            case .extensions: "/path/to/extension.ts"
            case .skills: "~/.codex/skills"
            case .prompts: "/path/to/prompts"
            case .themes: "/path/to/theme.json"
            case .shellPath: "/bin/zsh"
            case .shellPrefix: "source ~/.profile"
            case .npmCommand: "mise exec node@20 -- npm"
            case .proxy: "http://127.0.0.1:7890"
            }
        }
        var acceptsMultipleLines: Bool {
            switch self { case .extensions, .skills, .prompts, .themes: true; default: false }
        }
    }

    @Environment(AppModel.self) private var model
    let projectCWD: String?
    @State private var scope: SettingsScope = .global
    @State private var draft = ResourceSettingsDraft()
    @State private var drafts = ScopedSettingsDraftStore<ResourceSettingsDraft>()
    @State private var saving = false

    private var allowsProjectScope: Bool { projectCWD != nil }
    @State private var editor: Editor?

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(alignment: .leading, spacing: 18) {
                scopeGroup

                TronSettingsGroup("Additional Locations", detail: "Optional paths outside automatic discovery.") {
                    VStack(spacing: 0) {
                        editorRow(.extensions, icon: "shippingbox", value: draft.extensions, accent: .tronPurple)
                        TronSettingsDivider(accent: .tronPurple)
                        editorRow(.skills, icon: "sparkles", value: draft.skills, accent: .tronEmerald)
                        TronSettingsDivider(accent: .tronPurple)
                        editorRow(.prompts, icon: "text.quote", value: draft.prompts, accent: .tronCyan)
                        TronSettingsDivider(accent: .tronPurple)
                        editorRow(.themes, icon: "paintpalette", value: draft.themes, accent: .tronTeal)
                    }
                }

                TronSettingsGroup("Advanced Mac Overrides", detail: "Normally leave these on System Default.", accent: .tronSlate) {
                    VStack(spacing: 0) {
                        editorRow(.shellPath, icon: "terminal", value: draft.shellPath, accent: .tronTeal)
                        TronSettingsDivider(accent: .tronSlate)
                        editorRow(.shellPrefix, icon: "text.insert", value: draft.shellPrefix, accent: .tronTeal)
                        TronSettingsDivider(accent: .tronSlate)
                        editorRow(.npmCommand, icon: "shippingbox.and.arrow.backward", value: draft.npmCommand, accent: .tronPurple)
                        TronSettingsDivider(accent: .tronSlate)
                        editorRow(.proxy, icon: "network", value: draft.proxy, accent: .tronAmber)
                    }
                }

                TronInfoCard(
                    icon: "info.circle",
                    text: "Tron already discovers resources in the standard global and trusted-project folders. Add locations here only when resources live somewhere else.",
                    accent: .tronCyan
                )
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
        }
        .scrollDismissesKeyboard(.interactively)
        .tronScrollEdgeChrome()
        .tronNavigationTitle("Resource Locations")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                TronSaveToolbarButton(isSaving: saving, isEnabled: hasUnsavedChanges) {
                    Task { await save() }
                }
            }
        }
        .task(id: SettingsLoadID(target: settingsTarget, invalidationGeneration: model.settingsInvalidationGeneration)) {
            if !allowsProjectScope { scope = .global }
            await load()
        }
        .onChange(of: draft) { _, value in
            if let target = settingsTarget { drafts.update(value, for: target) }
        }
        .sheet(item: $editor) { value in editorSheet(value) }
    }

    private var scopeGroup: some View {
        TronSettingsGroup("Applies To") {
            TronValueRow(icon: "scope", title: scope == .project ? "Current Project" : "Every Project", detail: scopeExplanation) {
                if allowsProjectScope {
                    TronInlineMenu(scope == .project ? "Project" : "Global") {
                        Button("Every Project") { selectScope(.global) }
                        Button("Current Project") { selectScope(.project) }
                    }
                }
            }
        }
    }

    private var scopeExplanation: String {
        scope == .project ? "Saved in this trusted project's settings." : "Saved as defaults for this Mac."
    }

    private func editorRow(_ value: Editor, icon: String, value text: String, accent: Color) -> some View {
        Button { editor = value } label: {
            TronSettingsRow(icon: icon, title: value.title, subtitle: summary(value, text: text), accent: accent)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens an editor with an explanation and examples")
    }

    private func summary(_ editor: Editor, text: String) -> String {
        if editor == .proxy {
            if draft.proxyEdited {
                return draft.proxy.isEmpty ? "System Default" : "New value entered · hidden"
            }
            if draft.proxyConfigured { return "Configured · value hidden" }
        }
        let values = editor.acceptsMultipleLines ? lines(text) : (text.isEmpty ? [] : [text])
        guard !values.isEmpty else {
            return editor.acceptsMultipleLines ? "Automatic discovery only" : "System Default"
        }
        if editor.acceptsMultipleLines { return "\(values.count) additional location\(values.count == 1 ? "" : "s")" }
        return text
    }

    private func editorSheet(_ value: Editor) -> some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Label(value.explanation, systemImage: "info.circle")
                        .font(TronTypography.bodySM)
                        .foregroundStyle(Color.tronTextPrimary)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .tronGlassSurface(accent: .tronCyan, tintOpacity: 0.08)
                    pathEditor(value)
                    if value.acceptsMultipleLines {
                        TronCaption("Enter one file, directory, glob, or exclusion per line.")
                    }
                    Button("Use System Default") { binding(for: value).wrappedValue = "" }
                        .buttonStyle(TronActionButtonStyle())
                }
                .padding(18)
            }
            .scrollDismissesKeyboard(.interactively)
            .tronScrollEdgeChrome()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { TronSheetTitle(title: value.title) }
                ToolbarItem(placement: .confirmationAction) {
                    Button { editor = nil } label: {
                        Image(systemName: "checkmark").foregroundStyle(Color.tronEmerald)
                    }
                    .accessibilityLabel("Done")
                }
            }
        }
        .tronTopBlur(.sheet)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
    }

    @ViewBuilder
    private func pathEditor(_ value: Editor) -> some View {
        ZStack(alignment: .topLeading) {
            if value == .proxy {
                SecureField("", text: binding(for: value))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } else {
                TextField("", text: binding(for: value), axis: value.acceptsMultipleLines ? .vertical : .horizontal)
                    .lineLimit(value.acceptsMultipleLines ? 3...10 : 1...1)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .multilineTextAlignment(.leading)
            }
            if binding(for: value).wrappedValue.isEmpty {
                Text(value.placeholder)
                    .font(TronTypography.code(size: TronTypography.sizeBody))
                    .foregroundStyle(Color.tronTextMuted)
                    .allowsHitTesting(false)
            }
        }
        .frame(
            maxWidth: .infinity,
            minHeight: value.acceptsMultipleLines ? 120 : 52,
            alignment: value.acceptsMultipleLines ? .topLeading : .leading
        )
        .tronField(monospaced: true, compact: true)
        .accessibilityLabel(value.title)
    }

    private func binding(for editor: Editor) -> Binding<String> {
        Binding {
            switch editor {
            case .extensions: draft.extensions
            case .skills: draft.skills
            case .prompts: draft.prompts
            case .themes: draft.themes
            case .shellPath: draft.shellPath
            case .shellPrefix: draft.shellPrefix
            case .npmCommand: draft.npmCommand
            case .proxy: draft.proxy
            }
        } set: { value in
            switch editor {
            case .extensions: draft.extensions = value
            case .skills: draft.skills = value
            case .prompts: draft.prompts = value
            case .themes: draft.themes = value
            case .shellPath: draft.shellPath = value
            case .shellPrefix: draft.shellPrefix = value
            case .npmCommand: draft.npmCommand = value
            case .proxy:
                draft.proxy = value
                draft.proxyEdited = true
            }
        }
    }

    private var settingsTarget: SettingsTarget? {
        SettingsTarget(scope: scope, projectCWD: projectCWD)
    }

    private var hasUnsavedChanges: Bool {
        guard let target = settingsTarget else { return false }
        return drafts.isDirty(target)
    }

    private func selectScope(_ newScope: SettingsScope) {
        guard newScope != scope,
              let newTarget = SettingsTarget(scope: newScope, projectCWD: projectCWD) else { return }
        let nextDraft = drafts.draftForScopeSwitch(
            current: draft,
            from: settingsTarget,
            to: newTarget,
            default: ResourceSettingsDraft()
        )
        scope = newScope
        draft = nextDraft
    }

    private func load() async {
        guard let target = settingsTarget else { return }
        // Establish a clean snapshot before awaiting the gateway; a real edit
        // during the request still marks the draft dirty and rejects stale data.
        _ = drafts.install(draft, for: target)
        guard await model.refreshSettings(target: target),
              target == settingsTarget,
              editor == nil,
              let loaded = projectionDraft(target: target),
              drafts.install(loaded, for: target) else { return }
        draft = loaded
    }

    private func projectionDraft(target: SettingsTarget) -> ResourceSettingsDraft? {
        guard let root = model.settings(for: target)?.objectValue,
              let value = root["effective"]?.objectValue else { return nil }
        var loaded = ResourceSettingsDraft()
        loaded.shellPath = value["shellPath"]?.stringValue ?? ""
        loaded.shellPrefix = value["shellCommandPrefix"]?.stringValue ?? ""
        loaded.npmCommand = (value["npmCommand"]?.arrayValue ?? [])
            .compactMap(\.stringValue)
            .joined(separator: " ")
        loaded.proxyConfigured = value["httpProxyConfigured"]?.boolValue == true
        if let resources = value["resources"]?.objectValue {
            loaded.extensions = resources.lines("extensions")
            loaded.skills = resources.lines("skills")
            loaded.prompts = resources.lines("prompts")
            loaded.themes = resources.lines("themes")
        }
        return loaded
    }

    private func save() async {
        guard let target = settingsTarget else { return }
        drafts.update(draft, for: target)
        guard drafts.isDirty(target),
              let savingRevision = drafts.revision(for: target) else { return }
        let savingDraft = draft
        saving = true
        defer { saving = false }
        let baseline = drafts.baseline(for: target) ?? ResourceSettingsDraft()
        let patch = savingDraft.patch(comparedTo: baseline)
        do {
            try await model.updateSettings(patch, target: target)
            guard target == settingsTarget else { return }
            let resultingDraft = projectionDraft(target: target)
                ?? savingDraft.afterSuccessfulSave()
            if drafts.markSaved(
                submitted: savingDraft,
                resulting: resultingDraft,
                for: target,
                expectedRevision: savingRevision
            ) {
                draft = resultingDraft
            }
        }
        catch { model.lastError = error.localizedDescription }
    }

    private func lines(_ value: String) -> [String] {
        value.split(whereSeparator: \.isNewline).map(String.init).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}
