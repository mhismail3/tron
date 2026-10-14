import SwiftUI

/// Passive explanations sit on the sheet, never in a surface that looks tappable:
/// sheet intros, help and captions, in the settings row subtitle's size and colour
/// on every sheet (#900), so explanatory copy never reads smaller than its rows.
struct TronSettingsCaption: View {
    let text: String
    /// Captions sit 4 points inside the sheet's content edge; a group's detail
    /// aligns with its header instead.
    var inset: CGFloat = 4
    init(_ text: String, inset: CGFloat = 4) { self.text = text; self.inset = inset }
    var body: some View {
        Text(text)
            .font(TronTypography.settingsSubtext(adjustment: TronSettingsLayoutPolicy.metadataSizeAdjustment))
            .foregroundStyle(Color.tronTextSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, inset)
    }
}

extension View {
    /// Keep the explanation attached to its owner rather than a distant page footer.
    func tronSettingsCaption(_ text: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            self
            if let text { TronSettingsCaption(text) }
        }
    }
}

/// Actionable failures share row geometry and a trailing retry target. They are
/// deliberately distinct from passive, surface-free settings captions.
struct TronSettingsNotice: View {
    let message: String
    var title: String? = nil
    var icon: String = "exclamationmark.triangle"
    var accent: Color = .tronAmber
    var retry: (() -> Void)? = nil

    var body: some View {
        TronSettingsRow(icon: icon, title: title ?? message, subtitle: title == nil ? nil : message,
                        accent: accent, titleFont: title == nil ? TronTypography.bodySM : TronTypography.body) {
            if let retry {
                Button(action: retry) { TronInlineActionLabel("Retry", accent: accent) }
                    .buttonStyle(.plain)
            }
        }
        .tronSettingsVisualTheme(accent: accent)
        .tronGlassSurface(accent: accent, tintOpacity: 0.09, respectsSettingsTheme: false)
    }
}

/// A chosen value belongs in its action capsule, not repeated as a subtitle.
struct TronSelectionRow<Choices: View>: View {
    let icon: String
    let title: String
    var detail: String? = nil
    let value: String
    var accent: Color = .tronEmerald
    @ViewBuilder let choices: () -> Choices

    var body: some View {
        TronSettingsRow(icon: icon, title: title, subtitle: detail, accent: accent) {
            TronInlineMenu(value, accent: accent, content: choices)
                .accessibilityLabel(title)
                .accessibilityValue(value)
        }
    }
}

/// One option of a `TronChoiceRow`/`TronChoicePicker`.
struct TronChoice<ID: Hashable>: Identifiable {
    let id: ID
    let label: String
    var detail: String? = nil
    var disabledReason: String? = nil
}

/// The standard single-choice row: the chosen value in a right-aligned capsule
/// that opens a picker sheet of option rows. Use it instead of a menu; SwiftUI
/// menus fail to open in a sheet presented from another sheet (#877).
struct TronChoiceRow<ID: Hashable>: View {
    let icon: String
    let title: String
    var detail: String? = nil
    let choices: [TronChoice<ID>]
    let selected: ID?
    var accent: Color = .tronEmerald
    let onChoose: (ID) -> Void

    var body: some View {
        TronSelectionSheetRow(icon: icon, title: title, detail: detail,
                              value: choices.first { $0.id == selected }?.label ?? "None", accent: accent) {
            TronChoicePicker(title: title, choices: choices, selected: selected, onChoose: onChoose)
        }
    }
}

/// A picker sheet of standard option rows; long lists get the floating search.
struct TronChoicePicker<ID: Hashable>: View {
    let title: String
    let choices: [TronChoice<ID>]
    let selected: ID?
    var optionIdentifierPrefix = "settings-option-"
    let onChoose: (ID) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(choices) { choice in
                    TronCatalogOptionRow(title: choice.label, summary: choice.disabledReason, detail: choice.detail,
                                         icon: "circle", isSelected: choice.id == selected,
                                         isEnabled: choice.disabledReason == nil) {
                        onChoose(choice.id)
                        dismiss()
                    }
                    .accessibilityIdentifier(optionIdentifierPrefix + choice.label)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .tronScrollEdgeChrome()
        .tronNavigationTitle(title)
    }
}

/// Several choices from one list, committed with Save. The order chosen is kept;
/// a newly chosen item joins the end.
struct TronChecklistPicker<ID: Hashable>: View {
    let title: String
    var help: String? = nil
    let choices: [TronChoice<ID>]?
    var optionIdentifierPrefix = "settings-option-"
    let onSave: ([ID]) -> Void
    @State private var chosen: [ID]
    @Environment(\.dismiss) private var dismiss
    private let initial: [ID]

    init(title: String, help: String? = nil, choices: [TronChoice<ID>]?, selected: [ID],
         optionIdentifierPrefix: String = "settings-option-", onSave: @escaping ([ID]) -> Void) {
        self.title = title; self.help = help; self.choices = choices
        self.optionIdentifierPrefix = optionIdentifierPrefix; self.onSave = onSave
        initial = selected
        _chosen = State(initialValue: selected)
    }

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 8) {
                if let help { TronSettingsCaption(help).padding(.bottom, 4) }
                if choices == nil {
                    TronLoadingState(label: "Loading…").frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(choices ?? []) { choice in
                    let isChosen = chosen.contains(choice.id)
                    TronCatalogOptionRow(title: choice.label, summary: choice.disabledReason, detail: choice.detail,
                                         icon: "circle", isSelected: isChosen,
                                         isEnabled: choice.disabledReason == nil || isChosen) {
                        if isChosen { chosen.removeAll { $0 == choice.id } } else { chosen.append(choice.id) }
                    }
                    .accessibilityIdentifier(optionIdentifierPrefix + choice.label)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .tronScrollEdgeChrome()
        .tronNavigationTitle(title)
        .tronSaveToolbar(enabled: chosen != initial) {
            onSave(chosen)
            dismiss()
        }
    }
}

/// The same selected-value row can open a richer picker instead of a menu.
struct TronSelectionSheetRow<Destination: View>: View {
    let icon: String
    let title: String
    var detail: String? = nil
    let value: String
    var accessibilityLabel: String? = nil
    var accent: Color = .tronEmerald
    @ViewBuilder let destination: () -> Destination
    @Environment(\.tronSettingsVisualTheme) private var theme

    var body: some View {
        TronSettingsRow(icon: icon, title: title, subtitle: detail, accent: accent) {
            TronProgressiveSheetLink(accessibilityLabel: accessibilityLabel ?? title, accent: theme?.accent ?? accent, destination: destination) {
                TronInlineActionLabel(value, accent: accent)
            }
            .accessibilityValue(value)
        }
    }
}

/// Catalog choices share the established model-picker row. Catalog owners
/// supply facts and selection authority; this primitive owns only presentation.
struct TronCatalogOptionRow: View {
    let title: String
    var summary: String? = nil
    var detail: String? = nil
    var badge: String? = nil
    var icon: String = "cpu"
    let isSelected: Bool
    var isApplying = false
    var isEnabled = true
    let action: () -> Void
    @Environment(\.tronSettingsVisualTheme) private var theme

    private var accent: Color { theme?.accent ?? (isSelected ? .tronEmerald : .tronSlate) }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Group {
                    if isSelected && isApplying {
                        TronPulseLoadingIndicator(accent: theme?.accent ?? .tronEmerald, size: 14)
                    } else {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : icon)
                            .foregroundStyle(accent)
                            .accessibilityLabel(isSelected ? "Selected" : title)
                    }
                }
                .frame(width: 22)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                            .foregroundStyle(Color.tronTextPrimary)
                        if let badge {
                            Text(badge)
                                .font(TronTypography.secondaryDescription)
                                .foregroundStyle(Color.tronTextSecondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.tronCyan.opacity(0.12), in: Capsule())
                        }
                    }
                    // Uniform fact lines preserve lazy-list scroll estimates.
                    if let summary {
                        Text(summary)
                            .font(TronTypography.secondaryDescription)
                            .foregroundStyle(Color.tronTextPrimary)
                            .lineLimit(1)
                    }
                    if let detail {
                        Text(detail)
                            .font(TronTypography.secondaryDescription)
                            .foregroundStyle(Color.tronTextSecondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .tronScrollSurface(accent: accent, cornerRadius: 14, tintOpacity: isSelected ? 0.18 : 0.08)
        .disabled(!isEnabled)
        .accessibilityLabel([title, summary, detail].compactMap { $0 }.joined(separator: ", "))
        .accessibilityValue(isSelected && isApplying ? "Applying configuration" : isSelected ? "Selected" : "")
    }
}

struct TronSettingsInputScope: Equatable {
    var profile = 0
    var scope = 0
}

private struct TronSettingsInputScopeKey: EnvironmentKey {
    static let defaultValue = TronSettingsInputScope()
}

extension EnvironmentValues {
    var tronSettingsInputScope: TronSettingsInputScope {
        get { self[TronSettingsInputScopeKey.self] }
        set { self[TronSettingsInputScopeKey.self] = newValue }
    }
}

/// Stage numeric text until editing ends. Form owners may instead keep the
/// pending text externally until their explicit action captures a policy.
struct TronNumberSettingRow: View {
    let icon: String
    let title: String
    var detail: String? = nil
    @Binding var value: Int
    var accent: Color = .tronEmerald
    var stagedText: Binding<String?>? = nil
    @Environment(\.tronSettingsInputScope) private var inputScope
    @State private var text: String?
    @State private var acceptedBinding: Binding<Int>?
    @State private var admittedScope: TronSettingsInputScope?
    @State private var invalid = false
    @FocusState private var focused: Bool

    private var textBinding: Binding<String> {
        Binding(
            get: {
                if let stagedText { return stagedText.wrappedValue ?? String(value) }
                return text ?? String(value)
            },
            set: { next in
                if let stagedText {
                    stagedText.wrappedValue = next
                } else {
                    if text == nil { acceptedBinding = $value; admittedScope = inputScope }
                    text = next
                }
                invalid = false
            }
        )
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            TronSettingsRow(icon: icon, title: title, subtitle: detail, accent: accent) {
                TextField(title, text: textBinding)
                    .keyboardType(.numberPad)
                    .tronInlineField(numeric: true)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 118)
                    .accessibilityLabel(title)
                    .tronTextEntryDone(keyboardToolbar: true, focus: $focused)
            }
            if invalid {
                Text(Self.invalidInputMessage)
                    .font(TronTypography.secondaryDescription)
                    .foregroundStyle(Color.tronTextSecondary)
                    .padding(.horizontal, TronSettingsLayoutPolicy.rowHorizontalPadding)
                    .padding(.bottom, 12)
            }
        }
        .onSubmit { commit() }
        .onChange(of: focused) { _, active in if !active { commit() } }
        .onChange(of: inputScope) { _, _ in discard(); focused = false }
        .onDisappear { commit() }
    }

    private func commit() {
        guard stagedText == nil, let text else { return }
        guard admittedScope == inputScope else { discard(); return }
        guard let number = Self.parse(text) else { invalid = true; return }
        if let acceptedBinding, acceptedBinding.wrappedValue != number { acceptedBinding.wrappedValue = number }
        discard()
    }

    private func discard() {
        guard stagedText == nil else { return }
        text = nil
        acceptedBinding = nil
        admittedScope = nil
        invalid = false
    }

    static let invalidInputMessage = "Enter a whole number without separators."

    nonisolated static func parse(_ text: String) -> Int? {
        Int(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

struct TronTextSettingRow: View {
    let icon: String
    let title: String
    var detail: String? = nil
    @Binding var value: String
    var keyboard: UIKeyboardType = .default
    var accent: Color = .tronEmerald

    var body: some View {
        TronSettingsRow(icon: icon, title: title, subtitle: detail, accent: accent) {
            TextField(title, text: $value, prompt: Text("(empty)").foregroundStyle(Color.tronTextMuted))
                .keyboardType(keyboard)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .tronInlineField(monospaced: true)
                .multilineTextAlignment(.trailing)
                .frame(minWidth: 100, maxWidth: 220)
                .accessibilityLabel(title)
                .tronTextEntryDone()
        }
    }
}

extension Binding {
    /// Route compound user actions through the same binding admission as a
    /// field, without teaching individual sheets a second save path.
    func update(_ change: (inout Value) -> Void) {
        var next = wrappedValue
        change(&next)
        wrappedValue = next
    }
}
