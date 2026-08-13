import SwiftUI

struct RuntimeBehaviorSettingsView: View {
    @Environment(AppModel.self) private var model
    let allowsProjectScope: Bool
    @State private var scope = "global"
    @State private var transport = "auto"
    @State private var steeringMode = "one-at-a-time"
    @State private var followUpMode = "one-at-a-time"
    @State private var compactionEnabled = true
    @State private var compactionReserve = 16_384
    @State private var compactionRecent = 20_000
    @State private var branchReserve = 16_384
    @State private var branchSkipPrompt = false
    @State private var retryEnabled = true
    @State private var retryCount = 3
    @State private var retryDelay = 1_000
    @State private var providerTimeout = 120_000
    @State private var providerRetryCount = 2
    @State private var providerRetryDelay = 30_000
    @State private var httpIdleTimeout = 300_000
    @State private var websocketTimeout = 10_000
    @State private var hideThinking = false
    @State private var cacheNotices = false
    @State private var resizeImages = true
    @State private var blockImages = false
    @State private var skillCommands = true
    @State private var installTelemetry = true
    @State private var analytics = false
    @State private var mermaid = "final"
    @State private var codeIndent = "  "
    @State private var anthropicWarning = true
    @State private var saving = false

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(alignment: .leading, spacing: 18) {
                scopeGroup
                TronSettingsGroup("Provider Transport", accent: .tronCyan) {
                    VStack(spacing: 0) {
                        choiceRow("network", "Transport", transportLabel, accent: .tronCyan) {
                            Button("Automatic") { transport = "auto" }
                            Button("Server-Sent Events") { transport = "sse" }
                            Button("WebSocket") { transport = "websocket" }
                            Button("Cached WebSocket") { transport = "websocket-cached" }
                        }
                        TronSettingsDivider(accent: .tronCyan)
                        numberRow("timer", "HTTP idle timeout", "Milliseconds", value: $httpIdleTimeout, accent: .tronCyan)
                        TronSettingsDivider(accent: .tronCyan)
                        numberRow("bolt.horizontal", "WebSocket timeout", "Milliseconds", value: $websocketTimeout, accent: .tronCyan)
                    }
                }
                TronSettingsGroup("Message Queue", accent: .tronPurple) {
                    VStack(spacing: 0) {
                        choiceRow("arrow.turn.up.right", "Steering delivery", queueLabel(steeringMode), accent: .tronPurple) {
                            Button("Deliver all") { steeringMode = "all" }
                            Button("One at a time") { steeringMode = "one-at-a-time" }
                        }
                        TronSettingsDivider(accent: .tronPurple)
                        choiceRow("clock.arrow.circlepath", "Follow-up delivery", queueLabel(followUpMode), accent: .tronPurple) {
                            Button("Deliver all") { followUpMode = "all" }
                            Button("One at a time") { followUpMode = "one-at-a-time" }
                        }
                    }
                }
                TronSettingsGroup("Compaction", accent: .tronTeal) {
                    VStack(spacing: 0) {
                        TronToggleRow(icon: "arrow.triangle.2.circlepath", title: "Automatic compaction", accent: .tronTeal, isOn: $compactionEnabled)
                        TronSettingsDivider(accent: .tronTeal)
                        numberRow("gauge.with.dots.needle.33percent", "Reserve tokens", nil, value: $compactionReserve, accent: .tronTeal)
                        TronSettingsDivider(accent: .tronTeal)
                        numberRow("text.line.last.and.arrowtriangle.forward", "Keep recent tokens", nil, value: $compactionRecent, accent: .tronTeal)
                        TronSettingsDivider(accent: .tronTeal)
                        numberRow("arrow.triangle.branch", "Branch summary reserve", nil, value: $branchReserve, accent: .tronTeal)
                        TronSettingsDivider(accent: .tronTeal)
                        TronToggleRow(icon: "text.bubble", title: "Skip branch-summary prompt", accent: .tronTeal, isOn: $branchSkipPrompt)
                    }
                }
                TronSettingsGroup("Retry", accent: .tronAmber) {
                    VStack(spacing: 0) {
                        TronToggleRow(icon: "arrow.clockwise", title: "Automatic retry", accent: .tronAmber, isOn: $retryEnabled)
                        TronSettingsDivider(accent: .tronAmber)
                        numberRow("number", "Agent retry count", nil, value: $retryCount, accent: .tronAmber)
                        TronSettingsDivider(accent: .tronAmber)
                        numberRow("timer", "Base delay", "Milliseconds", value: $retryDelay, accent: .tronAmber)
                        TronSettingsDivider(accent: .tronAmber)
                        numberRow("hourglass", "Provider timeout", "Milliseconds", value: $providerTimeout, accent: .tronAmber)
                        TronSettingsDivider(accent: .tronAmber)
                        numberRow("number", "Provider retry count", nil, value: $providerRetryCount, accent: .tronAmber)
                        TronSettingsDivider(accent: .tronAmber)
                        numberRow("timer", "Maximum provider delay", "Milliseconds", value: $providerRetryDelay, accent: .tronAmber)
                    }
                }
                TronSettingsGroup("Conversation") {
                    VStack(spacing: 0) {
                        toggleRows
                    }
                }
                TronSettingsGroup("Markdown", accent: .tronPurple) {
                    VStack(spacing: 0) {
                        choiceRow("flowchart", "Mermaid diagrams", mermaid.capitalized, accent: .tronPurple) {
                            Button("Off") { mermaid = "off" }
                            Button("Completed responses") { mermaid = "final" }
                            Button("While streaming") { mermaid = "streaming" }
                        }
                        TronSettingsDivider(accent: .tronPurple)
                        TronValueRow(icon: "chevron.left.forwardslash.chevron.right", title: "Code block indent", accent: .tronPurple) {
                            TextField("Indent", text: $codeIndent)
                                .tronInlineField(monospaced: true)
                                .frame(width: 100)
                        }
                    }
                }
                TronSettingsGroup("Privacy and Warnings", accent: .tronSlate) {
                    VStack(spacing: 0) {
                        TronToggleRow(icon: "chart.bar", title: "Installation telemetry", accent: .tronSlate, isOn: $installTelemetry)
                        TronSettingsDivider(accent: .tronSlate)
                        TronToggleRow(icon: "waveform.path.ecg", title: "Anonymous analytics", accent: .tronSlate, isOn: $analytics)
                        TronSettingsDivider(accent: .tronSlate)
                        TronToggleRow(icon: "exclamationmark.triangle", title: "Anthropic extra-usage warning", accent: .tronSlate, isOn: $anthropicWarning)
                    }
                }
                Button(saving ? "Saving…" : "Save Runtime Settings") { Task { await save() } }
                    .buttonStyle(TronActionButtonStyle(role: .primary))
                    .disabled(saving)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
        }
        .tronScrollEdgeChrome()
        .tronNavigationTitle("Runtime Behavior")
        .task {
            if !allowsProjectScope { scope = "global" }
            await load()
        }
        .onChange(of: scope) { _, _ in Task { await load() } }
        .task(id: model.settingsRevision) { await load() }
    }

    private var scopeGroup: some View {
        TronSettingsGroup("Scope") {
            VStack(spacing: 0) {
                choiceRow("scope", "Settings Scope", scope == "project" ? "Current Project" : "Global Defaults") {
                    Button("Global Defaults") { scope = "global" }
                    if allowsProjectScope { Button("Current Project") { scope = "project" } }
                }
                Text(scope == "project" ? "These overrides apply only to the trusted current workspace." : "These defaults apply to every workspace on this Mac.")
                    .font(TronTypography.bodySM).foregroundStyle(Color.tronTextPrimary).padding(14)
            }
        }
    }

    @ViewBuilder private var toggleRows: some View {
        TronToggleRow(icon: "brain", title: "Hide thinking blocks", isOn: $hideThinking)
        TronSettingsDivider()
        TronToggleRow(icon: "bell", title: "Show cache-miss notices", isOn: $cacheNotices)
        TronSettingsDivider()
        TronToggleRow(icon: "photo", title: "Resize large images", isOn: $resizeImages)
        TronSettingsDivider()
        TronToggleRow(icon: "photo.slash", title: "Block images", isOn: $blockImages)
        TronSettingsDivider()
        TronToggleRow(icon: "command", title: "Enable skill commands", isOn: $skillCommands)
    }

    private func choiceRow<Content: View>(_ icon: String, _ title: String, _ value: String, accent: Color = .tronEmerald, @ViewBuilder choices: () -> Content) -> some View {
        TronValueRow(icon: icon, title: title, accent: accent) {
            TronInlineMenu(value, accent: accent, content: choices)
        }
    }

    private func numberRow(_ icon: String, _ title: String, _ detail: String?, value: Binding<Int>, accent: Color) -> some View {
        TronValueRow(icon: icon, title: title, detail: detail, accent: accent) {
            TextField(title, value: value, format: .number)
                .keyboardType(.numberPad)
                .tronInlineField(monospaced: true)
                .multilineTextAlignment(.trailing)
                .frame(width: 118)
        }
    }

    private var transportLabel: String {
        switch transport { case "sse": "Server-Sent Events"; case "websocket": "WebSocket"; case "websocket-cached": "Cached WebSocket"; default: "Automatic" }
    }
    private func queueLabel(_ value: String) -> String { value == "all" ? "Deliver all" : "One at a time" }

    private func load() async {
        await model.refreshSettings()
        loadFromProjection()
    }

    private func loadFromProjection() {
        guard !saving,
              let root = model.settings?.objectValue,
              let value = root["effective"]?.objectValue else { return }
        transport = value.string("transport", fallback: "auto")
        steeringMode = value.string("steeringMode", fallback: "one-at-a-time")
        followUpMode = value.string("followUpMode", fallback: "one-at-a-time")
        if let compaction = value["compaction"]?.objectValue {
            compactionEnabled = compaction.bool("enabled", fallback: true)
            compactionReserve = compaction.int("reserveTokens", fallback: compactionReserve)
            compactionRecent = compaction.int("keepRecentTokens", fallback: compactionRecent)
        }
        if let branch = value["branchSummary"]?.objectValue {
            branchReserve = branch.int("reserveTokens", fallback: branchReserve)
            branchSkipPrompt = branch.bool("skipPrompt", fallback: false)
        }
        if let retry = value["retry"]?.objectValue {
            retryEnabled = retry.bool("enabled", fallback: true)
            retryCount = retry.int("maxRetries", fallback: retryCount)
            retryDelay = retry.int("baseDelayMs", fallback: retryDelay)
            if let provider = retry["provider"]?.objectValue {
                providerTimeout = provider.int("timeoutMs", fallback: providerTimeout)
                providerRetryCount = provider.int("maxRetries", fallback: providerRetryCount)
                providerRetryDelay = provider.int("maxRetryDelayMs", fallback: providerRetryDelay)
            }
        }
        httpIdleTimeout = value.int("httpIdleTimeoutMs", fallback: httpIdleTimeout)
        websocketTimeout = value.int("websocketConnectTimeoutMs", fallback: websocketTimeout)
        hideThinking = value.bool("hideThinkingBlock", fallback: false)
        cacheNotices = value.bool("showCacheMissNotices", fallback: false)
        if let images = value["images"]?.objectValue {
            resizeImages = images.bool("autoResize", fallback: true)
            blockImages = images.bool("blockImages", fallback: false)
        }
        skillCommands = value.bool("enableSkillCommands", fallback: true)
        if let markdown = value["markdown"]?.objectValue {
            mermaid = markdown.string("mermaid", fallback: "final")
            codeIndent = markdown.string("codeBlockIndent", fallback: "  ")
        }
        if let warnings = value["warnings"]?.objectValue { anthropicWarning = warnings.bool("anthropicExtraUsage", fallback: true) }
        if let telemetry = value["telemetry"]?.objectValue {
            installTelemetry = telemetry.bool("install", fallback: true)
            analytics = telemetry.bool("analytics", fallback: false)
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        let patch: JSONValue = .object([
            "transport": .string(transport),
            "steeringMode": .string(steeringMode),
            "followUpMode": .string(followUpMode),
            "compaction": .object([
                "enabled": .bool(compactionEnabled), "reserveTokens": .number(Double(compactionReserve)),
                "keepRecentTokens": .number(Double(compactionRecent)),
            ]),
            "branchSummary": .object(["reserveTokens": .number(Double(branchReserve)), "skipPrompt": .bool(branchSkipPrompt)]),
            "retry": .object([
                "enabled": .bool(retryEnabled), "maxRetries": .number(Double(retryCount)), "baseDelayMs": .number(Double(retryDelay)),
                "provider": .object([
                    "timeoutMs": .number(Double(providerTimeout)), "maxRetries": .number(Double(providerRetryCount)),
                    "maxRetryDelayMs": .number(Double(providerRetryDelay)),
                ]),
            ]),
            "httpIdleTimeoutMs": .number(Double(httpIdleTimeout)),
            "websocketConnectTimeoutMs": .number(Double(websocketTimeout)),
            "hideThinkingBlock": .bool(hideThinking),
            "showCacheMissNotices": .bool(cacheNotices),
            "images": .object(["autoResize": .bool(resizeImages), "blockImages": .bool(blockImages)]),
            "enableSkillCommands": .bool(skillCommands),
            "markdown": .object(["codeBlockIndent": .string(codeIndent), "mermaid": .string(mermaid)]),
            "warnings": .object(["anthropicExtraUsage": .bool(anthropicWarning)]),
            "enableInstallTelemetry": .bool(installTelemetry),
            "enableAnalytics": .bool(analytics),
        ])
        do { try await model.updateSettings(patch, scope: scope) }
        catch { model.lastError = error.localizedDescription }
    }
}

struct ResourceSettingsView: View {
    private enum Editor: String, Identifiable {
        case extensions, skills, prompts, themes, shellPath, shellPrefix, npmCommand, sessionDir, proxy
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
            case .sessionDir: "Session Storage Directory"
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
            case .sessionDir: "Overrides where canonical session JSONL files are stored. Leave empty to use Tron's standard session location."
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
            case .sessionDir: "~/.pi/agent/sessions"
            case .proxy: "http://127.0.0.1:7890"
            }
        }
        var acceptsMultipleLines: Bool {
            switch self { case .extensions, .skills, .prompts, .themes: true; default: false }
        }
    }

    @Environment(AppModel.self) private var model
    let allowsProjectScope: Bool
    @State private var scope = "global"
    @State private var extensions = ""
    @State private var skills = ""
    @State private var prompts = ""
    @State private var themes = ""
    @State private var shellPath = ""
    @State private var shellPrefix = ""
    @State private var npmCommand = ""
    @State private var sessionDir = ""
    @State private var proxy = ""
    @State private var saving = false
    @State private var editor: Editor?

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(alignment: .leading, spacing: 18) {
                scopeGroup

                Label(
                    "Tron already discovers resources in the standard global and trusted-project folders. Add locations here only when resources live somewhere else.",
                    systemImage: "info.circle"
                )
                .font(TronTypography.bodySM)
                .foregroundStyle(Color.tronTextPrimary)
                .padding(14)
                .tronGlassSurface(accent: .tronCyan, tintOpacity: 0.08)

                TronSettingsGroup("Additional Locations", detail: "Optional paths outside automatic discovery.") {
                    VStack(spacing: 0) {
                        editorRow(.extensions, icon: "shippingbox", value: extensions, accent: .tronPurple)
                        TronSettingsDivider(accent: .tronPurple)
                        editorRow(.skills, icon: "sparkles", value: skills, accent: .tronEmerald)
                        TronSettingsDivider(accent: .tronPurple)
                        editorRow(.prompts, icon: "text.quote", value: prompts, accent: .tronCyan)
                        TronSettingsDivider(accent: .tronPurple)
                        editorRow(.themes, icon: "paintpalette", value: themes, accent: .tronTeal)
                    }
                }

                TronSettingsGroup("Advanced Mac Overrides", detail: "Normally leave these on System Default.", accent: .tronSlate) {
                    VStack(spacing: 0) {
                        editorRow(.shellPath, icon: "terminal", value: shellPath, accent: .tronTeal)
                        TronSettingsDivider(accent: .tronSlate)
                        editorRow(.shellPrefix, icon: "text.insert", value: shellPrefix, accent: .tronTeal)
                        TronSettingsDivider(accent: .tronSlate)
                        editorRow(.npmCommand, icon: "shippingbox.and.arrow.backward", value: npmCommand, accent: .tronPurple)
                        TronSettingsDivider(accent: .tronSlate)
                        editorRow(.sessionDir, icon: "externaldrive", value: sessionDir, accent: .tronCyan)
                        TronSettingsDivider(accent: .tronSlate)
                        editorRow(.proxy, icon: "network", value: proxy, accent: .tronAmber)
                    }
                }

                Button(saving ? "Saving…" : "Save Changes") { Task { await save() } }
                    .buttonStyle(TronActionButtonStyle(role: .primary))
                    .disabled(saving)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
        }
        .scrollDismissesKeyboard(.interactively)
        .tronScrollEdgeChrome()
        .tronNavigationTitle("Resource Locations")
        .task {
            if !allowsProjectScope { scope = "global" }
            await load()
        }
        .onChange(of: scope) { _, _ in Task { await load() } }
        .task(id: model.settingsRevision) { await load() }
        .sheet(item: $editor) { value in editorSheet(value) }
    }

    private var scopeGroup: some View {
        TronSettingsGroup("Applies To") {
            TronValueRow(icon: "scope", title: scope == "project" ? "Current Project" : "Every Project", detail: scopeExplanation) {
                if allowsProjectScope {
                    TronInlineMenu(scope == "project" ? "Project" : "Global") {
                        Button("Every Project") { scope = "global" }
                        Button("Current Project") { scope = "project" }
                    }
                }
            }
        }
    }

    private var scopeExplanation: String {
        scope == "project" ? "Saved in this trusted project's settings." : "Saved as defaults for this Mac."
    }

    private func editorRow(_ value: Editor, icon: String, value text: String, accent: Color) -> some View {
        Button { editor = value } label: {
            TronSettingsRow(icon: icon, title: value.title, subtitle: summary(value, text: text), accent: accent)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens an editor with an explanation and examples")
    }

    private func summary(_ editor: Editor, text: String) -> String {
        if editor == .proxy, text.isEmpty,
           model.settings?.objectValue?["effective"]?.objectValue?["httpProxyConfigured"]?.boolValue == true {
            return "Configured · value hidden"
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
                        .tronGlassSurface(accent: .tronCyan, tintOpacity: 0.08)
                    if value == .proxy {
                        SecureField(value.placeholder, text: binding(for: value))
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .tronField(monospaced: true, compact: true)
                    } else {
                        TextField(value.placeholder, text: binding(for: value), axis: value.acceptsMultipleLines ? .vertical : .horizontal)
                            .lineLimit(value.acceptsMultipleLines ? 3...10 : 1...1)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .tronField(monospaced: true, compact: true)
                    }
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

    private func binding(for editor: Editor) -> Binding<String> {
        Binding {
            switch editor {
            case .extensions: extensions
            case .skills: skills
            case .prompts: prompts
            case .themes: themes
            case .shellPath: shellPath
            case .shellPrefix: shellPrefix
            case .npmCommand: npmCommand
            case .sessionDir: sessionDir
            case .proxy: proxy
            }
        } set: { value in
            switch editor {
            case .extensions: extensions = value
            case .skills: skills = value
            case .prompts: prompts = value
            case .themes: themes = value
            case .shellPath: shellPath = value
            case .shellPrefix: shellPrefix = value
            case .npmCommand: npmCommand = value
            case .sessionDir: sessionDir = value
            case .proxy: proxy = value
            }
        }
    }

    private func load() async {
        await model.refreshSettings(
            cwd: scope == "project" ? model.selectedSnapshot?.cwd : nil,
            useSelectedProject: scope == "project"
        )
        loadFromProjection()
    }

    private func loadFromProjection() {
        guard !saving, editor == nil,
              let root = model.settings?.objectValue,
              let value = root["effective"]?.objectValue else { return }
        shellPath = value["shellPath"]?.stringValue ?? ""
        shellPrefix = value["shellCommandPrefix"]?.stringValue ?? ""
        sessionDir = value["sessionDir"]?.stringValue ?? ""
        npmCommand = (value["npmCommand"]?.arrayValue ?? []).compactMap(\.stringValue).joined(separator: " ")
        proxy = ""
        if let resources = value["resources"]?.objectValue {
            extensions = resources.lines("extensions")
            skills = resources.lines("skills")
            prompts = resources.lines("prompts")
            themes = resources.lines("themes")
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        var patch: [String: JSONValue] = [
            "extensions": .array(lines(extensions).map(JSONValue.string)),
            "skills": .array(lines(skills).map(JSONValue.string)),
            "prompts": .array(lines(prompts).map(JSONValue.string)),
            "themes": .array(lines(themes).map(JSONValue.string)),
            "shellPath": shellPath.isEmpty ? .null : .string(shellPath),
            "shellCommandPrefix": shellPrefix.isEmpty ? .null : .string(shellPrefix),
            "npmCommand": npmCommand.isEmpty ? .null : .array(npmCommand.split(separator: " ").map { .string(String($0)) }),
            "sessionDir": sessionDir.isEmpty ? .null : .string(sessionDir),
        ]
        if !proxy.isEmpty { patch["httpProxy"] = .string(proxy) }
        do { try await model.updateSettings(.object(patch), scope: scope, cwd: scope == "project" ? model.selectedSnapshot?.cwd : nil) }
        catch { model.lastError = error.localizedDescription }
    }

    private func lines(_ value: String) -> [String] {
        value.split(whereSeparator: \.isNewline).map(String.init).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

private extension Dictionary where Key == String, Value == JSONValue {
    func string(_ key: String, fallback: String) -> String { self[key]?.stringValue ?? fallback }
    func int(_ key: String, fallback: Int) -> Int { self[key]?.intValue ?? fallback }
    func bool(_ key: String, fallback: Bool) -> Bool { self[key]?.boolValue ?? fallback }
    func lines(_ key: String) -> String { (self[key]?.arrayValue ?? []).compactMap(\.stringValue).joined(separator: "\n") }
}
