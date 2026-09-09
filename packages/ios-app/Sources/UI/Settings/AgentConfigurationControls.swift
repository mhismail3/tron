import SwiftUI

/// Shared model and reasoning controls used by both persisted defaults and a
/// live session. Both setting capsules use the same anchored slider host.
struct TronModelSelectionRow: View {
    @Binding var selection: ModelRef?
    let models: [ModelSummary]
    let navigationTitle: String
    var accent: Color = .tronPurple

    var body: some View {
        TronSelectionSheetRow(icon: "cpu", title: "Model", detail: "Default for new sessions",
                              value: SessionModelSelectionPresentation.modelName(selection, catalog: models),
                              accessibilityLabel: navigationTitle, accent: accent) {
            ModelPicker(selection: $selection, models: models)
                .tronNavigationTitle(navigationTitle, accent: accent)
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
    var information: String? = nil
    var accent: Color = .tronTeal
    @State private var ownerID = UUID()
    @Environment(\.configurationSliderPresentation) private var sliderPresentation
    @Environment(\.controlSize) private var controlSize
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.tronPresentationActivity) private var presentationActivity
    @Environment(\.tronPresentationSurfaceToken) private var surfaceToken
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
            information: information,
            value: displayValue,
            accent: accent
        ) {
            Button {
                guard isEnabled, presentationActivity.allowsPresentationPublication,
                      sliderPresentation?.session == nil else { return }
                sliderPresentation?.open(owner: ownerID, surface: surfaceToken)
            } label: {
                TronInlineActionLabel(currentValue.formatted(), accent: accent)
            }
            .buttonStyle(.plain)
            .disabled(sliderPresentation == nil)
            .opacity(sliderPresentation?.session?.owner == ownerID ? 0 : 1)
            .accessibilityLabel("Context Window")
            .accessibilityValue(displayValue)
            .accessibilityIdentifier("context-window-control")
            .anchorPreference(key: ConfigurationSliderPreference.self, value: .bounds) { anchor in
                guard let session = sliderPresentation?.session, session.owner == ownerID,
                      isEnabled, presentationActivity.allowsPresentationPublication else { return nil }
                return ConfigurationSliderRequest(
                    session: session, anchor: anchor, sourceVerticalInset: controlSize == .small ? 8 : 0,
                    accent: settingsTheme?.accent ?? accent,
                    editor: .contextWindow(ContextWindowSliderRequest(
                        scale: ContextWindowSliderScale(limits: limits, defaultValue: defaultValue),
                        value: currentValue, selection: selection, title: currentValue.formatted(),
                        resetLabel: resetLabel, detail: detail
                    ) { draft in
                        guard isEnabled, presentationActivity.allowsPresentationPublication else { return }
                        if draft.changed, draft.selection != selection { selection = draft.selection }
                    })
                )
            }
        }
        .onChange(of: isEnabled) { _, enabled in if !enabled { cancelEditor() } }
        .onChange(of: limits) { _, _ in cancelEditor() }
        .onChange(of: currentValue) { _, _ in cancelEditor() }
        .onChange(of: selection) { _, _ in cancelEditor() }
        .onChange(of: defaultValue) { _, _ in cancelEditor() }
        .onDisappear { cancelEditor() }
        .accessibilityHint("\(detail) Opens a continuous slider with gentle detents. Dismiss to save.")
    }

    private func cancelEditor() { sliderPresentation?.cancel(owner: ownerID) }
}

struct TronThinkingSelectionRow: View {
    @Binding var selection: String
    let levels: [String]
    var information: String? = nil
    var accent: Color = .tronPurple
    @State private var ownerID = UUID()
    @Environment(\.configurationSliderPresentation) private var sliderPresentation
    @Environment(\.controlSize) private var controlSize
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.tronPresentationActivity) private var presentationActivity
    @Environment(\.tronPresentationSurfaceToken) private var surfaceToken
    @Environment(\.tronSettingsVisualTheme) private var settingsTheme

    private var scale: ThinkingSliderScale { ThinkingSliderScale(levels: levels) }
    private var canEdit: Bool { scale.levels.count > 1 || scale.levels.first.map { $0 != selection } == true }

    var body: some View {
        AgentConfigurationValueRow(
            icon: "brain",
            title: "Thinking",
            information: information,
            value: ThinkingLevelPresentation.title(selection),
            accent: accent
        ) {
            Button {
                guard canEdit, isEnabled, presentationActivity.allowsPresentationPublication,
                      sliderPresentation?.session == nil else { return }
                sliderPresentation?.open(owner: ownerID, surface: surfaceToken)
            } label: {
                TronInlineActionLabel(ThinkingLevelPresentation.title(selection), accent: accent)
            }
            .buttonStyle(.plain)
            .disabled(!canEdit || sliderPresentation == nil)
            .opacity(sliderPresentation?.session?.owner == ownerID ? 0 : 1)
            .accessibilityLabel("Thinking")
            .accessibilityValue(ThinkingLevelPresentation.title(selection))
            .accessibilityIdentifier("thinking-level-control")
            .anchorPreference(key: ConfigurationSliderPreference.self, value: .bounds) { anchor in
                guard let session = sliderPresentation?.session, session.owner == ownerID,
                      canEdit, isEnabled, presentationActivity.allowsPresentationPublication else { return nil }
                return ConfigurationSliderRequest(
                    session: session, anchor: anchor, sourceVerticalInset: controlSize == .small ? 8 : 0,
                    accent: settingsTheme?.accent ?? accent,
                    editor: .thinking(ThinkingSliderRequest(scale: scale, value: selection) { draft in
                        guard isEnabled, presentationActivity.allowsPresentationPublication,
                              let value = draft.selectionToCommit(currentValue: selection, levels: scale.levels) else { return }
                        selection = value
                    })
                )
            }
        }
        .onChange(of: selection) { _, _ in cancelEditor() }
        .onChange(of: levels) { _, _ in cancelEditor() }
        .onChange(of: isEnabled) { _, enabled in if !enabled { cancelEditor() } }
        .onDisappear { cancelEditor() }
        .accessibilityHint(canEdit ? "Opens a slider of available thinking levels. Dismiss to save." : "No alternative thinking levels are available.")
    }

    private func cancelEditor() { sliderPresentation?.cancel(owner: ownerID) }
}

/// The same mutation controls fit either ordinary settings rows or a compact
/// model summary. Only presentation changes; validation and controls stay shared.
private struct AgentConfigurationValueRow<Control: View>: View {
    let icon: String
    let title: String
    var detail: String? = nil
    var information: String? = nil
    let value: String
    let accent: Color
    @ViewBuilder let control: () -> Control
    @Environment(\.controlSize) private var controlSize

    var body: some View {
        if controlSize == .small {
            TronSettingsRow(icon: icon, title: title, subtitle: information, accent: accent) {
                control()
            }
        } else {
            TronValueRow(icon: icon, title: title, detail: detail, value: value, accent: accent) {
                control()
            }
        }
    }
}
