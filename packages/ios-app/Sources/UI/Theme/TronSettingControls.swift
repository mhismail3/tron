import SwiftUI

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
        }
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

/// Stage numeric text until editing ends. Clearing a budget to type its
/// replacement must not autosave a partial number or silently parse a prefix.
struct TronNumberSettingRow: View {
    let icon: String
    let title: String
    var detail: String? = nil
    @Binding var value: Int
    var accent: Color = .tronEmerald
    @Environment(\.tronSettingsInputScope) private var inputScope
    @State private var text: String?
    @State private var acceptedBinding: Binding<Int>?
    @State private var admittedScope: TronSettingsInputScope?
    @State private var invalid = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            TronSettingsRow(icon: icon, title: title, subtitle: detail, accent: accent) {
                TextField(title, text: Binding(get: { text ?? String(value) }, set: { next in
                    if text == nil { acceptedBinding = $value; admittedScope = inputScope }
                    text = next
                    invalid = false
                }))
                    .keyboardType(.numberPad)
                    .tronInlineField(numeric: true)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 118)
                    .accessibilityLabel(title)
                    .focused($focused)
            }
            if invalid {
                Text("Enter a whole number without separators.")
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
        guard let text else { return }
        guard admittedScope == inputScope else { discard(); return }
        guard let number = Self.parse(text) else { invalid = true; return }
        if let acceptedBinding, acceptedBinding.wrappedValue != number { acceptedBinding.wrappedValue = number }
        discard()
    }

    private func discard() {
        text = nil
        acceptedBinding = nil
        admittedScope = nil
        invalid = false
    }

    static func parse(_ text: String) -> Int? {
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
            TextField(title, text: $value)
                .keyboardType(keyboard)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .tronInlineField(monospaced: true)
                .multilineTextAlignment(.trailing)
                .frame(minWidth: 100, maxWidth: 220)
                .accessibilityLabel(title)
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
