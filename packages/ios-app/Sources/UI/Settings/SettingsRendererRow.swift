import SwiftUI
import TronMobileCore

/// One resolved key, rendered by the control the Gateway negotiated for it
/// (gateway docs/settings-model.md 7.5). The value always shows as the Gateway's
/// `display`; a control this app does not implement renders read-only.
struct SettingsRendererRow: View {
    let setting: ResolvedSetting
    let target: JSONValue
    let editable: Bool
    /// Changes when a key this row's options depend on changes, so they are re-requested.
    let dependencyDisplay: String
    let error: String?
    let onChange: (JSONValue?) -> Void

    @Environment(AppModel.self) private var model
    @State private var options: [SettingsOption]?
    @State private var showsHelp = false

    private var presentation: SettingsKeyPresentation? { setting.presentation }
    private var title: String { presentation?.label ?? setting.key }
    private var control: SettingsRowControl {
        editable ? SettingsRowControl(negotiated: presentation?.control) : .readOnly
    }

    private struct OptionsLoadID: Hashable {
        let key: String
        let dependencies: String
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            controlRow
            details
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(settingsRowIdentifier(setting))
        .task(id: OptionsLoadID(key: setting.id, dependencies: dependencyDisplay)) {
            guard presentation?.optionsSource != nil, control == .choice else { return }
            await loadOptions()
        }
    }

    @ViewBuilder
    private var controlRow: some View {
        switch control {
        case .toggle:
            TronToggleRow(icon: "switch.2", title: title, detail: setting.display,
                          isOn: Binding(get: { setting.value?.boolValue == true }, set: { onChange(.bool($0)) }))
        case .choice:
            let choices = options ?? presentation?.options?.map {
                SettingsOption(value: $0.value, label: $0.label, detail: nil, disabledReason: nil)
            } ?? []
            if choices.isEmpty {
                // A source with nothing to offer (a model that does not think) is a value, not a menu.
                readOnlyRow(subtitle: options == nil ? nil : "No options for the current choice")
            } else if presentation?.valueKind == "orderedChoice", let value = setting.value {
                SettingsChoiceSelectionRow(title: title, icon: "slider.horizontal.3", value: value,
                                           display: setting.display, options: choices, onChange: { onChange($0) })
                    .controlSize(.small)
            } else {
                TronSelectionRow(icon: "list.bullet", title: title, value: setting.display) {
                    ForEach(choices) { option in
                        Button(option.label) { onChange(option.value) }
                            .disabled(option.disabledReason != nil)
                    }
                }
            }
        case .number:
            TronNumberSettingRow(icon: "number", title: title, detail: rangeText,
                                 value: Binding(get: { setting.value?.intValue ?? 0 }, set: { onChange(.number(Double($0))) }))
        case .text:
            SettingsRendererTextRow(title: title, value: setting.value?.stringValue ?? "", onCommit: { onChange(.string($0)) })
        case .secret:
            TronSelectionSheetRow(icon: "lock", title: title, value: setting.display) {
                SettingsSecretEditor(title: title, help: presentation?.help ?? "", onChange: onChange)
            }
        case .list:
            if ["stringList", "toolSelection"].contains(presentation?.valueKind ?? ""),
               setting.value == nil || setting.value?.arrayValue?.allSatisfy({ $0.stringValue != nil }) == true {
                let values = setting.value?.arrayValue ?? []
                TronSelectionSheetRow(icon: "list.bullet", title: title, value: setting.display) {
                    SettingsListEditor(title: title, help: presentation?.help ?? "",
                                       values: values.compactMap(\.stringValue), onChange: onChange)
                }
            } else {
                readOnlyRow(subtitle: "Update Tron to edit this list")
            }
        case .catalog:
            TronSelectionSheetRow(icon: "square.stack.3d.up", title: title, value: setting.display) {
                SettingsCatalogPicker(setting: setting, target: target, title: title) { onChange($0) }
            }
        case .readOnly:
            readOnlyRow(subtitle: nil)
        }
    }

    private func readOnlyRow(subtitle: String?) -> some View {
        TronSettingsRow(icon: nil, title: title, subtitle: subtitle) {
            Text(setting.display)
                .font(TronTypography.body)
                .foregroundStyle(Color.tronTextSecondary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }

    private var rangeText: String? {
        guard let range = presentation?.range else { return nil }
        let unit = range.unit.map { " \($0)" } ?? ""
        return "\(Int(range.min))–\(Int(range.max))\(unit)"
    }

    @ViewBuilder
    private var details: some View {
        let badges = setting.badges
        let note = presentation?.note
        if !badges.isEmpty || note != nil || error != nil || presentation?.help.isEmpty == false {
            VStack(alignment: .leading, spacing: 6) {
                if !badges.isEmpty || presentation?.help.isEmpty == false {
                    HStack(spacing: 6) {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 6) { ForEach(Array(badges.enumerated()), id: \.offset) { SettingsBadgeView(badge: $0.element) } }
                            VStack(alignment: .leading, spacing: 4) { ForEach(Array(badges.enumerated()), id: \.offset) { SettingsBadgeView(badge: $0.element) } }
                        }
                        Spacer(minLength: 0)
                        if let help = presentation?.help, !help.isEmpty {
                            Button { showsHelp.toggle() } label: {
                                Image(systemName: showsHelp ? "info.circle.fill" : "info.circle")
                                    .foregroundStyle(Color.tronTextSecondary)
                                    .frame(minWidth: 44, minHeight: 32)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(showsHelp ? "Hide help for \(title)" : "Help for \(title)")
                        }
                    }
                }
                if showsHelp, let help = presentation?.help {
                    TronSettingsCaption(help)
                }
                if let note {
                    Text(note)
                        .font(TronTypography.secondaryDescription)
                        .foregroundStyle(Color.tronTextSecondary)
                        .accessibilityIdentifier("\(settingsRowIdentifier(setting))-note")
                }
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(TronTypography.secondaryDescription)
                        .foregroundStyle(Color.tronError)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("\(settingsRowIdentifier(setting))-error")
                }
            }
            .padding(.horizontal, TronSettingsLayoutPolicy.rowHorizontalPadding)
            .padding(.bottom, 12)
        }
    }

    private func loadOptions() async {
        do {
            let response = try await model.settingsOptions(target: target, key: setting.key, qualifiers: setting.qualifiers, query: nil)
            guard !Task.isCancelled else { return }
            options = response.options
        } catch {
            // The row stays on its static choices or its display; options are a disposable read.
        }
    }
}

/// A text value committed when editing ends; the Gateway validates it.
private struct SettingsRendererTextRow: View {
    let title: String
    let value: String
    let onCommit: (String) -> Void
    @State private var text: String?
    @FocusState private var focused: Bool

    var body: some View {
        TronSettingsRow(icon: "text.cursor", title: title) {
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

/// A searchable picker over a Gateway-served catalog (`settings.options`).
private struct SettingsCatalogPicker: View {
    let setting: ResolvedSetting
    let target: JSONValue
    let title: String
    let onChoose: (JSONValue) -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var options: [SettingsOption]?
    @State private var loadError: String?

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 16) {
                TronSearchBar(text: $query, prompt: "Search")
                if let options {
                    TronGlassCard {
                        ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
                            if index > 0 { TronSettingsDivider() }
                            Button {
                                onChoose(option.value)
                                dismiss()
                            } label: {
                                TronSettingsRow(icon: nil, title: option.label, subtitle: option.disabledReason ?? option.detail) {
                                    if option.value == setting.value {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(Color.tronEmerald)
                                            .accessibilityLabel("Selected")
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .disabled(option.disabledReason != nil)
                            .accessibilityIdentifier("settings-option-\(option.label)")
                        }
                    }
                } else if let loadError {
                    TronSettingsCaption(loadError)
                } else {
                    TronLoadingState(label: "Loading…")
                }
            }
            .padding(20)
        }
        .tronNavigationTitle(title)
        .task(id: query) {
            do {
                let response = try await model.settingsOptions(target: target, key: setting.key, qualifiers: setting.qualifiers,
                                                               query: query.isEmpty ? nil : query)
                guard !Task.isCancelled else { return }
                options = response.options
                loadError = nil
            } catch is CancellationError {
                return
            } catch {
                loadError = error.localizedDescription
            }
        }
    }
}
