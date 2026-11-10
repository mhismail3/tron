import SwiftUI
import TronMobileCore

struct SettingsRendererRow: View {
    let setting: ResolvedSetting
    let target: JSONValue
    let editable: Bool
    var detailed = false
    var modelConfiguration = false
    var modelSelectionAvailability: ModelSelectionAvailability = .ready
    var instanced = false
    var baseInstanceTitle: String? = nil
    var liveControl: AnyView? = nil
    var resetDisabled = false
    var canReset = false
    var instanceHelp: String? = nil
    let options: SettingsOptionsResponse?
    let error: String?
    let onChange: (JSONValue?) -> Void
    var onApplyAgain: ((String) -> Void)? = nil

    @Environment(AppModel.self) private var model
    @Environment(\.tronSettingsVisualTheme) private var theme

    private var presentation: SettingsKeyPresentation { setting.presentation }
    private var title: String {
        if modelConfiguration && setting.key == "model.thinking[role=chat]" { return "Effort" }
        if modelConfiguration && setting.key == "model.contextWindow" { return "Context Window" }
        return instanced ? (Self.instanceName(setting) ?? baseInstanceTitle ?? presentation.label)
            : (presentation.label)
    }

    static func instanceName(_ setting: ResolvedSetting) -> String? {
        if let scope = setting.badge("scope")?.label {
            return scope.hasPrefix("/") ? URL(fileURLWithPath: scope).lastPathComponent : scope
        }
        let fixed = fixedQualifiers(setting.key)
        let values = (setting.qualifiers ?? [:]).filter { fixed[$0.key] != $0.value }.sorted { $0.key < $1.key }.map(\.value)
        return values.isEmpty ? nil : values.joined(separator: " · ")
    }

    private static func fixedQualifiers(_ key: String) -> [String: String] {
        guard let open = key.firstIndex(of: "["), key.hasSuffix("]") else { return [:] }
        let pairs = key[key.index(after: open)..<key.index(before: key.endIndex)].split(separator: ",").compactMap { pair -> (String, String)? in
            let parts = pair.split(separator: "=", maxSplits: 1)
            return parts.count == 2 ? (String(parts[0]), String(parts[1])) : nil
        }
        return Dictionary(pairs, uniquingKeysWith: { first, _ in first })
    }

    private var control: SettingsRowControl {
        let negotiated = editable ? SettingsRowControl(negotiated: presentation.control) : .readOnly
        return negotiated == .list && presentation.valueKind != "stringList" ? .readOnly : negotiated
    }

    private var subtitle: String? {
        guard detailed else { return nil }
        let scope = setting.badge("scope")?.label
        let instanceLine = instanceHelp ?? (scope != title ? scope : nil) ?? ""
        let lines = [instanced ? instanceLine : presentation.help, presentation.note ?? ""].filter { !$0.isEmpty }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    private var entrySubtitle: String? {
        guard detailed, let hint = presentation.entry?.hint else { return subtitle }
        return [subtitle, hint].compactMap { $0 }.joined(separator: "\n")
    }

    static func semanticIcon(for key: String) -> String? {
        switch key {
        case "model.ref[role=chat]": return "cpu"
        case "model.thinking[role=chat]": return "brain"
        case "model.thinking[role=worker]": return "brain.head.profile"
        case "model.thinkingBudgets": return "gauge.with.dots.needle.50percent"
        case "model.queue[role=worker]": return "person.crop.rectangle.stack"
        case "model.queue[role=subagent]": return "person.2"
        case "model.queue[role=background]": return "moon.stars"
        case "permissions.budget.task": return "chart.pie"
        case "context.compaction.enabled": return "arrow.down.right.and.arrow.up.left"
        case "model.thinking[role=summarizer]": return "text.badge.checkmark"
        case "run.httpProxy": return "network"
        default: return nil
        }
    }

    private var icon: String {
        if let semantic = Self.semanticIcon(for: setting.key) { return semantic }
        if modelConfiguration, setting.key == "model.contextWindow" { return "gauge.with.dots.needle.50percent" }
        return switch control {
        case .toggle: "switch.2"
        case .text: "character.cursor.ibeam"
        case .secret: "key"
        case .list: "list.bullet"
        case .checklist: "checklist"
        case .catalog: "square.stack.3d.up"
        case .choice, .readOnly: "slider.horizontal.3"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if modelConfiguration && setting.key == "model.ref[role=chat]" {
                    modelHeader
                } else if let liveControl, setting.projectSetting == nil { liveControl } else { control(for: control) }
            }
                .environment(\.tronSettingsRowAccessory, accessory)
                .environment(\.tronSettingsRowStatus, overriddenStatus)
            details
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(settingsRowIdentifier(setting))
    }

    private var modelHeader: some View {
        let value = setting.value?.objectValue
        let provider = value?["provider"]?.stringValue
        let id = value?["id"]?.stringValue
        let sessionID = target.objectValue?["sessionId"]?.stringValue
        let catalog = model.providerCatalog(for: sessionID.map { .session(id: $0) } ?? .global)?.models ?? []
        let selected = catalog.first { $0.provider == provider && $0.id == id }
        return TronSettingsRow(icon: "cpu", title: selected?.displayName ?? display,
                               titleFont: SessionSummaryTypography.headline) {
            TronProgressiveSheetLink(accessibilityLabel: "Switch Model", identity: "manage.model.switch", detents: .contentFit) {
                SettingsModelPicker(setting: setting, target: target, title: "Models",
                                    selectionAvailability: modelSelectionAvailability,
                                    onReset: canReset ? { onChange(nil) } : nil) { onChange($0) }
            } label: {
                TronInlineActionLabel("Switch Model")
            }
            .disabled(!editable || control == .readOnly || setting.projectSetting != nil)
            .accessibilityIdentifier("manage-model-switch")
            .accessibilityValue(modelSelectionAvailability.accessibilityValue)
        }
        .lineLimit(1)
    }

    private var accessory: (@MainActor @Sendable () -> AnyView)? {
        if let source = setting.projectSetting {
            return { AnyView(
                TronProgressiveSheetLink(accessibilityLabel: "Set by Project settings",
                    identity: "settings.project.\(setting.id)", detents: .fixed([.height(300), .medium])) {
                    SettingsProjectInfo(source: source)
                } label: { TronInlineActionLabel("Set by Project settings").controlSize(.small).fixedSize() }
                .buttonStyle(.plain)
                .accessibilityIdentifier("\(settingsRowIdentifier(setting))-project")
            ) }
        }
        guard canReset && editable && (control != .readOnly || presentation.control == nil) else { return { AnyView(EmptyView()) } }
        return { AnyView(resetButton) }
    }

    private var overriddenStatus: String? {
        !modelConfiguration && canReset && editable && setting.projectSetting == nil
            && target.objectValue?["kind"]?.stringValue != "global" ? "Overridden" : nil
    }

    private var resetLabel: String {
        target.objectValue?["kind"]?.stringValue == "global" ? "Reset" : "Revert"
    }

    private var resetButton: some View {
        Button { if !resetDisabled { TronHaptics.shared.play(.selectionChanged); onChange(nil) } } label: {
            TronInlineActionLabel("", icon: "arrow.uturn.backward", alignment: .leading, accent: theme?.accent ?? .tronPrimary)
        }
            .controlSize(.small)
            .buttonStyle(.plain)
            .accessibilityLabel(resetLabel)
            .accessibilityHint("Remove the override for \(title) and use its inherited value.")
            .accessibilityIdentifier("\(settingsRowIdentifier(setting))-reset")
            .disabled(resetDisabled)
    }

    private var display: String {
        return setting.value == nil && setting.display == "Not set" && presentation.redacted != true ? "—" : setting.display
    }

    @ViewBuilder
    private func control(for control: SettingsRowControl) -> some View {
        switch control {
        case .toggle:
            TronSettingsRow(icon: icon, title: title, subtitle: subtitle) {
                Button { TronHaptics.shared.changeToggle(from: setting.value?.boolValue == true) { onChange(.bool($0)) } } label: {
                    TronToggleControl(isOn: setting.value?.boolValue == true, accent: theme?.accent ?? .tronPrimary)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityRepresentation {
                    Toggle(isOn: Binding(get: { setting.value?.boolValue == true },
                                         set: { next in TronHaptics.shared.changeToggle(from: setting.value?.boolValue == true, to: next) { onChange(.bool($0)) } })) { Text(title) }
                        .accessibilityHint(subtitle ?? "")
                }
            }
        case .choice:
            let choices = presentation.optionsSource != nil ? (options?.options ?? []) : (presentation.options?.map {
                SettingsOption(value: $0.value, label: $0.label, detail: $0.detail, disabledReason: nil, resource: nil)
            } ?? [])
            if choices.isEmpty {
                readOnlyRow
            } else if presentation.valueKind == "orderedChoice", let value = setting.value {
                SettingsChoiceSelectionRow(title: title, icon: icon, value: value,
                                           display: display, options: choices, information: subtitle,
                                           onChange: { onChange($0) })
                    .controlSize(.small)
            } else {
                TronChoiceRow(icon: icon, title: title, detail: subtitle,
                              choices: choices.map { TronChoice(id: $0.value, label: $0.label, detail: $0.detail,
                                                                disabledReason: $0.disabledReason) },
                              selected: setting.value) { onChange($0) }
            }
        case .text:
            SettingsRendererTextRow(title: title, icon: icon, subtitle: entrySubtitle, example: presentation.entry?.example,
                                    value: setting.value?.stringValue ?? "", onCommit: { onChange(.string($0)) })
        case .secret:
            TronSelectionSheetRow(icon: icon, title: title, detail: subtitle, value: display) {
                SettingsSecretEditor(title: title, help: presentation.help, onChange: onChange)
            }
        case .list:
            if setting.value == nil || setting.value?.arrayValue?.allSatisfy({ $0.stringValue != nil }) == true {
                let values = setting.value?.arrayValue ?? []
                TronSelectionSheetRow(icon: icon, title: title, detail: subtitle, value: display) {
                    SettingsListEditor(title: title, help: presentation.help, entry: presentation.entry,
                                       values: values.compactMap(\.stringValue), entryPicker: modelEntryPicker, onChange: onChange)
                }
            } else {
                readOnlyRow
            }
        case .checklist:
            if presentation.optionsSource?.name == "catalog.tools", let options, let values = setting.value?.arrayValue,
               values.allSatisfy({ $0.stringValue != nil }) {
                TronSelectionSheetRow(icon: icon, title: title, detail: subtitle, value: toolCount(values.compactMap(\.stringValue), of: options.options),
                                      valueFixed: true) {
                    SettingsToolsEditor(title: title, selected: values.compactMap(\.stringValue),
                                        options: options.options) { onChange(.array($0.map(JSONValue.string))) }
                }
            } else if presentation.optionsSource?.name != "catalog.tools", let values = setting.value?.arrayValue,
                      values.allSatisfy({ $0.stringValue != nil }) {
                TronSelectionSheetRow(icon: icon, title: title, detail: subtitle, value: display) {
                    TronChecklistPicker(
                        title: title, help: presentation.help,
                        choices: options?.options.compactMap { option in option.value.stringValue.map {
                            TronChoice(id: $0, label: option.label, detail: option.detail, disabledReason: option.disabledReason)
                        } },
                        selected: values.compactMap(\.stringValue)
                    ) { onChange(.array($0.map(JSONValue.string))) }
                }
            } else {
                readOnlyRow
            }
        case .catalog:
            TronSelectionSheetRow(icon: icon, title: title, detail: subtitle, value: display) {
                if presentation.optionsSource?.name == "catalog.models" {
                    SettingsModelPicker(setting: setting, target: target, title: title,
                                        onReset: canReset ? { onChange(nil) } : nil) { onChange($0) }
                } else {
                    SettingsCatalogPicker(setting: setting, target: target, title: title) { onChange($0) }
                }
            }
        case .readOnly:
            readOnlyRow
        }
    }

    private var modelEntryPicker: ((@escaping (String) -> Void) -> AnyView)? {
        guard presentation.optionsSource?.name == "catalog.models" else { return nil }
        return { add in
            AnyView(SettingsModelPicker(setting: setting, target: target, title: "Add model") { value in
                guard let provider = value.objectValue?["provider"]?.stringValue, let id = value.objectValue?["id"]?.stringValue else { return }
                add("\(provider)/\(id)")
            })
        }
    }

    private func toolCount(_ selected: [String], of catalog: [SettingsOption]?) -> String {
        guard let catalog, !catalog.isEmpty else { return display }
        let total = Set(catalog.compactMap(\.value.stringValue)).union(selected).count
        return "\(selected.count) of \(total) tools"
    }

    @ViewBuilder
    private var readOnlyRow: some View {
        if presentation.optionsSource?.name == "catalog.tools", let values = setting.value?.arrayValue?.compactMap(\.stringValue) {
            TronSelectionSheetRow(icon: icon, title: title, detail: subtitle, value: toolCount(values, of: options?.options), valueFixed: true) {
                SettingsToolsEditor(title: title, selected: values, options: options?.options ?? values.map {
                    SettingsOption(value: .string($0), label: $0, detail: nil, disabledReason: nil, resource: nil)
                })
            }
        } else {
            TronSettingsRow(icon: icon, title: title, subtitle: subtitle) {
                if modelConfiguration {
                    TronInlineActionLabel(display, accent: .tronPrimary)
                        .textSelection(.enabled)
                } else {
                    TronDynamicValue(text: display, color: .tronTextSecondary)
                        .textSelection(.enabled)
                }
            }
        }
    }

    @ViewBuilder
    private var details: some View {
        let actions = setting.badges.compactMap(\.action)
        let applyAgain = onApplyAgain == nil ? [] : actions.filter { $0.kind == "applyAgain" && $0.changeId != nil }
        ForEach(Array(applyAgain.enumerated()), id: \.offset) { _, action in
            TronSettingsDivider()
            Button { if let id = action.changeId { onApplyAgain?(id) } } label: {
                TronSettingsRow(icon: "arrow.clockwise", title: action.label)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("\(settingsRowIdentifier(setting))-applyAgain")
        }
        if let error {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(TronTypography.secondaryDescription)
                .foregroundStyle(Color.tronError)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, TronSettingsLayoutPolicy.dividerLeadingPadding)
                .padding(.trailing, TronSettingsLayoutPolicy.rowHorizontalPadding)
                .padding(.bottom, 12)
                .accessibilityIdentifier("\(settingsRowIdentifier(setting))-error")
        }
    }
}

struct SettingsProjectInfo: View {
    let source: SettingsProjectSource
    var body: some View {
        ScrollView {
            TronSettingsSections(alignment: .leading, spacing: 18, hidesLoneHeading: true) {
                TronSettingsCaption("This is set by the current project's settings. Ask an agent to update them in the repo.").containerValue(\.tronSettingsSection, false)
                TronSettingsGroup(nil) {
                    TronSettingsRow(icon: "doc.text", title: "File") {
                        Text(source.file).font(TronTypography.secondaryCodeDescription).textSelection(.enabled)
                    }
                    TronSettingsDivider()
                    TronSettingsRow(icon: "key", title: "Key") {
                        Text(source.path).font(TronTypography.secondaryCodeDescription).textSelection(.enabled)
                    }
                }
            }.padding(20)
        }
        .tronScrollEdgeChrome()
        .tronNavigationTitle("Project setting")
        .presentationDragIndicator(.hidden)
    }
}

func settingsLayerLabel(_ layer: String) -> String {
    switch layer {
    case "project": "Project"
    case "session": "Session"
    case "global": "Global"
    default: layer.capitalized
    }
}

private struct SettingsModelPicker: View {
    let setting: ResolvedSetting
    let target: JSONValue
    let title: String
    var selectionAvailability: ModelSelectionAvailability = .ready
    var onReset: (() -> Void)? = nil
    let onChoose: (JSONValue) -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var served: [SettingsOption]? // view-local: a rebuilt picker reads the served models again

    private var servedModels: Set<ModelRef>? {
        served.map { Set($0.compactMap { option in
            guard let value = option.value.objectValue, let provider = value["provider"]?.stringValue,
                  let id = value["id"]?.stringValue else { return nil }
            return ModelRef(provider: provider, id: id)
        }) }
    }

    private var catalogTarget: ProviderCatalogTarget {
        if target.objectValue?["kind"]?.stringValue == "session", let id = target.objectValue?["sessionId"]?.stringValue {
            return .session(id: id)
        }
        return .global
    }

    private var selection: Binding<ModelRef?> {
        Binding(
            get: {
                guard let value = setting.value?.objectValue, let provider = value["provider"]?.stringValue,
                      let id = value["id"]?.stringValue else { return nil }
                return ModelRef(provider: provider, id: id)
            },
            set: { ref in
                guard let ref, selectionAvailability.canSelect else { return }
                onChoose(.object(["provider": .string(ref.provider), "id": .string(ref.id)]))
                dismiss()
            }
        )
    }

    var body: some View {
        let catalog = model.providerCatalog(for: catalogTarget)?.models.filter(\.available)
        let models = servedModels.flatMap { served in
            catalog?.filter { served.contains(ModelRef(provider: $0.provider, id: $0.id)) }
        }
        Group {
            if let models, models.isEmpty {
                TronPlaceholderState(title: "No Models", detail: "No available model can be used here.", icon: "cpu")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let models {
                ModelPicker(selection: selection, models: models, selectionAvailability: selectionAvailability)
            } else {
                TronSheetLoadingState(label: "Loading models…")
            }
        }
            .tronNavigationTitle(title)
            .toolbar {
                if let onReset {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            guard selectionAvailability.canSelect else { return }
                            onReset(); dismiss()
                        } label: {
                            Image(systemName: "arrow.uturn.backward").tronToolbarAction()
                        }
                        .accessibilityLabel("Reset to inherited")
                        .accessibilityIdentifier("\(settingsRowIdentifier(setting))-picker-reset")
                        .disabled(!selectionAvailability.canSelect)
                    }
                }
            }
            .task { await model.refreshProviders(target: catalogTarget) }
            .task { await readServedPages() }
    }

    private func readServedPages() async {
        var options: [SettingsOption] = []
        var cursor: String?
        var seen: Set<String> = []
        repeat {
            guard let page = try? await model.settingsOptions(target: target, key: setting.key, qualifiers: setting.qualifiers,
                                                              cursor: cursor) else { return }
            options += page.options
            cursor = page.nextCursor
        } while cursor.map { seen.insert($0).inserted } == true
        served = options
    }
}

private struct SettingsRendererTextRow: View {
    let title: String
    let icon: String
    let subtitle: String?
    let example: String?
    let value: String
    let onCommit: (String) -> Void
    @State private var text: String?
    @FocusState private var focused: Bool

    var body: some View {
        TronSettingsRow(icon: icon, title: title, subtitle: subtitle) {
            TextField(title, text: Binding(get: { text ?? value }, set: { text = $0 }),
                      prompt: Text(example ?? "(empty)").foregroundStyle(Color.tronTextMuted))
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .tronInlineField(monospaced: true)
                .multilineTextAlignment(.trailing)
                .frame(minWidth: 100, maxWidth: 220)
                .accessibilityLabel(title)
                .tronTextEntryDone(focus: $focused, onDone: commit)
                .onChange(of: focused) { _, active in if !active { commit() } }
        }
    }

    private func commit() {
        guard let text, text != value else { self.text = nil; return }
        self.text = nil
        onCommit(text)
    }
}

private struct SettingsCatalogPicker: View {
    let setting: ResolvedSetting
    let target: JSONValue
    let title: String
    let onChoose: (JSONValue) -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.tronPresentationActivity) private var presentationActivity
    @State private var options: [SettingsOption]?
    @State private var nextCursor: String?
    @State private var pageCursor: String?
    @State private var consumedCursors: Set<String> = []
    @State private var loadError: String?
    @State private var loading = false
    @State private var requestGeneration = 0
    @State private var reloadTick = 0
    @State private var displayedSource: Source?
    @State private var installedLoad: LoadID?

    private struct Source: Hashable {
        let target: JSONValue
        let key: String
        let qualifiers: [String: String]?
        let identity: KnowledgePresentationIdentity
        let foreground: Int
    }

    private struct LoadID: Hashable {
        let source: Source
        let cursor: String?
        let reloadTick: Int
    }

    private var source: Source {
        Source(target: target, key: setting.key, qualifiers: setting.qualifiers,
               identity: model.knowledgePresentationIdentity, foreground: model.foregroundReconciliationGeneration)
    }

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 8) {
                if let options, displayedSource == source {
                    ForEach(options) { option in
                        TronCatalogOptionRow(
                            title: option.label, summary: option.disabledReason, detail: option.detail,
                            icon: "square.stack.3d.up", isSelected: option.value == setting.value,
                            isEnabled: option.disabledReason == nil
                        ) {
                            guard displayedSource == source else { return }
                            onChoose(option.value)
                            dismiss()
                        }
                        .accessibilityIdentifier("settings-option-\(option.label)")
                    }
                    if options.isEmpty {
                        TronSettingsCaption("No available options").containerValue(\.tronSettingsSection, false)
                    }
                    if let nextCursor {
                        Button { pageCursor = nextCursor } label: {
                            TronInlineActionLabel("Load more", isWorking: loading)
                        }
                        .buttonStyle(.plain)
                        .disabled(loading)
                        .accessibilityIdentifier("settings-catalog-more")
                    }
                }
                if let loadError {
                    TronSettingsCaption(loadError).containerValue(\.tronSettingsSection, false)
                    Button("Try again") { reloadTick &+= 1 }
                        .buttonStyle(.plain)
                } else if options == nil || displayedSource != source {
                    TronSheetLoadingState(label: "Loading…")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .tronScrollEdgeChrome()
        .tronNavigationTitle(title)
        .onChange(of: source) { _, _ in reset() }
        .onChange(of: presentationActivity) { _, _ in requestGeneration &+= 1; loading = false }
        .onDisappear { requestGeneration &+= 1 }
        .task(id: PresentationActivityTaskID(
            source: LoadID(source: source, cursor: pageCursor, reloadTick: reloadTick),
            presentationActive: presentationActivity.allowsPresentationPublication
        )) {
            guard presentationActivity.allowsPresentationPublication,
                  installedLoad != LoadID(source: source, cursor: pageCursor, reloadTick: reloadTick) else { return }
            await load()
        }
    }

    private func reset() {
        requestGeneration &+= 1
        installedLoad = nil
        options = nil
        displayedSource = nil
        pageCursor = nil
        nextCursor = nil
        consumedCursors = []
        loadError = nil
        loading = false
    }

    private func load() async {
        requestGeneration &+= 1
        let ticket = requestGeneration
        let activity = presentationActivity
        let requestedSource = source
        let cursor = pageCursor
        let requested = LoadID(source: requestedSource, cursor: cursor, reloadTick: reloadTick)
        loading = true
        loadError = nil
        @MainActor func isCurrent() -> Bool {
            ticket == requestGeneration && !Task.isCancelled && source == requestedSource
                && activity == presentationActivity && activity.allowsPresentationPublication
        }
        defer { if isCurrent() { loading = false } }
        do {
            let response = try await model.settingsOptions(
                target: requestedSource.target, key: requestedSource.key, qualifiers: requestedSource.qualifiers,
                cursor: cursor
            )
            guard isCurrent() else { return }
            var seen = Set((cursor == nil ? [] : options ?? []).map(\.id))
            let additions = response.options.filter { seen.insert($0.id).inserted }
            options = (cursor == nil ? [] : options ?? []) + additions
            displayedSource = requestedSource
            installedLoad = requested
            if let cursor { consumedCursors.insert(cursor) }
            if let next = response.nextCursor, consumedCursors.contains(next) {
                nextCursor = nil
                loadError = "The catalog could not advance."
            } else {
                nextCursor = response.nextCursor
            }
        } catch is CancellationError {
            return
        } catch {
            guard isCurrent() else { return }
            loadError = error.localizedDescription
        }
    }
}
