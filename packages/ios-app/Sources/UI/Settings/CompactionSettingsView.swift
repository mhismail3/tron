import SwiftUI

struct CompactionSettingsDraft: Equatable {
    var enabled = true
    var thinkingLevel = "inherit"
    var instructions = ""
    var reserveTokens = 16_384
    var keepRecentTokens = 20_000
    var restoreStandardRequested = false
    enum GenerationField: Hashable { case thinking, focus }
    var useGlobalFields: Set<GenerationField> = []

    mutating func restoreStandard() {
        thinkingLevel = "inherit"
        instructions = ""
        restoreStandardRequested = true
        useGlobalFields.removeAll()
    }

    mutating func setThinkingLevel(_ level: String) {
        thinkingLevel = level
        useGlobalFields.remove(.thinking)
    }

    mutating func setInstructions(_ value: String) {
        instructions = Self.boundedInstructions(value)
        useGlobalFields.remove(.focus)
    }

    mutating func useGlobalPolicy(from inherited: Self) {
        thinkingLevel = inherited.thinkingLevel
        instructions = inherited.instructions
        restoreStandardRequested = false
        useGlobalFields = [.thinking, .focus]
    }

    static func boundedInstructions(_ value: String) -> String {
        var units = 0
        var result = String.UnicodeScalarView()
        for scalar in value.unicodeScalars {
            let scalarUnits = scalar.value > 0xFFFF ? 2 : 1
            guard units + scalarUnits <= 4_000 else { break }
            result.append(scalar)
            units += scalarUnits
        }
        return String(result)
    }

    func afterSuccessfulSave() -> Self {
        var saved = self
        saved.restoreStandardRequested = false
        saved.useGlobalFields.removeAll()
        return saved
    }

    func patch(comparedTo baseline: Self) -> JSONValue {
        var compaction: [String: JSONValue] = [:]
        if enabled != baseline.enabled { compaction["enabled"] = .bool(enabled) }
        if useGlobalFields.contains(.thinking) { compaction["thinkingLevel"] = .null }
        else if thinkingLevel != baseline.thinkingLevel || restoreStandardRequested { compaction["thinkingLevel"] = .string(thinkingLevel) }
        if useGlobalFields.contains(.focus) { compaction["instructions"] = .null }
        else if instructions != baseline.instructions || restoreStandardRequested { compaction["instructions"] = .string(instructions) }
        if reserveTokens != baseline.reserveTokens { compaction["reserveTokens"] = .number(Double(reserveTokens)) }
        if keepRecentTokens != baseline.keepRecentTokens { compaction["keepRecentTokens"] = .number(Double(keepRecentTokens)) }
        return .object(compaction.isEmpty ? [:] : ["compaction": .object(compaction)])
    }
}

struct CompactionSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.tronPresentationActivity) private var presentationActivity
    let projectCWD: String?
    let projectSessionID: String?
    @State private var scope: SettingsScope = .global
    @State private var draft = CompactionSettingsDraft()
    @State private var drafts = ScopedSettingsDraftStore<CompactionSettingsDraft>()
    @State private var saving = false

    private var allowsProjectScope: Bool { projectCWD != nil }
    private var supportsPolicy: Bool { model.gatewayInfo?.capabilities.contains("compaction-policy.v1") == true }
    private var sessionPolicy: CompactionPolicyProjection? {
        guard let projectSessionID else { return nil }
        return model.authoritativeSnapshot(for: projectSessionID)?.compactionPolicy
    }
    private var sourceDescription: String {
        guard let target = settingsTarget,
              let source = model.settings(for: target)?.objectValue?["effective"]?.objectValue?["compaction"]?.objectValue?["source"]?.objectValue else { return "Sources unavailable" }
        return "Thinking: \(source["thinkingLevel"]?.stringValue ?? "unknown"); focus: \(source["instructions"]?.stringValue ?? "unknown")."
    }
    private var settingsTarget: SettingsTarget? { SettingsTarget(scope: scope, projectCWD: projectCWD) }
    private var hasUnsavedChanges: Bool {
        guard let target = settingsTarget else { return false }
        return drafts.hasChanges(draft, for: target)
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(alignment: .leading, spacing: 18) {
                scopeGroup
                if let sessionPolicy { effectiveGroup(sessionPolicy) }
                TronSettingsGroup("Saved Configuration", detail: sourceDescription, accent: .tronTeal, surfaceStyle: .scrollOptimized) {
                    VStack(spacing: 0) {
                        TronToggleRow(
                            icon: "arrow.triangle.2.circlepath",
                            title: "Automatic compaction",
                            detail: "Applies at the next idle prompt or manual compaction",
                            accent: .tronTeal,
                            isOn: $draft.enabled
                        )
                        TronSettingsDivider(accent: .tronTeal)
                        TronValueRow(icon: "brain", title: "Summary thinking", detail: "Same conversation model; SDK-resolved request level (provider defaults may still apply)", value: draft.thinkingLevel == "inherit" ? "Inherit conversation" : draft.thinkingLevel.capitalized, accent: .tronTeal) {
                            TronInlineMenu("Change", accent: .tronTeal) {
                                Button("Inherit conversation") { draft.setThinkingLevel("inherit") }
                                ForEach(["off", "minimal", "low", "medium", "high", "xhigh", "max"], id: \.self) { level in
                                    Button(level.capitalized) { draft.setThinkingLevel(level) }
                                }
                            }.disabled(!supportsPolicy)
                        }
                    }
                }
                TronSettingsGroup("Summary Focus", detail: "Optional. Up to 4,000 UTF-16 units; no hard summary-length guarantee.", accent: .tronPurple, surfaceStyle: .scrollOptimized) {
                    VStack(alignment: .leading, spacing: 12) {
                        TextEditor(text: instructionsBinding)
                            .frame(minHeight: 120)
                            .tronTextEditor()
                            .accessibilityLabel("Compaction summary focus")
                            .disabled(!supportsPolicy)
                        Text("Thinking and focus are captured at the next compaction, including both split-summary passes. They do not change chat, branch summaries, or an already-running summary.")
                            .font(TronTypography.secondaryDescription)
                            .foregroundStyle(Color.tronTextSecondary)
                        Button("Restore standard behavior") { draft.restoreStandard() }
                            .disabled(!supportsPolicy)
                        if scope == .project, let inherited = globalProjectionDraft() {
                            Button("Use global values") { draft.useGlobalPolicy(from: inherited) }
                                .disabled(!supportsPolicy)
                            Text("Removes this project's thinking and focus overrides so future global changes are inherited. Save to apply.")
                                .font(TronTypography.secondaryDescription)
                                .foregroundStyle(Color.tronTextSecondary)
                        }
                        Text("Restores inherited conversation thinking and empty focus. Automatic compaction and token budgets are unchanged. Save to apply.")
                            .font(TronTypography.secondaryDescription)
                            .foregroundStyle(Color.tronTextSecondary)
                    }.padding(14)
                }
                TronSettingsGroup("Advanced Context Budgets", detail: "Applied at the next idle prompt or manual compaction, never during an active run.", accent: .tronTeal, surfaceStyle: .scrollOptimized) {
                    VStack(spacing: 0) {
                        numberRow("gauge.with.dots.needle.33percent", "Reserve tokens", "Response headroom", value: $draft.reserveTokens)
                        TronSettingsDivider(accent: .tronTeal)
                        numberRow("text.line.last.and.arrowtriangle.forward", "Keep recent tokens", "Recent history retained verbatim", value: $draft.keepRecentTokens)
                    }
                }
                if !supportsPolicy {
                    Text("This Gateway does not expose configurable summary thinking and focus.")
                        .font(TronTypography.secondaryDescription)
                        .foregroundStyle(Color.tronAmber)
                }
                if draft.thinkingLevel == "low" {
                    Text("Low is an explicit experiment. Provider quality and cost may vary; standard behavior is recommended until evaluated with your provider.")
                        .font(TronTypography.secondaryDescription)
                        .foregroundStyle(Color.tronAmber)
                        .padding(.horizontal, 4)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
        }
        .tronScrollEdgeChrome()
        .tronNavigationTitle("Compaction")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                TronSaveToolbarButton(isSaving: saving, isEnabled: hasUnsavedChanges) { Task { await save() } }
            }
        }
        .task(id: PresentationActivityTaskID(
            source: SettingsLoadID(target: settingsTarget, invalidationGeneration: model.settingsInvalidationGeneration),
            presentationActive: presentationActivity.allowsPresentationPublication
        )) {
            guard presentationActivity.allowsPresentationPublication else { return }
            if !allowsProjectScope { scope = .global }
            await load()
        }
        .onChange(of: draft) { _, value in
            if let target = settingsTarget { drafts.update(value, for: target) }
        }
    }

    private func effectiveGroup(_ policy: CompactionPolicyProjection) -> some View {
        TronSettingsGroup("Current Session", detail: "Read-only runtime configuration, independent of this editor's scope.", accent: .tronTeal, surfaceStyle: .scrollOptimized) {
            VStack(alignment: .leading, spacing: 12) {
                if let selected = policy.next.model {
                    Text("Model: \(selected.provider)/\(selected.id)")
                } else {
                    Text("No session model selected")
                }
                Text("Next summary: requested \(policy.next.requestedThinkingLevel), effective \(policy.next.effectiveThinkingLevel ?? "unavailable").")
                Text("Current automatic compaction: \(policy.currentBudgets.enabled ? "On" : "Off"). Reserve \(policy.currentBudgets.reserveTokens); retain \(policy.currentBudgets.keepRecentTokens) tokens.")
                if let active = policy.active {
                    Text("Running \(active.reason ?? "") summary: requested \(active.requestedThinkingLevel), effective \(active.effectiveThinkingLevel ?? "unavailable"). Reserve \(active.reserveTokens); retain \(active.keepRecentTokens) tokens.")
                    Text(active.instructions.isEmpty ? "Running focus: none" : "Running focus: \(active.instructions)")
                }
                if policy.extensionMayOverride {
                    Text("An extension observes compaction and may supply its own summary. This policy governs built-in requests through this session, not independent extension generation.")
                        .foregroundStyle(Color.tronAmber)
                }
                if let warning = policy.warning { Text(warning).foregroundStyle(Color.tronAmber) }
            }
            .font(TronTypography.secondaryDescription)
            .foregroundStyle(Color.tronTextSecondary)
            .padding(14)
        }
    }

    private var scopeGroup: some View {
        TronSettingsGroup("Scope", detail: scope == .project
            ? "Overrides apply only to the trusted current workspace."
            : "Defaults apply to every workspace on this Mac.", surfaceStyle: .scrollOptimized) {
            if allowsProjectScope {
                TronValueRow(icon: "scope", title: "Settings Scope", value: scope == .project ? "Current Project" : "Global Defaults") {
                    TronInlineMenu("Change") {
                        Button("Global Defaults") { selectScope(.global) }
                        Button("Current Project") { selectScope(.project) }
                    }
                }
            } else {
                TronValueRow(icon: "scope", title: "Settings Scope", value: "Global Defaults")
            }
        }
    }

    private var instructionsBinding: Binding<String> {
        Binding(get: { draft.instructions }, set: { draft.setInstructions($0) })
    }

    private func numberRow(_ icon: String, _ title: String, _ detail: String, value: Binding<Int>) -> some View {
        TronValueRow(icon: icon, title: title, detail: detail, accent: .tronTeal) {
            TextField(title, value: value, format: .number)
                .keyboardType(.numberPad)
                .tronInlineField(numeric: true)
                .multilineTextAlignment(.trailing)
                .frame(width: 118)
        }
    }

    private func selectScope(_ newScope: SettingsScope) {
        guard newScope != scope, let target = SettingsTarget(scope: newScope, projectCWD: projectCWD) else { return }
        draft = drafts.draftForScopeSwitch(current: draft, from: settingsTarget, to: target, default: CompactionSettingsDraft())
        scope = newScope
    }

    private func load() async {
        guard let target = settingsTarget else { return }
        _ = drafts.seedBaselineIfMissing(draft, for: target)
        guard await model.refreshSettings(target: target),
              presentationActivity.allowsPresentationPublication,
              !Task.isCancelled,
              target == settingsTarget,
              let loaded = projectionDraft(target: target), drafts.install(loaded, for: target, ifCurrent: draft) else { return }
        draft = loaded
    }

    private func projectionDraft(target: SettingsTarget) -> CompactionSettingsDraft? {
        guard let value = model.settings(for: target)?.objectValue?["effective"]?.objectValue,
              let compaction = value["compaction"]?.objectValue else { return nil }
        return CompactionSettingsDraft(
            enabled: compaction.bool("enabled", fallback: true),
            thinkingLevel: compaction.string("thinkingLevel", fallback: "inherit"),
            instructions: compaction.string("instructions", fallback: ""),
            reserveTokens: compaction.int("reserveTokens", fallback: 16_384),
            keepRecentTokens: compaction.int("keepRecentTokens", fallback: 20_000)
        )
    }

    private func globalProjectionDraft() -> CompactionSettingsDraft? {
        // The scoped response already includes the canonical global document;
        // avoid a second request and a different-time inheritance preview.
        guard let target = settingsTarget,
              let global = model.settings(for: target)?.objectValue?["documents"]?.objectValue?["global"]?.objectValue else { return nil }
        let compaction = global["compaction"]?.objectValue ?? [:]
        return CompactionSettingsDraft(
            thinkingLevel: compaction.string("thinkingLevel", fallback: "inherit"),
            instructions: compaction.string("instructions", fallback: "")
        )
    }

    private func save() async {
        guard let target = settingsTarget else { return }
        drafts.update(draft, for: target)
        guard drafts.isDirty(target), let revision = drafts.revision(for: target) else { return }
        let submitted = draft
        saving = true
        defer { saving = false }
        let baseline = drafts.baseline(for: target) ?? CompactionSettingsDraft()
        do {
            try await model.updateSettings(submitted.patch(comparedTo: baseline), target: target)
            guard target == settingsTarget, draft == submitted else { return }
            let resultingDraft = (projectionDraft(target: target) ?? submitted).afterSuccessfulSave()
            if drafts.markSaved(
                submitted: submitted,
                resulting: resultingDraft,
                for: target,
                expectedRevision: revision
            ) {
                draft = resultingDraft
            }
        } catch { model.presentError(error) }
    }
}
