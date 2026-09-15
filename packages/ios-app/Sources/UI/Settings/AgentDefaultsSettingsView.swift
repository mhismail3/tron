import SwiftUI

struct AgentDefaultsDraft: Equatable {
    var selectedModel: ModelRef?
    var thinking = "medium"
    var retry = true
    var trust = "ask"
    /// Sparse values owned by this settings scope. Effective inherited values
    /// are kept separately so selecting a model never creates a write.
    var modelContextWindows: [String: Int] = [:]
    var inheritedModelContextWindows: [String: Int] = [:]
    var contextWindowMinimum: Int? = nil

    func contextWindowOverride(for model: ModelRef) -> Int? {
        modelContextWindows[model.contextWindowKey]
    }

    mutating func setContextWindowOverride(_ value: Int?, for model: ModelRef) {
        modelContextWindows[model.contextWindowKey] = value
    }

    func patch(comparedTo baseline: Self) -> JSONValue {
        var patch: [String: JSONValue] = [:]
        if thinking != baseline.thinking { patch["defaultThinkingLevel"] = .string(thinking) }
        if retry != baseline.retry { patch["retry"] = .object(["enabled": .bool(retry)]) }
        if trust != baseline.trust { patch["defaultProjectTrust"] = .string(trust) }
        if selectedModel != baseline.selectedModel {
            if let selectedModel {
                patch["defaultModel"] = .object([
                    "provider": .string(selectedModel.provider),
                    "id": .string(selectedModel.id),
                ])
            } else {
                patch["defaultModel"] = .null
            }
        }
        let keys = Set(modelContextWindows.keys).union(baseline.modelContextWindows.keys)
        var contextPatch: [String: JSONValue] = [:]
        for key in keys {
            if let value = modelContextWindows[key] {
                if baseline.modelContextWindows[key] != value { contextPatch[key] = .number(Double(value)) }
            } else if baseline.modelContextWindows[key] != nil {
                contextPatch[key] = .null
            }
        }
        if !contextPatch.isEmpty { patch["modelContextWindows"] = .object(contextPatch) }
        return .object(patch)
    }
}

struct AgentDefaultsSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.tronPresentationActivity) private var presentationActivity
    let allowsProjectScope: Bool
    let providerTarget: ProviderCatalogTarget
    let projectCWD: String?
    let projectSessionID: String?
    @State private var draft = AgentDefaultsDraft()
    @State private var sliderPresentation = ConfigurationSliderPresentation()
    @State private var drafts = ScopedSettingsDraftStore<AgentDefaultsDraft>()
    @State private var scope: SettingsScope = .global
    @State private var refreshingCatalog = false

    init(
        allowsProjectScope: Bool,
        providerTarget: ProviderCatalogTarget,
        projectCWD: String?,
        projectSessionID: String? = nil
    ) {
        self.allowsProjectScope = allowsProjectScope
        self.providerTarget = providerTarget
        self.projectCWD = projectCWD
        self.projectSessionID = projectSessionID
    }

    var body: some View {
        let editing = editBinding
        return ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(alignment: .leading, spacing: 18) {
                if let target = settingsTarget {
                    SettingsAutosaveNotice(key: .settings(target, sessionID: target.scope == .project ? projectSessionID : nil))
                }
                TronSettingsGroup(
                    "Scope",
                    detail: scope == .project
                        ? "Overrides apply only to the trusted current workspace."
                        : "Defaults apply to every Tron workspace on this Mac."
                ) {
                    if allowsProjectScope {
                        TronSelectionRow(icon: "scope", title: "Settings Scope",
                                         value: scope == .project ? "Current Project" : "Global Defaults") {
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
                VStack(alignment: .leading, spacing: TronSpacing.md) {
                    TronSettingsGroup("Default Model", accent: .tronPurple) {
                        VStack(spacing: 0) {
                            TronModelSelectionRow(
                                selection: editing.selectedModel,
                                models: availableModels,
                                navigationTitle: "Models"
                            )
                            if model.gatewayInfo?.capabilities.contains("context-window.v1") == true,
                               let selectedModel, let limits = selectedContextWindowLimits {
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
                            TronSettingsDivider(accent: .tronPurple)
                            TronThinkingSelectionRow(
                                selection: editing.thinking,
                                // Persisted defaults are model-independent; only a live
                                // session uses the runtime's available-level subset.
                                levels: ["off", "minimal", "low", "medium", "high", "xhigh", "max"],
                                information: "Reasoning effort; higher levels can take longer"
                            )
                            .id(settingsTarget)
                        }
                    }
                    refreshModelCatalogButton
                }
                TronSettingsGroup("Context", accent: .tronTeal) {
                    VStack(spacing: 0) {
                        TronToggleRow(
                            icon: "arrow.clockwise",
                            title: "Automatic Retry",
                            detail: "Retry transient agent and provider failures",
                            accent: .tronTeal,
                            isOn: editing.retry
                        )
                    }
                }
                TronSettingsGroup(
                    "Project Resources",
                    detail: "Trust controls project resource loading; it is not a sandbox.",
                    accent: .tronAmber
                ) {
                    TronSelectionRow(icon: "checkmark.shield", title: "Default Trust", value: draft.trust.capitalized, accent: .tronAmber) {
                        Button("Ask") { editing.update { $0.trust = "ask" } }
                        Button("Always") { editing.update { $0.trust = "always" } }
                        Button("Never") { editing.update { $0.trust = "never" } }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
        }
        .tronScrollEdgeChrome()
        .tronConfigurationSliderHost(sliderPresentation)
        .environment(\.configurationSliderSignposts, model.performanceSignpostsForCapture)
        .tronNavigationTitle("Models and Defaults")
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
            await refresh()
        }
    }

    private var settingsTarget: SettingsTarget? {
        SettingsTarget(scope: scope, projectCWD: projectCWD)
    }

    private var catalogTarget: ProviderCatalogTarget {
        scope == .project ? providerTarget : .global
    }

    private var availableModels: [ModelSummary] {
        model.providerCatalog(for: catalogTarget)?.models.filter(\.available) ?? []
    }

    private var selectedModel: ModelSummary? {
        guard let selected = draft.selectedModel else { return nil }
        return availableModels.first(where: { $0.ref == selected })
    }

    private var selectedContextWindowLimits: ContextWindowLimits? {
        selectedModel?.contextWindowLimits?.withMinimum(draft.contextWindowMinimum)
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
            get: { editing.wrappedValue.contextWindowOverride(for: modelSummary.ref) },
            set: { value in editing.update { $0.setContextWindowOverride(value, for: modelSummary.ref) } }
        )
    }

    private var refreshModelCatalogButton: some View {
        TronSettingsRow(icon: "list.bullet.rectangle", title: "Model Catalog",
                        subtitle: modelCatalogSummary, accent: .tronPurple) {
            Button { Task { await refreshModelCatalog() } } label: {
                TronInlineActionLabel("Refresh", icon: "arrow.clockwise", isWorking: refreshingCatalog, accent: .tronPurple)
            }
            .buttonStyle(.plain)
            .disabled(refreshingCatalog)
            .accessibilityLabel("Refresh Model Catalog")
        }
        .tronGlassSurface(accent: .tronPurple, tintOpacity: 0.14)
    }

    private var modelCatalogSummary: String {
        guard model.providerCatalog(for: catalogTarget) != nil else { return "Catalog not loaded" }
        return availableModels.count == 1
            ? "1 model currently available"
            : "\(availableModels.count) models currently available"
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

    private func refresh() async {
        let foreground = model.foregroundReconciliationGeneration
        guard let target = settingsTarget else { return }
        // Establish a clean local snapshot before the first async response. If the
        // user edits while the response is in flight, update() marks the draft dirty
        // and the late response is correctly rejected.
        _ = drafts.seedBaselineIfMissing(draft, for: target)
        let requestedCatalogTarget = catalogTarget
        async let settingsReady = model.refreshSettings(target: target)
        async let catalogReady = model.refreshProviders(target: requestedCatalogTarget)
        let (loadedSettings, _) = await (settingsReady, catalogReady)
        guard loadedSettings,
              foreground == model.foregroundReconciliationGeneration,
              presentationActivity.allowsPresentationPublication,
              !Task.isCancelled,
              target == settingsTarget,
              requestedCatalogTarget == catalogTarget else { return }
        load(target: target, catalogTarget: requestedCatalogTarget)
    }

    private func load(target: SettingsTarget, catalogTarget: ProviderCatalogTarget) {
        guard let root = model.settings(for: target)?.objectValue,
              let value = root["effective"]?.objectValue else { return }
        let selectedModel: ModelRef?
        if let object = value["defaultModel"]?.objectValue,
           let provider = object["provider"]?.stringValue,
           let id = object["id"]?.stringValue {
            selectedModel = ModelRef(provider: provider, id: id)
        } else {
            selectedModel = model.preferredAvailableModel(for: catalogTarget)
        }
        let scopeDocument = root["documents"]?.objectValue?[target.scope.rawValue]?.objectValue ?? [:]
        let scopedContextWindows = Self.contextWindows(scopeDocument["modelContextWindows"])
        let inheritedContextWindows = target.scope == .project
            ? Self.contextWindows(root["documents"]?.objectValue?["global"]?.objectValue?["modelContextWindows"])
            : [:]
        let projected = AgentDefaultsDraft(
            selectedModel: selectedModel,
            thinking: value["defaultThinkingLevel"]?.stringValue ?? "medium",
            retry: value["retry"]?.objectValue?["enabled"]?.boolValue ?? true,
            trust: value["defaultProjectTrust"]?.stringValue ?? "ask",
            modelContextWindows: scopedContextWindows,
            inheritedModelContextWindows: inheritedContextWindows,
            contextWindowMinimum: value["contextWindowMinimum"]?.intValue
        )
        if drafts.install(projected, for: target, ifCurrent: draft) {
            draft = projected
        } else if let saved = drafts.draft(for: target) {
            draft = saved
        }
    }

    private static func contextWindows(_ value: JSONValue?) -> [String: Int] {
        guard let object = value?.objectValue else { return [:] }
        return object.compactMapValues { value in
            guard let number = value.intValue, number > 0 else { return nil }
            return number
        }
    }

    private func refreshModelCatalog() async {
        guard !refreshingCatalog else { return }
        let requestedTarget = catalogTarget
        refreshingCatalog = true
        defer { refreshingCatalog = false }
        do {
            try await model.refreshModelCatalog(target: requestedTarget, force: true)
        } catch is CancellationError {
            // Profile replacement retires the old target and its presentation.
        } catch {
            model.presentError(error)
        }
    }

}
