import SwiftUI
import TronMobileCore

/// One resolved key, rendered by the control the Gateway negotiated for it
/// (gateway docs/settings-model.md 7.5). The value always shows as the Gateway's
/// `display`; a control this app does not implement renders read-only.
struct SettingsRendererRow: View {
    let setting: ResolvedSetting
    let target: JSONValue
    let editable: Bool
    /// Detailed rows show help; every key's body opens the shared Value & Source sheet.
    var detailed = false
    /// One of several instances of a key (per project, per model): titled by its
    /// instance, with the key's label and help on the enclosing group.
    var instanced = false
    /// Configuration inspection adds a concise application/source summary;
    /// precise layers and launch evidence remain in Value & Source.
    var inspecting = false
    /// Reset removes the owned layer's override, never copies an inherited value.
    var canReset = false
    /// An instance's own description, when its group's help does not say it
    /// (an approval level describes the setting it governs).
    var instanceHelp: String? = nil
    /// The options the key's source serves, read by the renderer with the
    /// resolution itself, so a row is never without them once it renders.
    let options: SettingsOptionsResponse?
    let error: String?
    let onChange: (JSONValue?) -> Void
    /// Apply again on an outside change this row's badge names (settings-model.md 5.6).
    var onApplyAgain: ((String) -> Void)? = nil

    @Environment(AppModel.self) private var model
    @Environment(\.tronSettingsVisualTheme) private var theme

    private var presentation: SettingsKeyPresentation? { setting.presentation }
    private var title: String {
        instanced ? (Self.instanceName(setting) ?? presentation?.label ?? setting.key) : (presentation?.label ?? setting.key)
    }

    /// An instance's name: its scope ("tron" for a project path), else its qualifiers.
    static func instanceName(_ setting: ResolvedSetting) -> String? {
        if let scope = setting.badge("scope")?.label {
            return scope.hasPrefix("/") ? URL(fileURLWithPath: scope).lastPathComponent : scope
        }
        let values = (setting.qualifiers ?? [:]).sorted { $0.key < $1.key }.map(\.value)
        return values.isEmpty ? nil : values.joined(separator: " · ")
    }

    private var control: SettingsRowControl {
        editable ? SettingsRowControl(negotiated: presentation?.control) : .readOnly
    }

    /// The key's help and note, on detailed rows only; an instance's help is on its group.
    private var subtitle: String? {
        guard detailed else { return nil }
        // An instance is titled by its short name; its full scope (a project's path)
        // describes it when nothing else does.
        let scope = setting.badge("scope")?.label
        let instanceLine = instanceHelp ?? (scope != title ? scope : nil) ?? ""
        let lines = [instanced ? instanceLine : presentation?.help ?? "", presentation?.note ?? "",
                     inspecting ? applicationSummary : ""].filter { !$0.isEmpty }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    private var applicationSummary: String {
        let source = setting.badge("source")?.label ?? settingsLayerLabel(setting.layer)
        if setting.applied == false { return "\(source) · Not applied" }
        switch setting.origin {
        case "launch": return "\(source) · Retained launch value"
        case "legacy-session": return "Retained session value · Launch source unavailable"
        default: return source
        }
    }

    /// A text row's subtitle also says what to type, on rows that show help.
    private var entrySubtitle: String? {
        guard detailed, let hint = presentation?.entry?.hint else { return subtitle }
        return [subtitle, hint].compactMap { $0 }.joined(separator: "\n")
    }

    /// Every row carries a glyph so titles align; the glyph names the control kind.
    private var icon: String {
        switch control {
        case .toggle: "switch.2"
        case .number: "number"
        case .text: "character.cursor.ibeam"
        case .secret: "key"
        case .list: "list.bullet"
        case .checklist: "checklist"
        case .catalog: "square.stack.3d.up"
        case .choice, .readOnly: "slider.horizontal.3"
        }
    }

    private var numberRange: SettingsRange? {
        presentation?.optionsSource == nil ? presentation?.range : options?.range
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            control(for: control)
                .environment(\.tronSettingsRowInspection, inspection)
                .environment(\.tronSettingsRowAccessory, accessory)
            details
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(settingsRowIdentifier(setting))
    }

    private var inspection: TronSettingsRowInspection {
        return TronSettingsRowInspection(
            label: "Value and source for \(title)",
            identifier: "\(settingsRowIdentifier(setting))-source",
            destination: { AnyView(SettingsProvenanceView(setting: setting)) }
        )
    }

    private var accessory: (@MainActor @Sendable () -> AnyView)? {
        guard canReset && editable && control != .readOnly else { return nil }
        return { AnyView(resetButton) }
    }

    private var resetLabel: String {
        setting.badges.compactMap(\.action).first { ["useCurrentDefault", "followDefault"].contains($0.kind) }?.label ?? "Reset to inherited"
    }

    private var resetButton: some View {
        Button { onChange(nil) } label: {
            TronInlineActionLabel("", icon: "arrow.uturn.backward", accent: theme?.accent ?? .tronEmerald)
        }
            .controlSize(.small)
            .buttonStyle(.plain)
            .accessibilityLabel(resetLabel)
            .accessibilityHint("Remove the override for \(title) and use its inherited value.")
            .accessibilityIdentifier("\(settingsRowIdentifier(setting))-reset")
    }

    /// An absent optional value is not a second provenance statement.
    private var display: String { setting.value == nil && setting.display == "Not set" && presentation?.redacted != true ? "—" : setting.display }

    @ViewBuilder
    private func control(for control: SettingsRowControl) -> some View {
        switch control {
        case .toggle:
            TronSettingsRow(icon: icon, title: title, subtitle: subtitle) {
                Button { onChange(.bool(setting.value?.boolValue != true)) } label: {
                    TronToggleControl(isOn: setting.value?.boolValue == true, accent: theme?.accent ?? .tronEmerald)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityRepresentation {
                    Toggle(isOn: Binding(get: { setting.value?.boolValue == true },
                                         set: { onChange(.bool($0)) })) { Text(title) }
                        .accessibilityHint(subtitle ?? "")
                }
            }
        case .choice:
            let choices = presentation?.optionsSource != nil ? (options?.options ?? []) : (presentation?.options?.map {
                SettingsOption(value: $0.value, label: $0.label, detail: $0.detail, disabledReason: nil, resource: nil)
            } ?? [])
            if choices.isEmpty {
                // A source with nothing to offer (a model that does not think) is a value, not a menu.
                readOnlyRow
            } else if presentation?.valueKind == "orderedChoice", let value = setting.value {
                SettingsChoiceSelectionRow(title: title, icon: icon, value: value,
                                           display: display, options: choices, information: subtitle,
                                           onChange: { onChange($0) })
                    .controlSize(.small)
            } else {
                // A picker sheet, not a Menu: section sub-sheets are presented from
                // other sheets, where SwiftUI menus fail to open (#877).
                TronChoiceRow(icon: icon, title: title, detail: subtitle,
                              choices: choices.map { TronChoice(id: $0.value, label: $0.label, detail: $0.detail,
                                                                disabledReason: $0.disabledReason) },
                              selected: setting.value) { onChange($0) }
            }
        case .number:
            if let range = numberRange, range.supportsIntegerSlider {
                if case .number(let raw) = setting.value, let value = Int(exactly: raw) {
                    SettingsNumberSelectionRow(title: title, value: value, display: display, range: range,
                                               icon: icon, information: subtitle) {
                        onChange(.number(Double($0)))
                    }
                    .controlSize(.small)
                } else if setting.value == nil {
                    // Unset: the slider still opens. A token limit's unset value is the
                    // served maximum (the model's capacity), its reference "Default".
                    let tokens = range.unit == "tokens"
                    SettingsNumberSelectionRow(title: title, value: Int(tokens ? range.max : range.min), display: display,
                                               range: range, icon: icon, information: subtitle,
                                               actionDisplay: display,
                                               referenceValue: tokens ? Int(range.max) : nil) {
                        onChange(.number(Double($0)))
                    }
                    .controlSize(.small)
                } else {
                    readOnlyRow
                }
            } else {
                readOnlyRow
            }
        case .text:
            SettingsRendererTextRow(title: title, icon: icon, subtitle: entrySubtitle, example: presentation?.entry?.example,
                                    value: setting.value?.stringValue ?? "", onCommit: { onChange(.string($0)) })
        case .secret:
            TronSelectionSheetRow(icon: icon, title: title, detail: subtitle, value: display) {
                SettingsSecretEditor(title: title, help: presentation?.help ?? "", onChange: onChange)
            }
        case .list:
            if presentation?.valueKind == "numberMap", let fields = presentation?.options,
               !fields.isEmpty, fields.count <= 64,
               fields.allSatisfy({ $0.value.stringValue != nil }),
               Set(fields.compactMap { $0.value.stringValue }).count == fields.count,
               Set((setting.value?.objectValue ?? [:]).keys).isSubset(of: Set(fields.compactMap { $0.value.stringValue })),
               let range = presentation?.range, range.supportsIntegerSlider,
               setting.value == nil || setting.value?.objectValue?.values.allSatisfy({ value in
                   if case .number(let number) = value { return Int(exactly: number) != nil }
                   return false
               }) == true {
                TronSelectionSheetRow(icon: icon, title: title, detail: subtitle, value: display) {
                    SettingsNumberMapEditor(title: title, help: presentation?.help ?? "", fields: fields,
                                            range: range, values: setting.value?.objectValue ?? [:], onChange: onChange)
                }
            } else if presentation?.valueKind == "stringList",
               setting.value == nil || setting.value?.arrayValue?.allSatisfy({ $0.stringValue != nil }) == true {
                let values = setting.value?.arrayValue ?? []
                TronSelectionSheetRow(icon: icon, title: title, detail: subtitle, value: display) {
                    SettingsListEditor(title: title, help: presentation?.help ?? "", entry: presentation?.entry,
                                       values: values.compactMap(\.stringValue), entryPicker: modelEntryPicker, onChange: onChange)
                }
            } else {
                readOnlyRow
            }
        case .checklist:
            // A tool catalog opens the shared Available Tools list and details (#900).
            if presentation?.optionsSource?.name == "catalog.tools", let options, let values = setting.value?.arrayValue,
               values.allSatisfy({ $0.stringValue != nil }) {
                TronSelectionSheetRow(icon: icon, title: title, detail: subtitle, value: display) {
                    SettingsToolsEditor(title: title, selected: values.compactMap(\.stringValue),
                                        options: options.options) { onChange(.array($0.map(JSONValue.string))) }
                }
            } else if presentation?.optionsSource?.name != "catalog.tools", let values = setting.value?.arrayValue,
                      values.allSatisfy({ $0.stringValue != nil }) {
                TronSelectionSheetRow(icon: icon, title: title, detail: subtitle, value: display) {
                    TronChecklistPicker(
                        title: title, help: presentation?.help,
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
                if presentation?.optionsSource?.name == "catalog.models" {
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

    /// A list of `provider/id` model references (a model queue) adds from the
    /// shared model picker, limited to the models the Gateway serves for the key.
    private var modelEntryPicker: ((@escaping (String) -> Void) -> AnyView)? {
        guard presentation?.optionsSource?.name == "catalog.models" else { return nil }
        return { add in
            AnyView(SettingsModelPicker(setting: setting, target: target, title: "Add model") { value in
                guard let provider = value.objectValue?["provider"]?.stringValue, let id = value.objectValue?["id"]?.stringValue else { return }
                add("\(provider)/\(id)")
            })
        }
    }

    /// Inspection never offers a shortcut to a different configuration editor.
    @ViewBuilder
    private var readOnlyRow: some View {
        if presentation?.optionsSource?.name == "catalog.tools", let values = setting.value?.arrayValue?.compactMap(\.stringValue) {
            TronSelectionSheetRow(icon: icon, title: title, detail: subtitle, value: display) {
                SettingsToolsEditor(title: title, selected: values, options: options?.options ?? values.map {
                    SettingsOption(value: .string($0), label: $0, detail: nil, disabledReason: nil, resource: nil)
                })
            }
        } else {
            TronSettingsRow(icon: icon, title: title, subtitle: subtitle) {
                TronDynamicValue(text: display, color: .tronTextSecondary)
                    .textSelection(.enabled)
            }
        }
    }

    /// Outside-change recovery remains an explicit action; resets live beside
    /// every owned control, and refusals stay under the attempted row.
    @ViewBuilder
    private var details: some View {
        let actions = setting.badges.compactMap(\.action)
        let applyAgain = onApplyAgain == nil ? [] : actions.filter { $0.kind == "applyAgain" && $0.changeId != nil }
        // Action primitives are served with the source badge. A future action stays
        // absent, never an arbitrary RPC; reset reuses the row's dry-run and receipt
        // owner, Apply again the change record.
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

/// Read-only provenance for one key. Layers are values from their owners, never audit entries.
private struct SettingsProvenanceView: View {
    let setting: ResolvedSetting

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                TronSettingsGroup("Effective value", detail: setting.presentation?.help) {
                    TronSettingsRow(icon: "checkmark.circle", title: setting.presentation?.label ?? setting.key,
                                    subtitle: setting.badge("source")?.detail ?? setting.badge("layer")?.label) {
                        TronDynamicValue(text: setting.display, color: .tronTextSecondary)
                    }
                    ForEach((setting.qualifiers ?? [:]).sorted { $0.key < $1.key }, id: \.key) { qualifier in
                        TronSettingsDivider()
                        TronSettingsRow(icon: "scope", title: qualifier.key.capitalized) {
                            TronDynamicValue(text: qualifier.value, color: .tronTextSecondary)
                        }
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("settings-provenance-effective")
                TronSettingsGroup("Configuration sources", detail: "Highest priority first. Unset layers inherit; history is not a source.") {
                    ForEach(Array(setting.layers.enumerated()), id: \.offset) { index, layer in
                        if index > 0 { TronSettingsDivider() }
                        TronSettingsRow(icon: "square.3.layers.3d", title: settingsLayerLabel(layer.layer),
                                        subtitle: layer.applied == false ? "Not applied · untrusted repository" : nil) {
                            TronDynamicValue(text: layer.display ?? "Inherited", color: .tronTextSecondary)
                        }
                    }
                }
                let evidence = setting.badges.filter { $0.kind != "layer" }
                if !evidence.isEmpty {
                    TronSettingsGroup("Application & provenance") {
                        ForEach(Array(evidence.enumerated()), id: \.offset) { index, badge in
                            if index > 0 { TronSettingsDivider() }
                            TronSettingsRow(icon: "info.circle", title: badge.label, subtitle: badge.detail)
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("settings-provenance-evidence")
                }
                if let effect = setting.presentation?.effect {
                    TronSettingsCaption("Application boundary: \(effect).")
                }
                if setting.origin == "launch" {
                    TronSettingsCaption("This retained launch value remains applied until explicitly reset or changed. Values in lower source layers are current defaults, not proof of what was used at launch.")
                } else if setting.origin == "legacy-session" {
                    TronSettingsCaption("This session retained the value without attributable launch provenance. Its original source is unknown.")
                }
            }.padding(20)
        }
        .tronScrollEdgeChrome()
        .tronNavigationTitle("Value & Source")
    }
}

func settingsLayerLabel(_ layer: String) -> String {
    switch layer {
    case "chat": "Session"
    case "profile": "Home profile"
    case "project": "Repository"
    case "mac": "Mac"
    case "builtin": "Built-in"
    default: layer.capitalized
    }
}

/// A model key (`catalog.models`) uses the app's one model picker over the
/// configured providers' catalog, like every other model choice in the app.
/// Choosing sends the model reference through the row's change owner.
/// A model key's choices in the shared ModelPicker. The Gateway decides which
/// models the key accepts (Home's memory takes no virtual model); the provider
/// catalog supplies how each one is shown.
private struct SettingsModelPicker: View {
    let setting: ResolvedSetting
    let target: JSONValue
    let title: String
    var onReset: (() -> Void)? = nil
    let onChoose: (JSONValue) -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var served: [SettingsOption]?

    /// Every model the Gateway serves for the key, once each page is read.
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
                guard let ref else { return }
                // A pick closes the picker, as every settings choice does.
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
                ModelPicker(selection: selection, models: models)
            } else {
                TronSheetLoadingState(label: "Loading models…")
            }
        }
            .tronNavigationTitle(title)
            .toolbar {
                if let onReset {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { onReset(); dismiss() } label: {
                            Image(systemName: "arrow.uturn.backward").tronToolbarAction()
                        }
                        .accessibilityLabel("Reset to inherited")
                        .accessibilityIdentifier("\(settingsRowIdentifier(setting))-picker-reset")
                    }
                }
            }
            // Reads the catalog; it never asks providers to refresh their model lists.
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

/// A text value committed when editing ends; the Gateway validates it.
private struct SettingsRendererTextRow: View {
    let title: String
    let icon: String
    let subtitle: String?
    /// The schema's realistic example, as the empty field's placeholder.
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

/// A paged catalog over the Gateway's option source. Presentation
/// uses the same option row as ModelPicker; values and cursors remain opaque.
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
    /// The read whose result is on screen; the same read never runs twice.
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
                        TronSettingsCaption("No available options")
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
                    TronSettingsCaption(loadError)
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
        // A covering sheet retires the read in flight; what is shown stays.
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
            // Values identify rows across pages; overlapping server pages must
            // not duplicate SwiftUI identity or reorder already-visible choices.
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
