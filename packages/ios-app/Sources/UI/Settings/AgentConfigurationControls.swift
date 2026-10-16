import SwiftUI
import TronMobileCore

struct ContextWindowSelectionRow: View {
    @Binding var selection: Int?
    let limits: ContextWindowLimits
    let inheritedValue: Int?
    var effectiveValue: Int? = nil
    var resetLabel = "Use model default"
    var warning: String? = nil
    var source: String? = nil
    var information: String? = nil
    var accent: Color = .tronTeal

    private var currentValue: Int { effectiveValue ?? selection ?? inheritedValue ?? limits.default }
    private var defaultValue: Int { min(limits.maximum, max(limits.minimum, inheritedValue ?? limits.default)) }

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
        SettingsNumberSelectionRow(
            title: "Context Window", value: currentValue, display: displayValue,
            range: SettingsRange(min: Double(limits.minimum), max: Double(limits.maximum), step: nil, unit: "tokens"),
            icon: "gauge.with.dots.needle.50percent", detail: detail, information: information, accent: accent,
            actionDisplay: currentValue.formatted(), referenceValue: defaultValue, resetLabel: resetLabel,
            selectionIdentity: selection, identifier: "context-window-control", sliderIdentifier: "context-window-slider"
        ) { value in
            let next = value == defaultValue ? nil : value
            if next != selection { selection = next }
        }
    }
}

struct TronThinkingSelectionRow: View {
    @Binding var selection: String
    let levels: [String]
    var information: String? = nil
    var accent: Color = .tronPurple

    var body: some View {
        SettingsChoiceSelectionRow(
            title: "Thinking", icon: "brain", value: .string(selection),
            display: ThinkingLevelPresentation.title(selection),
            options: levels.map { SettingsOption(value: .string($0), label: ThinkingLevelPresentation.title($0), detail: nil, disabledReason: nil, resource: nil) },
            information: information, accent: accent,
            identifier: "thinking-level-control", sliderIdentifier: "thinking-level-slider"
        ) { if let value = $0.stringValue { selection = value } }
    }
}
