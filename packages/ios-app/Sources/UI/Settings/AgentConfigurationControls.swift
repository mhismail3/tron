import SwiftUI

/// Shared model and reasoning controls used by both persisted defaults and a
/// live session. Keeping the sheet link and inline menu here prevents the
/// Manage Session surface from drifting back to stock menus.
struct TronModelSelectionRow: View {
    @Binding var selection: ModelRef?
    let models: [ModelSummary]
    let navigationTitle: String
    var accent: Color = .tronPurple

    var body: some View {
        TronProgressiveSheetLink(accessibilityLabel: navigationTitle, accent: accent) {
            ModelPicker(selection: $selection, models: models)
                .tronNavigationTitle(navigationTitle, accent: accent)
        } label: {
            TronValueRow(
                icon: "cpu",
                title: "Model",
                value: selection?.displayDescription ?? "Choose model",
                accent: accent
            )
        }
    }
}

enum ContextWindowInput {
    static func tokens(_ text: String, limits: ContextWindowLimits) -> Int? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.allSatisfy({ $0.isASCII && $0.isNumber }),
              let tokens = Int(value), limits.admits(tokens) else { return nil }
        return tokens
    }
}

struct ContextWindowSelectionRow: View {
    @Binding var selection: Int?
    let limits: ContextWindowLimits
    let inheritedValue: Int?
    var effectiveValue: Int? = nil
    var resetLabel = "Use model default"
    var warning: String? = nil
    var source: String? = nil
    var accent: Color = .tronTeal
    @State private var customText = ""
    @State private var editingCustom = false

    private var displayValue: String {
        if let effectiveValue {
            return "\(effectiveValue.formatted()) tokens · \(source?.capitalized ?? "Effective")"
        }
        if let selection { return "\(selection.formatted()) tokens" }
        if let inheritedValue { return "Inherited · \(inheritedValue.formatted()) tokens" }
        return "Model default · \(limits.default.formatted()) tokens"
    }

    private var detail: String {
        var text = "Configurable: \(limits.minimum.formatted())–\(limits.maximum.formatted()) tokens."
        if effectiveValue == nil, let configured = selection ?? inheritedValue, !limits.admits(configured) {
            text += " The saved value is outside current bounds and will be adjusted when applied."
        }
        if let warning { text += " \(warning)" }
        else if let threshold = limits.longContextThreshold, (selection ?? inheritedValue ?? limits.default) > threshold {
            text += " Long-context requests may increase cost or subscription usage."
        }
        return text
    }

    var body: some View {
        TronValueRow(
            icon: "gauge.with.dots.needle.50percent",
            title: "Context Window",
            detail: detail,
            value: displayValue,
            accent: accent
        ) {
            TronInlineMenu("Change", accent: accent) {
                Button(resetLabel) { selection = nil }
                Button("Maximum (\(limits.maximum.formatted()))") { selection = limits.maximum }
                Button("Custom token limit…") {
                    customText = String(selection ?? effectiveValue ?? inheritedValue ?? limits.default)
                    editingCustom = true
                }
            }
        }
        .alert("Context Window", isPresented: $editingCustom) {
            TextField("Whole number of tokens", text: $customText)
                .keyboardType(.numberPad)
            Button("Cancel", role: .cancel) {}
            Button("Apply") {
                if let tokens = ContextWindowInput.tokens(customText, limits: limits) { selection = tokens }
            }
            .disabled(ContextWindowInput.tokens(customText, limits: limits) == nil)
        } message: {
            Text("Enter \(limits.minimum.formatted())–\(limits.maximum.formatted()) tokens. Larger windows may increase cost or allowance usage and do not restore previously compacted history.")
        }
        .accessibilityHint("Choose the default, maximum, or explicitly apply a supported custom token limit.")
    }
}

struct TronThinkingSelectionRow: View {
    @Binding var selection: String
    let levels: [String]
    var accent: Color = .tronPurple

    var body: some View {
        TronValueRow(
            icon: "brain",
            title: "Thinking",
            value: selection.capitalized,
            accent: accent
        ) {
            TronInlineMenu("Change", accent: accent) {
                ForEach(levels, id: \.self) { level in
                    Button(level.capitalized) { selection = level }
                }
            }
        }
    }
}
