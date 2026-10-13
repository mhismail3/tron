import SwiftUI
import TronMobileCore

/// One resolved key, rendered by the control the Gateway negotiated for it
/// (gateway docs/settings-model.md 7.5). The value always shows as the Gateway's
/// `display`; a control this app does not implement renders read-only.
struct SettingsRendererRow: View {
    let setting: ResolvedSetting
    let target: JSONValue
    let editable: Bool
    /// Sub-sheet rows show source, help and actions; primary rows only title and control.
    var detailed = false
    /// One of several instances of a key (per project, per model): titled by its
    /// instance, with the key's label and help on the enclosing group.
    var instanced = false
    /// A row has one control. When its source also offers actions, the row
    /// previews the value and opens this sheet, which holds control and actions.
    var detailDestination: AnyView? = nil
    /// On a key's own sheet: each action is its own full-width row.
    var actionsAsRows = false
    var externalControl = false
    /// Changes when a key this row's options depend on changes, so they are re-requested.
    let dependencyDisplay: String
    let error: String?
    /// "Edit at Mac/Project" for a key this surface cannot write.
    var layerEditorTitle: String? = nil
    var onEditLayer: () -> Void = {}
    let onChange: (JSONValue?) -> Void
    /// Apply again on an outside change this row's badge names (settings-model.md 5.6).
    var onApplyAgain: ((String) -> Void)? = nil

    @Environment(AppModel.self) private var model
    @Environment(\.tronPresentationActivity) private var presentationActivity
    @State private var options: [SettingsOption]?
    @State private var dynamicRange: SettingsRange?
    @State private var optionsGeneration = 0

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

    /// Detailed rows carry their sources as tags beside the title. An instance's
    /// scope is its title, so it is not repeated as a tag.
    private var tags: [TronTagModel] {
        guard detailed else { return [] }
        return setting.badges.filter { !(instanced && $0.kind == "scope") }.map(TronTagModel.init)
    }
    private var control: SettingsRowControl {
        editable && !externalControl ? SettingsRowControl(negotiated: presentation?.control) : .readOnly
    }

    private struct OptionsLoadID: Hashable {
        let key: String
        let target: JSONValue
        let dependencies: String
        let foreground: Int
    }

    /// The key's help and note, on detailed rows only; an instance's help is on its group.
    private var subtitle: String? {
        guard detailed else { return nil }
        let lines = [instanced ? "" : presentation?.help ?? "", presentation?.note ?? ""].filter { !$0.isEmpty }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
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
        presentation?.optionsSource == nil ? presentation?.range : dynamicRange
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            controlRow.tronSettingsRowTags(tags)
            details
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(settingsRowIdentifier(setting))
        // Each source with its detail ("Changed outside Tron, Mac: On → Off"); the
        // visible line names sources only. Primary rows carry no source.
        .accessibilityValue(detailed ? setting.badges.map { badge in
            badge.detail.map { "\(badge.label), \($0)" } ?? badge.label
        }.joined(separator: " · ") : "")
        .onChange(of: dependencyDisplay) { _, _ in
            optionsGeneration &+= 1
            options = nil
            dynamicRange = nil
        }
        .onChange(of: presentationActivity) { _, _ in
            optionsGeneration &+= 1
            options = nil
            dynamicRange = nil
        }
        .onDisappear { optionsGeneration &+= 1 }
        .task(id: PresentationActivityTaskID(
            source: OptionsLoadID(key: setting.id, target: target, dependencies: dependencyDisplay,
                                  foreground: model.foregroundReconciliationGeneration),
            presentationActive: presentationActivity.allowsPresentationPublication
        )) {
            guard presentation?.optionsSource != nil, [.choice, .number, .checklist].contains(control),
                  presentationActivity.allowsPresentationPublication else { return }
            await loadOptions()
        }
    }

    @ViewBuilder
    private var controlRow: some View {
        if let detailDestination {
            TronProgressiveSheetLink(accessibilityLabel: title, identity: "settings.key.\(setting.id)") {
                detailDestination
            } label: {
                TronSettingsRow(icon: icon, title: title, subtitle: subtitle) {
                    TronDynamicValue(text: setting.display, color: .tronTextSecondary)
                }
            }
            .accessibilityIdentifier("\(settingsRowIdentifier(setting))-open")
        } else {
            control(for: control)
        }
    }

    @ViewBuilder
    private func control(for control: SettingsRowControl) -> some View {
        switch control {
        case .toggle:
            TronToggleRow(icon: icon, title: title, detail: subtitle,
                          isOn: Binding(get: { setting.value?.boolValue == true }, set: { onChange(.bool($0)) }))
        case .choice:
            let choices = presentation?.optionsSource != nil ? (options ?? []) : (presentation?.options?.map {
                SettingsOption(value: $0.value, label: $0.label, detail: nil, disabledReason: nil)
            } ?? [])
            if choices.isEmpty {
                // A source with nothing to offer (a model that does not think) is a value, not a menu.
                readOnlyRow
            } else if presentation?.valueKind == "orderedChoice", let value = setting.value {
                SettingsChoiceSelectionRow(title: title, icon: icon, value: value,
                                           display: setting.display, options: choices, information: subtitle,
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
                    SettingsNumberSelectionRow(title: title, value: value, display: setting.display, range: range,
                                               icon: icon, information: subtitle) {
                        onChange(.number(Double($0)))
                    }
                    .controlSize(.small)
                } else if setting.value == nil {
                    // Unset: the slider still opens. A token limit's unset value is the
                    // served maximum (the model's capacity), its reference "Default".
                    let tokens = range.unit == "tokens"
                    SettingsNumberSelectionRow(title: title, value: Int(tokens ? range.max : range.min), display: setting.display,
                                               range: range, icon: icon, information: subtitle,
                                               actionDisplay: setting.display,
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
            SettingsRendererTextRow(title: title, icon: icon, subtitle: subtitle, value: setting.value?.stringValue ?? "", onCommit: { onChange(.string($0)) })
        case .secret:
            TronSelectionSheetRow(icon: icon, title: title, detail: subtitle, value: setting.display) {
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
                TronSelectionSheetRow(icon: icon, title: title, detail: subtitle, value: setting.display) {
                    SettingsNumberMapEditor(title: title, help: presentation?.help ?? "", fields: fields,
                                            range: range, values: setting.value?.objectValue ?? [:], onChange: onChange)
                }
            } else if presentation?.valueKind == "stringList",
               setting.value == nil || setting.value?.arrayValue?.allSatisfy({ $0.stringValue != nil }) == true {
                let values = setting.value?.arrayValue ?? []
                TronSelectionSheetRow(icon: icon, title: title, detail: subtitle, value: setting.display) {
                    SettingsListEditor(title: title, help: presentation?.help ?? "",
                                       values: values.compactMap(\.stringValue), onChange: onChange)
                }
            } else {
                readOnlyRow
            }
        case .checklist:
            if let values = setting.value?.arrayValue, values.allSatisfy({ $0.stringValue != nil }) {
                TronSelectionSheetRow(icon: icon, title: title, detail: subtitle, value: setting.display) {
                    TronChecklistPicker(
                        title: title, help: presentation?.help,
                        choices: options?.compactMap { option in option.value.stringValue.map {
                            TronChoice(id: $0, label: option.label, detail: option.detail, disabledReason: option.disabledReason)
                        } },
                        selected: values.compactMap(\.stringValue)
                    ) { onChange(.array($0.map(JSONValue.string))) }
                }
            } else {
                readOnlyRow
            }
        case .catalog:
            TronSelectionSheetRow(icon: icon, title: title, detail: subtitle, value: setting.display) {
                SettingsCatalogPicker(setting: setting, target: target, title: title) { onChange($0) }
            }
        case .readOnly:
            readOnlyRow
        }
    }

    /// A value this surface shows but does not edit. When another scope owns it,
    /// the value is a right-aligned link to that scope's editor.
    private var readOnlyRow: some View {
        TronSettingsRow(icon: icon, title: title, subtitle: subtitle) {
            if let layerEditorTitle {
                Button(action: onEditLayer) { TronInlineActionLabel(setting.display, icon: "arrow.up.forward") }
                    .buttonStyle(.plain)
                    .accessibilityLabel(layerEditorTitle)
                    .accessibilityValue(setting.display)
                    .accessibilityIdentifier("\(settingsRowIdentifier(setting))-edit-layer")
            } else {
                TronDynamicValue(text: setting.display, color: .tronTextSecondary)
                    .textSelection(.enabled)
            }
        }
    }

    /// A key's actions, as full-width rows on its own sheet (`actionsAsRows`), and
    /// any refusal under the row wherever the change was attempted.
    @ViewBuilder
    private var details: some View {
        let actions = actionsAsRows ? setting.badges.compactMap(\.action) : []
        let resets = editable && (control != .readOnly || externalControl)
            ? actions.filter { ["useCurrentDefault", "followDefault"].contains($0.kind) } : []
        let applyAgain = onApplyAgain == nil ? [] : actions.filter { $0.kind == "applyAgain" && $0.changeId != nil }
        // Action primitives are served with the source badge. A future action stays
        // absent, never an arbitrary RPC; reset reuses the row's dry-run and receipt
        // owner, Apply again the change record.
        ForEach(Array(resets.enumerated()), id: \.offset) { _, action in
            TronSettingsDivider()
            Button { onChange(nil) } label: {
                TronSettingsRow(icon: "arrow.uturn.backward", title: action.label)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("\(settingsRowIdentifier(setting))-\(action.kind)")
        }
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

    private func loadOptions() async {
        optionsGeneration &+= 1
        let ticket = optionsGeneration
        let activity = presentationActivity
        let identity = model.knowledgePresentationIdentity
        let foreground = model.foregroundReconciliationGeneration
        // Never keep choices for a previous dependency value visible while its replacement loads.
        options = nil
        dynamicRange = nil
        @MainActor func isCurrent() -> Bool {
            ticket == optionsGeneration && !Task.isCancelled
                && activity == presentationActivity && activity.allowsPresentationPublication
                && identity == model.knowledgePresentationIdentity
                && foreground == model.foregroundReconciliationGeneration
        }
        do {
            let response = try await model.settingsOptions(target: target, key: setting.key, qualifiers: setting.qualifiers, query: nil)
            guard isCurrent() else { return }
            options = response.options
            dynamicRange = response.range
        } catch {
            // Options are disposable; stale failures must not publish or hide a newer result.
            guard isCurrent() else { return }
        }
    }
}

/// A text value committed when editing ends; the Gateway validates it.
private struct SettingsRendererTextRow: View {
    let title: String
    let icon: String
    let subtitle: String?
    let value: String
    let onCommit: (String) -> Void
    @State private var text: String?
    @FocusState private var focused: Bool

    var body: some View {
        TronSettingsRow(icon: icon, title: title, subtitle: subtitle) {
            TextField(title, text: Binding(get: { text ?? value }, set: { text = $0 }),
                      prompt: Text("(empty)").foregroundStyle(Color.tronTextMuted))
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .tronInlineField(monospaced: true)
                .multilineTextAlignment(.trailing)
                .frame(minWidth: 100, maxWidth: 220)
                .accessibilityLabel(title)
                .focused($focused)
                .onSubmit(commit)
                .onChange(of: focused) { _, active in if !active { commit() } }
        }
    }

    private func commit() {
        guard let text, text != value else { self.text = nil; return }
        self.text = nil
        onCommit(text)
    }
}

/// A searchable, paged catalog over the Gateway's option source. Presentation
/// uses the same option row as ModelPicker; values and cursors remain opaque.
private struct SettingsCatalogPicker: View {
    let setting: ResolvedSetting
    let target: JSONValue
    let title: String
    let onChoose: (JSONValue) -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.tronPresentationActivity) private var presentationActivity
    @State private var query = ""
    @State private var options: [SettingsOption]?
    @State private var nextCursor: String?
    @State private var pageCursor: String?
    @State private var consumedCursors: Set<String> = []
    @State private var loadError: String?
    @State private var loading = false
    @State private var requestGeneration = 0
    @State private var reloadTick = 0
    @State private var displayedSource: Source?

    private struct Source: Hashable {
        let target: JSONValue
        let key: String
        let qualifiers: [String: String]?
        let query: String
        let identity: KnowledgePresentationIdentity
        let foreground: Int
    }

    private struct LoadID: Hashable {
        let source: Source
        let cursor: String?
        let reloadTick: Int
    }

    private var source: Source {
        Source(target: target, key: setting.key, qualifiers: setting.qualifiers, query: query,
               identity: model.knowledgePresentationIdentity, foreground: model.foregroundReconciliationGeneration)
    }

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 8) {
                if let options, displayedSource == source {
                    // Only choices this account can use (a model catalog lists every
                    // provider's models); the current value stays visible even if not.
                    ForEach(options.filter { $0.disabledReason == nil || $0.value == setting.value }) { option in
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
                    if !options.contains(where: { $0.disabledReason == nil || $0.value == setting.value }) {
                        TronSettingsCaption(query.isEmpty ? "No available options" : "No options match this search")
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
                    TronLoadingState(label: "Loading…")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .tronScrollEdgeChrome()
        .tronFloatingSearch(text: $query)
        .tronNavigationTitle(title)
        .onChange(of: source) { _, _ in reset() }
        .onChange(of: presentationActivity) { _, _ in reset() }
        .onDisappear { requestGeneration &+= 1 }
        .task(id: PresentationActivityTaskID(
            source: LoadID(source: source, cursor: pageCursor, reloadTick: reloadTick),
            presentationActive: presentationActivity.allowsPresentationPublication
        )) {
            guard presentationActivity.allowsPresentationPublication else { return }
            await load()
        }
    }

    private func reset() {
        requestGeneration &+= 1
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
        loading = true
        loadError = nil
        if cursor == nil {
            options = nil
            nextCursor = nil
            consumedCursors = []
        }
        @MainActor func isCurrent() -> Bool {
            ticket == requestGeneration && !Task.isCancelled && source == requestedSource
                && activity == presentationActivity && activity.allowsPresentationPublication
        }
        defer { if isCurrent() { loading = false } }
        do {
            let response = try await model.settingsOptions(
                target: requestedSource.target, key: requestedSource.key, qualifiers: requestedSource.qualifiers,
                query: requestedSource.query.isEmpty ? nil : requestedSource.query, cursor: cursor
            )
            guard isCurrent() else { return }
            // Values identify rows across pages; overlapping server pages must
            // not duplicate SwiftUI identity or reorder already-visible choices.
            var seen = Set((cursor == nil ? [] : options ?? []).map(\.id))
            let additions = response.options.filter { seen.insert($0.id).inserted }
            options = (cursor == nil ? [] : options ?? []) + additions
            displayedSource = requestedSource
            if let cursor { consumedCursors.insert(cursor) }
            if let next = response.nextCursor, consumedCursors.contains(next) {
                nextCursor = nil
                loadError = "The catalog could not advance. Search to narrow the results."
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
