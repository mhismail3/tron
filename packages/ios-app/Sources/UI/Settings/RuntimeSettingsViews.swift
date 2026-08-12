import SwiftUI

struct RuntimeBehaviorSettingsView: View {
    @Environment(AppModel.self) private var model
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
        .scrollEdgeEffectStyle(.soft, for: .all)
        .tronNavigationTitle("Runtime Behavior")
        .task { await load() }
        .onChange(of: scope) { _, _ in Task { await load() } }
    }

    private var scopeGroup: some View {
        TronSettingsGroup("Scope") {
            VStack(spacing: 0) {
                choiceRow("scope", "Settings Scope", scope == "project" ? "Current Project" : "Global Defaults") {
                    Button("Global Defaults") { scope = "global" }
                    Button("Current Project") { scope = "project" }.disabled(model.selectedSnapshot == nil)
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
        guard let root = model.settings?.objectValue,
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
    @Environment(AppModel.self) private var model
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

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(alignment: .leading, spacing: 18) {
                TronSettingsGroup("Scope") {
                    VStack(spacing: 0) {
                        TronValueRow(icon: "scope", title: "Settings Scope") {
                            TronInlineMenu(scope == "project" ? "Current Project" : "Global Defaults") {
                                Button("Global Defaults") { scope = "global" }
                                Button("Current Project") { scope = "project" }
                                    .disabled(model.selectedSnapshot == nil)
                            }
                        }
                        TronSettingsDivider()
                        Text(scope == "project"
                             ? "These overrides apply only to the trusted current workspace."
                             : "These defaults apply to every workspace on this Mac.")
                            .font(TronTypography.caption)
                            .foregroundStyle(Color.tronTextSecondary)
                            .padding(12)
                    }
                }

                TronSettingsGroup(
                    "Resource Paths",
                    detail: "Enter one path per line. Project paths load only after the workspace is trusted."
                ) {
                    VStack(spacing: 0) {
                        multiline("Extensions", text: $extensions)
                        TronSettingsDivider()
                        multiline("Skills", text: $skills)
                        TronSettingsDivider()
                        multiline("Prompt templates", text: $prompts)
                        TronSettingsDivider()
                        multiline("Themes (terminal only)", text: $themes)
                    }
                    .padding(12)
                }

                TronSettingsGroup("Mac Runtime", accent: .tronTeal) {
                    VStack(spacing: 12) {
                        TextField("Shell path", text: $shellPath).textInputAutocapitalization(.never).autocorrectionDisabled()
                            .tronField(monospaced: true, compact: true)
                        TextField("Shell command prefix", text: $shellPrefix).textInputAutocapitalization(.never).autocorrectionDisabled()
                            .tronField(monospaced: true, compact: true)
                        TextField("npm command", text: $npmCommand).textInputAutocapitalization(.never).autocorrectionDisabled()
                            .tronField(monospaced: true, compact: true)
                        TextField("Session directory", text: $sessionDir).textInputAutocapitalization(.never).autocorrectionDisabled()
                            .tronField(monospaced: true, compact: true)
                        SecureField("HTTP proxy (write only)", text: $proxy).textInputAutocapitalization(.never).autocorrectionDisabled()
                            .tronField(monospaced: true, compact: true)
                    }
                    .padding(12)
                }

                Button(saving ? "Saving…" : "Save Resource Settings") { Task { await save() } }
                    .buttonStyle(TronActionButtonStyle(role: .primary))
                    .disabled(saving)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 40)
        }
        .scrollEdgeEffectStyle(.soft, for: .all)
        .tronNavigationTitle("Resource Paths")
        .task { await load() }
        .onChange(of: scope) { _, _ in Task { await load() } }
    }

    @ViewBuilder
    private func multiline(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(TronTypography.caption).foregroundStyle(Color.tronTextSecondary)
            TextField(title, text: text, axis: .vertical).lineLimit(2...6)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .tronField(monospaced: true, compact: true)
        }
    }

    private func load() async {
        await model.refreshSettings()
        guard let root = model.settings?.objectValue,
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
        do { try await model.updateSettings(.object(patch), scope: scope) }
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
