import SwiftUI

struct CompactionSettingsDraft: Equatable {
    var enabled = true
    var thinkingLevel = "inherit"
    var instructions = ""
    var reserveTokens = 16_384
    var keepRecentTokens = 20_000
    var branchReserveTokens = 16_384
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
        else if thinkingLevel != baseline.thinkingLevel || restoreStandardRequested || baseline.useGlobalFields.contains(.thinking) { compaction["thinkingLevel"] = .string(thinkingLevel) }
        if useGlobalFields.contains(.focus) { compaction["instructions"] = .null }
        else if instructions != baseline.instructions || restoreStandardRequested || baseline.useGlobalFields.contains(.focus) { compaction["instructions"] = .string(instructions) }
        if reserveTokens != baseline.reserveTokens { compaction["reserveTokens"] = .number(Double(reserveTokens)) }
        if keepRecentTokens != baseline.keepRecentTokens { compaction["keepRecentTokens"] = .number(Double(keepRecentTokens)) }
        var patch: [String: JSONValue] = compaction.isEmpty ? [:] : ["compaction": .object(compaction)]
        if branchReserveTokens != baseline.branchReserveTokens {
            patch["branchSummary"] = .object(["reserveTokens": .number(Double(branchReserveTokens))])
        }
        return .object(patch)
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

    private var supportsPolicy: Bool { model.gatewayInfo?.capabilities.contains("compaction-policy.v1") == true }
    private var settingsTarget: SettingsTarget? { SettingsTarget(scope: scope, projectCWD: projectCWD) }
    private var sessionPolicy: CompactionPolicyProjection? {
        projectSessionID.flatMap { model.authoritativeSnapshot(for: $0)?.compactionPolicy }
    }

    var body: some View {
        let editing = editBinding
        return ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(alignment: .leading, spacing: 18) {
                scopeGroup
                if let target = settingsTarget { SettingsAutosaveNotice(key: .settings(target, sessionID: nil)) }
                if let sessionPolicy { CompactionRuntimeSection(policy: sessionPolicy) }
                TronSettingsGroup("Defaults", detail: "Applied at the next idle prompt or manual compaction.", accent: .tronPurple) {
                    VStack(spacing: 0) {
                        TronToggleRow(icon: "arrow.triangle.2.circlepath", title: "Automatic Compaction",
                                      detail: "Summarize when the context window fills", accent: .tronPurple, isOn: editing.enabled)
                        TronSettingsDivider(accent: .tronPurple)
                        TronSelectionRow(icon: "brain", title: "Summary Thinking",
                                         detail: "Reasoning effort for the summary, not the conversation",
                                         value: draft.thinkingLevel == "inherit" ? "Inherit" : ThinkingLevelPresentation.title(draft.thinkingLevel), accent: .tronPurple) {
                            Button("Inherit conversation") { editing.update { $0.setThinkingLevel("inherit") } }
                            ForEach(["off", "minimal", "low", "medium", "high", "xhigh", "max"], id: \.self) { level in
                                Button(ThinkingLevelPresentation.title(level)) { editing.update { $0.setThinkingLevel(level) } }
                            }
                        }
                        .disabled(!supportsPolicy)
                    }
                }
                .tronSettingsCaption(draft.thinkingLevel == "low" ? "Low is an explicit experiment. Provider quality and cost may vary; standard behavior is recommended until evaluated with your provider." : nil)
                TronSettingsGroup("Summary Focus", detail: "Optional guidance for future summaries.", accent: .tronPurple) {
                    VStack(spacing: 0) {
                        TronValueRow(icon: "text.alignleft", title: "Instructions",
                                     value: "\(draft.instructions.utf16.count.formatted()) / 4,000", accent: .tronPurple)
                        TextEditor(text: instructionsBinding)
                            .frame(minHeight: 110)
                            .tronTextEditor()
                            .padding(.horizontal, 14).padding(.bottom, 14)
                            .accessibilityLabel("Compaction summary focus")
                            .disabled(!supportsPolicy)
                        TronSettingsDivider(accent: .tronPurple)
                        TronSettingsRow(icon: "arrow.uturn.backward", title: "Standard Behavior",
                                        subtitle: "Inherit conversation thinking and clear focus", accent: .tronPurple) {
                            Button { editing.update { $0.restoreStandard() } } label: {
                                TronInlineActionLabel("Restore", accent: .tronPurple)
                            }.buttonStyle(.plain).disabled(!supportsPolicy)
                        }
                        if scope == .project, let inherited = globalProjectionDraft() {
                            TronSettingsDivider(accent: .tronPurple)
                            TronSettingsRow(icon: "globe", title: "Global Values",
                                            subtitle: "Remove this project's thinking and focus overrides", accent: .tronPurple) {
                                Button { editing.update { $0.useGlobalPolicy(from: inherited) } } label: {
                                    TronInlineActionLabel("Use Global", accent: .tronPurple)
                                }.buttonStyle(.plain).disabled(!supportsPolicy)
                            }
                        }
                    }
                }
                .tronSettingsCaption("Focus is captured when a summary starts. It does not change an active summary, chat, or branch summaries. Restore leaves automatic compaction and token budgets unchanged."
                    + (supportsPolicy ? "" : "\nThis Gateway does not expose configurable summary thinking and focus."))
                TronSettingsGroup("Context Budgets", detail: "Token allowances for future summaries.", accent: .tronPurple) {
                    VStack(spacing: 0) {
                        TronNumberSettingRow(icon: "gauge.with.dots.needle.33percent", title: "Reserve Tokens",
                                             detail: "Response headroom", value: editing.reserveTokens, accent: .tronPurple)
                        TronSettingsDivider(accent: .tronPurple)
                        TronNumberSettingRow(icon: "text.line.last.and.arrowtriangle.forward", title: "Keep Recent Tokens",
                                             detail: "Recent history retained verbatim", value: editing.keepRecentTokens, accent: .tronPurple)
                        TronSettingsDivider(accent: .tronPurple)
                        TronNumberSettingRow(icon: "arrow.triangle.branch", title: "Branch Summary Reserve",
                                             detail: "Headroom when summarizing a branch you leave", value: editing.branchReserveTokens, accent: .tronPurple)
                    }
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 18)
        }
        .scrollDismissesKeyboard(.interactively)
        .tronScrollEdgeChrome().tronNavigationTitle("Compaction")
        .tronSettingsAutosave(draft: $draft, store: $drafts, initial: CompactionSettingsDraft())
        .task(id: PresentationActivityTaskID(
            source: SettingsLoadID(target: settingsTarget, invalidationGeneration: model.settingsInvalidationGeneration,
                                   foregroundGeneration: model.foregroundReconciliationGeneration),
            presentationActive: presentationActivity.allowsPresentationPublication
        )) {
            guard presentationActivity.allowsPresentationPublication else { return }
            if projectCWD == nil { scope = .global }
            await load()
        }
    }

    private var scopeGroup: some View {
        TronSettingsGroup("Scope", detail: scope == .project ? "Overrides for this trusted workspace." : "Defaults for every workspace on this Mac.") {
            if projectCWD != nil {
                TronSelectionRow(icon: "scope", title: "Settings Scope", value: scope == .project ? "Current Project" : "Global Defaults") {
                    Button("Global Defaults") { selectScope(.global) }
                    Button("Current Project") { selectScope(.project) }
                }
            } else { TronValueRow(icon: "scope", title: "Settings Scope", value: "Global Defaults") }
        }
    }

    private var editBinding: Binding<CompactionSettingsDraft> {
        let target = settingsTarget
        return SettingsAutosave.binding(draft: $draft, store: $drafts, model: model, target: target,
            admits: { target == settingsTarget && presentationActivity.allowsDataPublication },
            patch: { $0.patch(comparedTo: $1) },
            settled: { value, target in (projectionDraft(target: target) ?? value).afterSuccessfulSave() })
    }

    private var instructionsBinding: Binding<String> {
        let editing = editBinding
        return Binding(get: { editing.wrappedValue.instructions }, set: { value in editing.update { $0.setInstructions(value) } })
    }

    private func selectScope(_ newScope: SettingsScope) {
        guard newScope != scope, let target = SettingsTarget(scope: newScope, projectCWD: projectCWD) else { return }
        draft = drafts.draftForScopeSwitch(current: draft, from: settingsTarget, to: target, default: CompactionSettingsDraft())
        scope = newScope
    }

    private func load() async {
        let foreground = model.foregroundReconciliationGeneration
        guard let target = settingsTarget else { return }
        _ = drafts.seedBaselineIfMissing(draft, for: target)
        guard await model.refreshSettings(target: target), presentationActivity.allowsPresentationPublication,
              foreground == model.foregroundReconciliationGeneration, !Task.isCancelled, target == settingsTarget,
              let loaded = projectionDraft(target: target), drafts.install(loaded, for: target, ifCurrent: draft) else { return }
        draft = loaded
    }

    private func projectionDraft(target: SettingsTarget) -> CompactionSettingsDraft? {
        guard let effective = model.settings(for: target)?.objectValue?["effective"]?.objectValue,
              let compaction = effective["compaction"]?.objectValue else { return nil }
        return CompactionSettingsDraft(
            enabled: compaction.bool("enabled", fallback: true),
            thinkingLevel: compaction.string("thinkingLevel", fallback: "inherit"),
            instructions: compaction.string("instructions", fallback: ""),
            reserveTokens: compaction.int("reserveTokens", fallback: 16_384),
            keepRecentTokens: compaction.int("keepRecentTokens", fallback: 20_000),
            branchReserveTokens: effective["branchSummary"]?.objectValue?.int("reserveTokens", fallback: 16_384) ?? 16_384
        )
    }

    private func globalProjectionDraft() -> CompactionSettingsDraft? {
        guard let target = settingsTarget,
              let global = model.settings(for: target)?.objectValue?["documents"]?.objectValue?["global"]?.objectValue else { return nil }
        let compaction = global["compaction"]?.objectValue ?? [:]
        return CompactionSettingsDraft(thinkingLevel: compaction.string("thinkingLevel", fallback: "inherit"),
                                       instructions: compaction.string("instructions", fallback: ""))
    }
}

/// Read-only runtime facts use the same rows as editable defaults, without
/// conflating the active session with the selected settings scope.
struct CompactionRuntimeSection: View {
    let policy: CompactionPolicyProjection
    var body: some View {
        TronSettingsGroup("Current Session", detail: "Live configuration, independent of the defaults below.", accent: .tronPurple) {
            VStack(spacing: 0) {
                TronValueRow(icon: "cpu", title: "Model", value: policy.next.model?.displayName ?? "Not selected")
                TronSettingsDivider()
                TronValueRow(icon: "brain", title: "Summary Thinking",
                             detail: policy.next.effectiveThinkingLevel == policy.next.requestedThinkingLevel ? nil
                                : "Requested: \(ThinkingLevelPresentation.title(policy.next.requestedThinkingLevel))",
                             value: policy.next.effectiveThinkingLevel.map(ThinkingLevelPresentation.title) ?? "Unavailable")
                TronSettingsDivider()
                TronValueRow(icon: "arrow.triangle.2.circlepath", title: "Automatic Compaction", value: policy.currentBudgets.enabled ? "On" : "Off")
                TronSettingsDivider()
                TronValueRow(icon: "gauge.with.dots.needle.33percent", title: "Reserve Tokens", value: policy.currentBudgets.reserveTokens.formatted())
                TronSettingsDivider()
                TronValueRow(icon: "text.line.last.and.arrowtriangle.forward", title: "Keep Recent Tokens", value: policy.currentBudgets.keepRecentTokens.formatted())
                if let active = policy.active {
                    TronSettingsDivider()
                    TronSettingsRow(icon: "arrow.triangle.2.circlepath", title: "Summary Running",
                                    subtitle: "\(ThinkingLevelPresentation.title(active.effectiveThinkingLevel ?? active.requestedThinkingLevel)) · \(active.reserveTokens.formatted()) reserved · \(active.keepRecentTokens.formatted()) retained")
                    if !active.instructions.isEmpty {
                        TronSettingsDivider()
                        TronSettingsRow(icon: "text.alignleft", title: "Running Focus", subtitle: active.instructions)
                    }
                }
            }
        }
        .tronSettingsCaption(runtimeNote)
    }

    private var runtimeNote: String? {
        let notes = [policy.extensionMayOverride
            ? "An extension may supply its own summary. These defaults govern built-in summaries." : nil,
            policy.warning].compactMap { $0 }.filter { !$0.isEmpty }
        return notes.isEmpty ? nil : notes.joined(separator: "\n")
    }
}
