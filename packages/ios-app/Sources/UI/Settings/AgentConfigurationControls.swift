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

struct ContextWindowSelectionRow: View {
    @Binding var selection: Int?
    let limits: ContextWindowLimits
    let inheritedValue: Int?
    var effectiveValue: Int? = nil
    var resetLabel = "Use model default"
    var warning: String? = nil
    var source: String? = nil
    var accent: Color = .tronTeal
    @State private var editorID: UUID?
    @Environment(\.controlSize) private var controlSize
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.tronPresentationActivity) private var presentationActivity
    @Environment(\.tronSettingsVisualTheme) private var settingsTheme

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
        AgentConfigurationValueRow(
            icon: "gauge.with.dots.needle.50percent",
            title: "Context Window",
            detail: detail,
            value: displayValue,
            accent: accent
        ) {
            Button { editorID = UUID() } label: {
                TronInlineActionLabel(currentValue.formatted(), accent: accent)
            }
            .buttonStyle(.plain)
            .opacity(editorID == nil ? 1 : 0)
            .accessibilityLabel("Context Window")
            .accessibilityValue(displayValue)
            .accessibilityIdentifier("context-window-control")
            .anchorPreference(key: ContextWindowSliderPreference.self, value: .bounds) { anchor in
                guard let editorID, isEnabled, presentationActivity.allowsPresentationPublication else { return nil }
                return ContextWindowSliderRequest(
                    id: editorID, anchor: anchor, sourceVerticalInset: controlSize == .small ? 8 : 0,
                    scale: ContextWindowSliderScale(limits: limits, defaultValue: defaultValue),
                    value: currentValue, selection: selection, title: currentValue.formatted(),
                    resetLabel: resetLabel, detail: detail,
                    accent: settingsTheme?.accent ?? accent
                ) { draft in
                    guard self.editorID == editorID, isEnabled,
                          presentationActivity.allowsPresentationPublication else { return }
                    self.editorID = nil
                    if draft.changed, draft.selection != selection { selection = draft.selection }
                }
            }
        }
        .onChange(of: isEnabled) { _, enabled in if !enabled { editorID = nil } }
        .onChange(of: limits) { _, _ in editorID = nil }
        .onChange(of: currentValue) { _, _ in editorID = nil }
        .onChange(of: selection) { _, _ in editorID = nil }
        .onChange(of: defaultValue) { _, _ in editorID = nil }
        .onChange(of: presentationActivity) { _, activity in
            if !activity.allowsPresentationPublication { editorID = nil }
        }
        .onDisappear { editorID = nil }
        .accessibilityHint("\(detail) Opens a continuous slider with gentle detents. Dismiss to save.")
    }
}

struct TronThinkingSelectionRow: View {
    @Binding var selection: String
    let levels: [String]
    var accent: Color = .tronPurple
    @Environment(\.controlSize) private var controlSize

    var body: some View {
        AgentConfigurationValueRow(
            icon: "brain",
            title: "Thinking",
            value: ThinkingLevelPresentation.title(selection),
            accent: accent
        ) {
            TronInlineMenu(controlSize == .small ? ThinkingLevelPresentation.title(selection) : "Change", accent: accent) {
                ForEach(levels, id: \.self) { level in
                    Button(ThinkingLevelPresentation.title(level)) { selection = level }
                }
            }
            .accessibilityLabel("Thinking")
            .accessibilityValue(ThinkingLevelPresentation.title(selection))
        }
    }
}

/// The same mutation controls fit either ordinary settings rows or a compact
/// model summary. Only presentation changes; validation and controls stay shared.
private struct AgentConfigurationValueRow<Control: View>: View {
    let icon: String
    let title: String
    var detail: String? = nil
    let value: String
    let accent: Color
    @ViewBuilder let control: () -> Control
    @Environment(\.controlSize) private var controlSize

    var body: some View {
        if controlSize == .small {
            TronSettingsRow(icon: icon, title: title, accent: accent) {
                control()
            }
        } else {
            TronValueRow(icon: icon, title: title, detail: detail, value: value, accent: accent) {
                control()
            }
        }
    }
}
