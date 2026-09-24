import SwiftUI

struct AgentDefaultsDraft: Equatable {
    var transport = "auto"
    var steeringMode = "one-at-a-time"
    var followUpMode = "one-at-a-time"
    var retryEnabled = true
    var selectedModel: ModelRef?
    var thinking = "medium"
    var modelContextWindows: [String: Int] = [:]
    var inheritedModelContextWindows: [String: Int] = [:]
    var contextWindowMinimum: Int?
    var retryCount = 3
    var retryDelay = 1_000
    var providerTimeout = 120_000
    var providerRetryCount = 2
    var providerRetryDelay = 30_000
    var httpIdleTimeout = 300_000
    var websocketTimeout = 10_000
    var resizeImages = true
    var blockImages = false
    var providerAttribution = true

    func patch(comparedTo baseline: Self) -> JSONValue {
        var patch: [String: JSONValue] = [:]
        if transport != baseline.transport { patch["transport"] = .string(transport) }
        if steeringMode != baseline.steeringMode { patch["steeringMode"] = .string(steeringMode) }
        if followUpMode != baseline.followUpMode { patch["followUpMode"] = .string(followUpMode) }
        if thinking != baseline.thinking { patch["defaultThinkingLevel"] = .string(thinking) }
        if selectedModel != baseline.selectedModel {
            if let selectedModel {
                patch["defaultModel"] = .object(["provider": .string(selectedModel.provider), "id": .string(selectedModel.id)])
            } else {
                patch["defaultModel"] = .null
            }
        }
        let contextKeys = Set(modelContextWindows.keys).union(baseline.modelContextWindows.keys)
        var contextPatch: [String: JSONValue] = [:]
        for key in contextKeys {
            if let value = modelContextWindows[key], baseline.modelContextWindows[key] != value {
                contextPatch[key] = .number(Double(value))
            } else if modelContextWindows[key] == nil, baseline.modelContextWindows[key] != nil {
                contextPatch[key] = .null
            }
        }
        if !contextPatch.isEmpty { patch["modelContextWindows"] = .object(contextPatch) }
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
        var images: [String: JSONValue] = [:]
        if resizeImages != baseline.resizeImages { images["autoResize"] = .bool(resizeImages) }
        if blockImages != baseline.blockImages { images["blockImages"] = .bool(blockImages) }
        if !images.isEmpty { patch["images"] = .object(images) }
        if providerAttribution != baseline.providerAttribution { patch["enableInstallTelemetry"] = .bool(providerAttribution) }
        return .object(patch)
    }
}

struct AgentDefaultsSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.tronPresentationActivity) private var presentationActivity
    let projectCWD: String?
    let projectSessionID: String?
    @State private var scope: SettingsScope = .global
    @State private var draft = AgentDefaultsDraft()
    @State private var drafts = ScopedSettingsDraftStore<AgentDefaultsDraft>()
    @State private var loadGeneration = 0
    @State private var sliderPresentation = ConfigurationSliderPresentation()

    private var allowsProjectScope: Bool { projectCWD != nil }

    init(projectCWD: String?, projectSessionID: String? = nil) {
        self.projectCWD = projectCWD
        self.projectSessionID = projectSessionID
    }

    var body: some View {
        let editing = editBinding
        return ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(alignment: .leading, spacing: 18) {
                scopeGroup
                modelDefaultsSection
                if let target = settingsTarget { SettingsAutosaveNotice(key: .settings(target, sessionID: target.scope == .project ? projectSessionID : nil)) }
                TronSettingsGroup("Message Queue", accent: .tronPurple, surfaceStyle: .glass) {
                    VStack(spacing: 0) {
                        choiceRow("arrow.turn.up.right", "Steering delivery", queueLabel(draft.steeringMode), accent: .tronPurple) {
                            Button("Deliver all") { editing.update { $0.steeringMode = "all" } }
                            Button("One at a time") { editing.update { $0.steeringMode = "one-at-a-time" } }
                        }
                        TronSettingsDivider(accent: .tronPurple)
                        choiceRow("clock.arrow.circlepath", "Follow-up delivery", queueLabel(draft.followUpMode), accent: .tronPurple) {
                            Button("Deliver all") { editing.update { $0.followUpMode = "all" } }
                            Button("One at a time") { editing.update { $0.followUpMode = "one-at-a-time" } }
                        }
                    }
                }
                TronSettingsGroup("Image Input", accent: .tronTeal, surfaceStyle: .glass) {
                    VStack(spacing: 0) {
                        TronToggleRow(icon: "photo", title: "Resize large images", detail: "Reduce oversized images before upload", accent: .tronTeal, isOn: editing.resizeImages)
                        TronSettingsDivider(accent: .tronTeal)
                        TronToggleRow(icon: "photo.slash", title: "Block images", detail: "Prevent image input from reaching providers", accent: .tronTeal, isOn: editing.blockImages)
                    }
                }
                TronSettingsGroup("Retry", accent: .tronAmber, surfaceStyle: .glass) {
                    VStack(spacing: 0) {
                        TronToggleRow(
                            icon: "arrow.clockwise",
                            title: "Automatic retry",
                            detail: "Retry transient request failures",
                            accent: .tronAmber,
                            isOn: editing.retryEnabled
                        )
                        TronSettingsDivider(accent: .tronAmber)
                        numberRow("number", "Agent retry count", "Maximum retries for agent requests", value: editing.retryCount, accent: .tronAmber)
                        TronSettingsDivider(accent: .tronAmber)
                        numberRow("timer", "Base delay", "Initial delay in milliseconds", value: editing.retryDelay, accent: .tronAmber)
                        TronSettingsDivider(accent: .tronAmber)
                        numberRow("hourglass", "Provider timeout", "Request timeout in milliseconds", value: editing.providerTimeout, accent: .tronAmber)
                        TronSettingsDivider(accent: .tronAmber)
                        numberRow("number", "Provider retry count", "Maximum retries for provider requests", value: editing.providerRetryCount, accent: .tronAmber)
                        TronSettingsDivider(accent: .tronAmber)
                        numberRow("timer", "Maximum provider delay", "Delay cap in milliseconds", value: editing.providerRetryDelay, accent: .tronAmber)
                    }
                }
                TronSettingsGroup("Provider Transport", accent: .tronCyan, surfaceStyle: .glass) {
                    VStack(spacing: 0) {
                        choiceRow("network", "Transport", transportLabel, accent: .tronCyan) {
                            Button("Automatic") { editing.update { $0.transport = "auto" } }
                            Button("Server-Sent Events") { editing.update { $0.transport = "sse" } }
                            Button("WebSocket") { editing.update { $0.transport = "websocket" } }
                            Button("Cached WebSocket") { editing.update { $0.transport = "websocket-cached" } }
                        }
                        TronSettingsDivider(accent: .tronCyan)
                        numberRow("timer", "HTTP idle timeout", "Milliseconds", value: editing.httpIdleTimeout, accent: .tronCyan)
                        TronSettingsDivider(accent: .tronCyan)
                        numberRow("bolt.horizontal", "WebSocket timeout", "Milliseconds", value: editing.websocketTimeout, accent: .tronCyan)
                        TronSettingsDivider(accent: .tronCyan)
                        // The SDK's install-telemetry setting only gates provider
                        // attribution headers in Tron; its terminal install ping never runs.
                        TronToggleRow(
                            icon: "tag",
                            title: "Provider attribution",
                            detail: "Send Pi attribution headers to OpenRouter, NVIDIA, and Cloudflare",
                            accent: .tronCyan,
                            isOn: editing.providerAttribution
                        )
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
        }
        .tronScrollEdgeChrome()
        .tronConfigurationSliderHost(sliderPresentation)
        .environment(\.configurationSliderSignposts, model.performanceSignpostsForCapture)
        .tronNavigationTitle("Agent Defaults")
        .tronSettingsAutosave(draft: $draft, store: $drafts, initial: AgentDefaultsDraft())
        .task(id: PresentationActivityTaskID(
            source: AgentDefaultsLoadID(
                settingsTarget: settingsTarget,
                providerTarget: catalogTarget,
                settingsInvalidationGeneration: model.settingsInvalidationGeneration,
                providerInvalidationGeneration: model.providerInvalidationGeneration,
                foregroundGeneration: model.foregroundReconciliationGeneration
            ),
            presentationActive: presentationActivity.allowsPresentationPublication
        )) {
            guard presentationActivity.allowsPresentationPublication else { return }
            if !allowsProjectScope { scope = .global }
            await load()
        }

    }

    private var modelDefaultsSection: some View {
        let editing = editBinding
        return VStack(alignment: .leading, spacing: 18) {
            TronSettingsGroup(
                "Model Defaults",
                detail: "Defaults apply to new sessions; existing sessions keep their current runtime.",
                accent: .tronPurple,
                surfaceStyle: .glass
            ) {
                VStack(spacing: 0) {
                    TronModelSelectionRow(
                        selection: editing.selectedModel,
                        models: availableModels,
                        navigationTitle: "Models"
                    )
                    TronSettingsDivider(accent: .tronPurple)
                    TronThinkingSelectionRow(
                        selection: editing.thinking,
                        levels: ["off", "minimal", "low", "medium", "high", "xhigh", "max"],
                        information: "Reasoning effort; higher levels can take longer"
                    )
                    .id(settingsTarget)
                    if model.gatewayInfo?.capabilities.contains("context-window.v1") == true,
                       let selectedModel = selectedModelSummary,
                       let limits = selectedContextWindowLimits {
                        TronSettingsDivider(accent: .tronPurple)
                        ContextWindowSelectionRow(
                            selection: contextWindowBinding(for: selectedModel),
                            limits: limits,
                            inheritedValue: draft.inheritedModelContextWindows[selectedModel.ref.contextWindowKey],
                            resetLabel: scope == .project ? "Use inherited default" : "Use model default",
                            information: "Conversation capacity for new sessions"
                        )
                        .id("\(scope.rawValue):\(selectedModel.ref.contextWindowKey)")
                    }
                }
            }
        }
    }

    private var catalogTarget: ProviderCatalogTarget {
        scope == .project
            ? projectSessionID.map(ProviderCatalogTarget.session(id:)) ?? .global
            : .global
    }

    private var availableModels: [ModelSummary] {
        model.providerCatalog(for: catalogTarget)?.models.filter(\.available) ?? []
    }

    private var selectedModelSummary: ModelSummary? {
        guard let selected = draft.selectedModel else { return nil }
        return availableModels.first { $0.ref == selected }
    }

    private var selectedContextWindowLimits: ContextWindowLimits? {
        selectedModelSummary?.contextWindowLimits?.withMinimum(draft.contextWindowMinimum)
    }

    private var scopeGroup: some View {
        TronSettingsGroup(
            "Scope",
            detail: scope == .project
                ? "These overrides apply only to the trusted current workspace."
                : "These defaults apply to every workspace on this Mac.",
            surfaceStyle: .glass
        ) {
            if allowsProjectScope {
                choiceRow("scope", "Settings Scope", scope == .project ? "Current Project" : "Global Defaults") {
                    Button("Global Defaults") { selectScope(.global) }
                    Button("Current Project") { selectScope(.project) }
                }
            } else {
                TronValueRow(
                    icon: "scope",
                    title: "Settings Scope",
                    value: "Global Defaults"
                )
            }
        }
    }

    private func choiceRow<Content: View>(_ icon: String, _ title: String, _ value: String, accent: Color = .tronEmerald, @ViewBuilder choices: @escaping () -> Content) -> some View {
        TronSelectionRow(icon: icon, title: title, value: value, accent: accent, choices: choices)
    }

    private func numberRow(_ icon: String, _ title: String, _ detail: String?, value: Binding<Int>, accent: Color) -> some View {
        TronNumberSettingRow(icon: icon, title: title, detail: detail, value: value, accent: accent)
    }

    private var transportLabel: String {
        switch draft.transport { case "sse": "Server-Sent Events"; case "websocket": "WebSocket"; case "websocket-cached": "Cached WebSocket"; default: "Automatic" }
    }
    private func queueLabel(_ value: String) -> String { value == "all" ? "Deliver all" : "One at a time" }

    private var settingsTarget: SettingsTarget? {
        SettingsTarget(scope: scope, projectCWD: projectCWD)
    }

    private var editBinding: Binding<AgentDefaultsDraft> {
        let target = settingsTarget
        return SettingsAutosave.binding(draft: $draft, store: $drafts, model: model, target: target,
            sessionID: target?.scope == .project ? projectSessionID : nil,
            admits: { target == settingsTarget && presentationActivity.allowsDataPublication },
            patch: { $0.patch(comparedTo: $1) })
    }

    private func contextWindowBinding(for modelSummary: ModelSummary) -> Binding<Int?> {
        let editing = editBinding
        return Binding(
            get: { editing.wrappedValue.modelContextWindows[modelSummary.ref.contextWindowKey] },
            set: { value in editing.update { $0.modelContextWindows[modelSummary.ref.contextWindowKey] = value } }
        )
    }

    private func selectScope(_ newScope: SettingsScope) {
        guard newScope != scope,
              let newTarget = SettingsTarget(scope: newScope, projectCWD: projectCWD) else { return }
        let nextDraft = drafts.draftForScopeSwitch(
            current: draft,
            from: settingsTarget,
            to: newTarget,
            default: AgentDefaultsDraft()
        )
        scope = newScope
        draft = nextDraft
    }

    private func load() async {
        let foreground = model.foregroundReconciliationGeneration
        let identity = model.knowledgePresentationIdentity
        loadGeneration &+= 1
        let ticket = loadGeneration
        guard let target = settingsTarget else { return }
        // Installing a projection never submits an autosave; a user edit made
        // while this read is pending still rejects its stale result.
        _ = drafts.seedBaselineIfMissing(draft, for: target)
        let requestedCatalogTarget = catalogTarget
        async let settingsReady = model.refreshSettings(target: target)
        async let catalogReady = model.refreshProviders(target: requestedCatalogTarget)
        let loadedSettings = await settingsReady
        _ = await catalogReady
        guard loadedSettings,
              ticket == loadGeneration,
              identity == model.knowledgePresentationIdentity,
              foreground == model.foregroundReconciliationGeneration,
              presentationActivity.allowsPresentationPublication,
              !Task.isCancelled,
              target == settingsTarget,
              requestedCatalogTarget == catalogTarget,
              let loaded = projectionDraft(target: target, catalogTarget: requestedCatalogTarget),
              drafts.install(loaded, for: target, ifCurrent: draft) else { return }
        draft = loaded
    }

    private func projectionDraft(target: SettingsTarget, catalogTarget: ProviderCatalogTarget) -> AgentDefaultsDraft? {
        guard let root = model.settings(for: target)?.objectValue,
              let value = root["effective"]?.objectValue else { return nil }
        var loaded = AgentDefaultsDraft()
        if let object = value["defaultModel"]?.objectValue,
           let provider = object["provider"]?.stringValue,
           let id = object["id"]?.stringValue {
            loaded.selectedModel = ModelRef(provider: provider, id: id)
        } else {
            loaded.selectedModel = model.preferredAvailableModel(for: catalogTarget)
        }
        loaded.thinking = value["defaultThinkingLevel"]?.stringValue ?? loaded.thinking
        if let scopeDocument = root["documents"]?.objectValue?[target.scope.rawValue]?.objectValue {
            loaded.modelContextWindows = Self.contextWindows(scopeDocument["modelContextWindows"])
        }
        if target.scope == .project,
           let globalDocument = root["documents"]?.objectValue?["global"]?.objectValue {
            loaded.inheritedModelContextWindows = Self.contextWindows(globalDocument["modelContextWindows"])
        }
        loaded.contextWindowMinimum = value["contextWindowMinimum"]?.intValue
        loaded.transport = value.string("transport", fallback: loaded.transport)
        loaded.steeringMode = value.string("steeringMode", fallback: loaded.steeringMode)
        loaded.followUpMode = value.string("followUpMode", fallback: loaded.followUpMode)
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
        if let images = value["images"]?.objectValue {
            loaded.resizeImages = images.bool("autoResize", fallback: loaded.resizeImages)
            loaded.blockImages = images.bool("blockImages", fallback: loaded.blockImages)
        }
        if let telemetry = value["telemetry"]?.objectValue {
            loaded.providerAttribution = telemetry.bool("install", fallback: loaded.providerAttribution)
        }
        return loaded
    }

    private static func contextWindows(_ value: JSONValue?) -> [String: Int] {
        guard let object = value?.objectValue else { return [:] }
        return object.compactMapValues { value in
            guard let number = value.intValue, number > 0 else { return nil }
            return number
        }
    }

}
