import SwiftUI

struct RuntimeBehaviorDraft: Equatable {
    var transport = "auto"
    var steeringMode = "one-at-a-time"
    var followUpMode = "one-at-a-time"
    var compactionEnabled = true
    var compactionReserve = 16_384
    var compactionRecent = 20_000
    var branchReserve = 16_384
    var branchSkipPrompt = false
    var retryEnabled = true
    var retryCount = 3
    var retryDelay = 1_000
    var providerTimeout = 120_000
    var providerRetryCount = 2
    var providerRetryDelay = 30_000
    var httpIdleTimeout = 300_000
    var websocketTimeout = 10_000
    var hideThinking = false
    var cacheNotices = false
    var resizeImages = true
    var blockImages = false
    var skillCommands = true
    var installTelemetry = true
    var analytics = false
    var mermaid = "final"
    var codeIndent = "  "
    var anthropicWarning = true

    func patch(comparedTo baseline: Self) -> JSONValue {
        var patch: [String: JSONValue] = [:]
        if transport != baseline.transport { patch["transport"] = .string(transport) }
        if steeringMode != baseline.steeringMode { patch["steeringMode"] = .string(steeringMode) }
        if followUpMode != baseline.followUpMode { patch["followUpMode"] = .string(followUpMode) }
        var compaction: [String: JSONValue] = [:]
        if compactionEnabled != baseline.compactionEnabled { compaction["enabled"] = .bool(compactionEnabled) }
        if compactionReserve != baseline.compactionReserve { compaction["reserveTokens"] = .number(Double(compactionReserve)) }
        if compactionRecent != baseline.compactionRecent { compaction["keepRecentTokens"] = .number(Double(compactionRecent)) }
        if !compaction.isEmpty { patch["compaction"] = .object(compaction) }
        var branch: [String: JSONValue] = [:]
        if branchReserve != baseline.branchReserve { branch["reserveTokens"] = .number(Double(branchReserve)) }
        if branchSkipPrompt != baseline.branchSkipPrompt { branch["skipPrompt"] = .bool(branchSkipPrompt) }
        if !branch.isEmpty { patch["branchSummary"] = .object(branch) }
        var retry: [String: JSONValue] = [:]
        if retryEnabled != baseline.retryEnabled { retry["enabled"] = .bool(retryEnabled) }
        if retryCount != baseline.retryCount { retry["maxRetries"] = .number(Double(retryCount)) }
        if retryDelay != baseline.retryDelay { retry["baseDelayMs"] = .number(Double(retryDelay)) }
        var provider: [String: JSONValue] = [:]
        if providerTimeout != baseline.providerTimeout { provider["timeoutMs"] = .number(Double(providerTimeout)) }
        if providerRetryCount != baseline.providerRetryCount { provider["maxRetries"] = .number(Double(providerRetryCount)) }
        if providerRetryDelay != baseline.providerRetryDelay { provider["maxRetryDelayMs"] = .number(Double(providerRetryDelay)) }
        if !provider.isEmpty { retry["provider"] = .object(provider) }
        if !retry.isEmpty { patch["retry"] = .object(retry) }
        if httpIdleTimeout != baseline.httpIdleTimeout { patch["httpIdleTimeoutMs"] = .number(Double(httpIdleTimeout)) }
        if websocketTimeout != baseline.websocketTimeout { patch["websocketConnectTimeoutMs"] = .number(Double(websocketTimeout)) }
        if hideThinking != baseline.hideThinking { patch["hideThinkingBlock"] = .bool(hideThinking) }
        if cacheNotices != baseline.cacheNotices { patch["showCacheMissNotices"] = .bool(cacheNotices) }
        var images: [String: JSONValue] = [:]
        if resizeImages != baseline.resizeImages { images["autoResize"] = .bool(resizeImages) }
        if blockImages != baseline.blockImages { images["blockImages"] = .bool(blockImages) }
        if !images.isEmpty { patch["images"] = .object(images) }
        if skillCommands != baseline.skillCommands { patch["enableSkillCommands"] = .bool(skillCommands) }
        var markdown: [String: JSONValue] = [:]
        if codeIndent != baseline.codeIndent { markdown["codeBlockIndent"] = .string(codeIndent) }
        if mermaid != baseline.mermaid { markdown["mermaid"] = .string(mermaid) }
        if !markdown.isEmpty { patch["markdown"] = .object(markdown) }
        if anthropicWarning != baseline.anthropicWarning {
            patch["warnings"] = .object(["anthropicExtraUsage": .bool(anthropicWarning)])
        }
        if installTelemetry != baseline.installTelemetry { patch["enableInstallTelemetry"] = .bool(installTelemetry) }
        if analytics != baseline.analytics { patch["enableAnalytics"] = .bool(analytics) }
        return .object(patch)
    }
}

struct RuntimeBehaviorSettingsView: View {
    @Environment(AppModel.self) private var model
    let projectCWD: String?
    @State private var scope: SettingsScope = .global
    @State private var draft = RuntimeBehaviorDraft()
    @State private var drafts = ScopedSettingsDraftStore<RuntimeBehaviorDraft>()
    @State private var saving = false

    private var allowsProjectScope: Bool { projectCWD != nil }

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(alignment: .leading, spacing: 18) {
                scopeGroup
                TronSettingsGroup("Provider Transport", accent: .tronCyan) {
                    VStack(spacing: 0) {
                        choiceRow("network", "Transport", transportLabel, accent: .tronCyan) {
                            Button("Automatic") { draft.transport = "auto" }
                            Button("Server-Sent Events") { draft.transport = "sse" }
                            Button("WebSocket") { draft.transport = "websocket" }
                            Button("Cached WebSocket") { draft.transport = "websocket-cached" }
                        }
                        TronSettingsDivider(accent: .tronCyan)
                        numberRow("timer", "HTTP idle timeout", "Milliseconds", value: $draft.httpIdleTimeout, accent: .tronCyan)
                        TronSettingsDivider(accent: .tronCyan)
                        numberRow("bolt.horizontal", "WebSocket timeout", "Milliseconds", value: $draft.websocketTimeout, accent: .tronCyan)
                    }
                }
                TronSettingsGroup("Message Queue", accent: .tronPurple) {
                    VStack(spacing: 0) {
                        choiceRow("arrow.turn.up.right", "Steering delivery", queueLabel(draft.steeringMode), accent: .tronPurple) {
                            Button("Deliver all") { draft.steeringMode = "all" }
                            Button("One at a time") { draft.steeringMode = "one-at-a-time" }
                        }
                        TronSettingsDivider(accent: .tronPurple)
                        choiceRow("clock.arrow.circlepath", "Follow-up delivery", queueLabel(draft.followUpMode), accent: .tronPurple) {
                            Button("Deliver all") { draft.followUpMode = "all" }
                            Button("One at a time") { draft.followUpMode = "one-at-a-time" }
                        }
                    }
                }
                TronSettingsGroup("Compaction", accent: .tronTeal) {
                    VStack(spacing: 0) {
                        TronToggleRow(icon: "arrow.triangle.2.circlepath", title: "Automatic compaction", accent: .tronTeal, isOn: $draft.compactionEnabled)
                        TronSettingsDivider(accent: .tronTeal)
                        numberRow("gauge.with.dots.needle.33percent", "Reserve tokens", nil, value: $draft.compactionReserve, accent: .tronTeal)
                        TronSettingsDivider(accent: .tronTeal)
                        numberRow("text.line.last.and.arrowtriangle.forward", "Keep recent tokens", nil, value: $draft.compactionRecent, accent: .tronTeal)
                        TronSettingsDivider(accent: .tronTeal)
                        numberRow("arrow.triangle.branch", "Branch summary reserve", nil, value: $draft.branchReserve, accent: .tronTeal)
                        TronSettingsDivider(accent: .tronTeal)
                        TronToggleRow(icon: "text.bubble", title: "Skip branch-summary prompt", accent: .tronTeal, isOn: $draft.branchSkipPrompt)
                    }
                }
                TronSettingsGroup("Retry", accent: .tronAmber) {
                    VStack(spacing: 0) {
                        TronToggleRow(icon: "arrow.clockwise", title: "Automatic retry", accent: .tronAmber, isOn: $draft.retryEnabled)
                        TronSettingsDivider(accent: .tronAmber)
                        numberRow("number", "Agent retry count", nil, value: $draft.retryCount, accent: .tronAmber)
                        TronSettingsDivider(accent: .tronAmber)
                        numberRow("timer", "Base delay", "Milliseconds", value: $draft.retryDelay, accent: .tronAmber)
                        TronSettingsDivider(accent: .tronAmber)
                        numberRow("hourglass", "Provider timeout", "Milliseconds", value: $draft.providerTimeout, accent: .tronAmber)
                        TronSettingsDivider(accent: .tronAmber)
                        numberRow("number", "Provider retry count", nil, value: $draft.providerRetryCount, accent: .tronAmber)
                        TronSettingsDivider(accent: .tronAmber)
                        numberRow("timer", "Maximum provider delay", "Milliseconds", value: $draft.providerRetryDelay, accent: .tronAmber)
                    }
                }
                TronSettingsGroup("Conversation") {
                    VStack(spacing: 0) {
                        toggleRows
                    }
                }
                TronSettingsGroup("Markdown", accent: .tronPurple) {
                    VStack(spacing: 0) {
                        choiceRow("flowchart", "Mermaid diagrams", draft.mermaid.capitalized, accent: .tronPurple) {
                            Button("Off") { draft.mermaid = "off" }
                            Button("Completed responses") { draft.mermaid = "final" }
                            Button("While streaming") { draft.mermaid = "streaming" }
                        }
                        TronSettingsDivider(accent: .tronPurple)
                        TronValueRow(icon: "chevron.left.forwardslash.chevron.right", title: "Code block indent", accent: .tronPurple) {
                            TextField("Indent", text: $draft.codeIndent)
                                .tronInlineField(monospaced: true)
                                .frame(width: 100)
                        }
                    }
                }
                TronSettingsGroup("Privacy and Warnings", accent: .tronSlate) {
                    VStack(spacing: 0) {
                        TronToggleRow(icon: "chart.bar", title: "Installation telemetry", accent: .tronSlate, isOn: $draft.installTelemetry)
                        TronSettingsDivider(accent: .tronSlate)
                        TronToggleRow(icon: "waveform.path.ecg", title: "Anonymous analytics", accent: .tronSlate, isOn: $draft.analytics)
                        TronSettingsDivider(accent: .tronSlate)
                        TronToggleRow(icon: "exclamationmark.triangle", title: "Anthropic extra-usage warning", accent: .tronSlate, isOn: $draft.anthropicWarning)
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
        .task(id: SettingsLoadID(target: settingsTarget, invalidationGeneration: model.settingsInvalidationGeneration)) {
            if !allowsProjectScope { scope = .global }
            await load()
        }
        .onChange(of: draft) { _, value in
            if let target = settingsTarget { drafts.update(value, for: target) }
        }
    }

    private var scopeGroup: some View {
        TronSettingsGroup("Scope") {
            VStack(spacing: 0) {
                choiceRow("scope", "Settings Scope", scope == .project ? "Current Project" : "Global Defaults") {
                    Button("Global Defaults") { selectScope(.global) }
                    if allowsProjectScope { Button("Current Project") { selectScope(.project) } }
                }
                Text(scope == .project ? "These overrides apply only to the trusted current workspace." : "These defaults apply to every workspace on this Mac.")
                    .font(TronTypography.bodySM).foregroundStyle(Color.tronTextPrimary).padding(14)
            }
        }
    }

    @ViewBuilder private var toggleRows: some View {
        TronToggleRow(icon: "brain", title: "Hide thinking blocks", isOn: $draft.hideThinking)
        TronSettingsDivider()
        TronToggleRow(icon: "bell", title: "Show cache-miss notices", isOn: $draft.cacheNotices)
        TronSettingsDivider()
        TronToggleRow(icon: "photo", title: "Resize large images", isOn: $draft.resizeImages)
        TronSettingsDivider()
        TronToggleRow(icon: "photo.slash", title: "Block images", isOn: $draft.blockImages)
        TronSettingsDivider()
        TronToggleRow(icon: "command", title: "Enable skill commands", isOn: $draft.skillCommands)
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
        switch draft.transport { case "sse": "Server-Sent Events"; case "websocket": "WebSocket"; case "websocket-cached": "Cached WebSocket"; default: "Automatic" }
    }
    private func queueLabel(_ value: String) -> String { value == "all" ? "Deliver all" : "One at a time" }

    private var settingsTarget: SettingsTarget? {
        SettingsTarget(scope: scope, projectCWD: projectCWD)
    }

    private func selectScope(_ newScope: SettingsScope) {
        guard newScope != scope,
              let newTarget = SettingsTarget(scope: newScope, projectCWD: projectCWD) else { return }
        let nextDraft = drafts.draftForScopeSwitch(
            current: draft,
            from: settingsTarget,
            to: newTarget,
            default: RuntimeBehaviorDraft()
        )
        scope = newScope
        draft = nextDraft
    }

    private func load() async {
        guard let target = settingsTarget,
              await model.refreshSettings(target: target),
              target == settingsTarget,
              let loaded = projectionDraft(target: target),
              drafts.install(loaded, for: target) else { return }
        draft = loaded
    }

    private func projectionDraft(target: SettingsTarget) -> RuntimeBehaviorDraft? {
        guard let root = model.settings(for: target)?.objectValue,
              let value = root["effective"]?.objectValue else { return nil }
        var loaded = RuntimeBehaviorDraft()
        loaded.transport = value.string("transport", fallback: loaded.transport)
        loaded.steeringMode = value.string("steeringMode", fallback: loaded.steeringMode)
        loaded.followUpMode = value.string("followUpMode", fallback: loaded.followUpMode)
        if let compaction = value["compaction"]?.objectValue {
            loaded.compactionEnabled = compaction.bool("enabled", fallback: loaded.compactionEnabled)
            loaded.compactionReserve = compaction.int("reserveTokens", fallback: loaded.compactionReserve)
            loaded.compactionRecent = compaction.int("keepRecentTokens", fallback: loaded.compactionRecent)
        }
        if let branch = value["branchSummary"]?.objectValue {
            loaded.branchReserve = branch.int("reserveTokens", fallback: loaded.branchReserve)
            loaded.branchSkipPrompt = branch.bool("skipPrompt", fallback: loaded.branchSkipPrompt)
        }
        if let retry = value["retry"]?.objectValue {
            loaded.retryEnabled = retry.bool("enabled", fallback: loaded.retryEnabled)
            loaded.retryCount = retry.int("maxRetries", fallback: loaded.retryCount)
            loaded.retryDelay = retry.int("baseDelayMs", fallback: loaded.retryDelay)
            if let provider = retry["provider"]?.objectValue {
                loaded.providerTimeout = provider.int("timeoutMs", fallback: loaded.providerTimeout)
                loaded.providerRetryCount = provider.int("maxRetries", fallback: loaded.providerRetryCount)
                loaded.providerRetryDelay = provider.int("maxRetryDelayMs", fallback: loaded.providerRetryDelay)
            }
        }
        loaded.httpIdleTimeout = value.int("httpIdleTimeoutMs", fallback: loaded.httpIdleTimeout)
        loaded.websocketTimeout = value.int("websocketConnectTimeoutMs", fallback: loaded.websocketTimeout)
        loaded.hideThinking = value.bool("hideThinkingBlock", fallback: loaded.hideThinking)
        loaded.cacheNotices = value.bool("showCacheMissNotices", fallback: loaded.cacheNotices)
        if let images = value["images"]?.objectValue {
            loaded.resizeImages = images.bool("autoResize", fallback: loaded.resizeImages)
            loaded.blockImages = images.bool("blockImages", fallback: loaded.blockImages)
        }
        loaded.skillCommands = value.bool("enableSkillCommands", fallback: loaded.skillCommands)
        if let markdown = value["markdown"]?.objectValue {
            loaded.mermaid = markdown.string("mermaid", fallback: loaded.mermaid)
            loaded.codeIndent = markdown.string("codeBlockIndent", fallback: loaded.codeIndent)
        }
        if let warnings = value["warnings"]?.objectValue {
            loaded.anthropicWarning = warnings.bool("anthropicExtraUsage", fallback: loaded.anthropicWarning)
        }
        if let telemetry = value["telemetry"]?.objectValue {
            loaded.installTelemetry = telemetry.bool("install", fallback: loaded.installTelemetry)
            loaded.analytics = telemetry.bool("analytics", fallback: loaded.analytics)
        }
        return loaded
    }

    private func save() async {
        guard let target = settingsTarget else { return }
        drafts.update(draft, for: target)
        guard let savingRevision = drafts.revision(for: target) else { return }
        let savingDraft = draft
        saving = true
        defer { saving = false }
        let baseline = drafts.baseline(for: target) ?? RuntimeBehaviorDraft()
        let patch = savingDraft.patch(comparedTo: baseline)
        do {
            try await model.updateSettings(patch, target: target)
            guard target == settingsTarget else { return }
            _ = drafts.markSaved(
                savingDraft,
                for: target,
                expectedRevision: savingRevision
            )
        }
        catch { model.lastError = error.localizedDescription }
    }
}
