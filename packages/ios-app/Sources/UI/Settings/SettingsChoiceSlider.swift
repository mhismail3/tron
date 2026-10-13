import SwiftUI
import TronMobileCore

/// Ordered values and labels come from the caller's catalog. This is the same
/// anchored editor for thinking and schema-defined choices, not a second style.
struct SettingsChoiceSliderRequest {
    let title: String
    let options: [SettingsOption]
    let value: JSONValue
    let identifier: String
    let finish: (JSONValue) -> Void
}

struct SettingsChoiceSliderEditor: View {
    let request: SettingsChoiceSliderRequest
    let anchor: ConfigurationSliderRequest
    let source: CGRect
    let availableSize: CGSize
    let presentation: ConfigurationSliderPresentation
    @State private var value: JSONValue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(request: SettingsChoiceSliderRequest, anchor: ConfigurationSliderRequest, source: CGRect,
         availableSize: CGSize, presentation: ConfigurationSliderPresentation) {
        self.request = request
        self.anchor = anchor
        self.source = source
        self.availableSize = availableSize
        self.presentation = presentation
        _value = State(initialValue: request.value)
    }

    private func progress(_ index: Int) -> Double {
        request.options.count == 1 ? 0.5 : Double(index) / Double(request.options.count - 1)
    }

    var body: some View {
        let index = request.options.firstIndex { $0.value == value }
        let label = index.map { request.options[$0].label } ?? "Unavailable"
        ConfigurationSliderContainer(
            title: request.title, value: label, collapsedTitle: label,
            anchor: anchor, source: source, availableSize: availableSize, presentation: presentation,
            finish: { if value != request.value { request.finish(value) } }
        ) { actions in
            ConfigurationSliderTrack(
                progress: index.map(progress) ?? 0, stops: request.options.indices.map(progress),
                emphasizedStop: index.map(progress), showsThumb: index != nil, accent: anchor.accent,
                title: request.title, value: label,
                hint: "Available choices: \(request.options.map(\.label).joined(separator: ", ")). Drag or adjust to choose. Dismiss to save.",
                identifier: request.identifier, feedback: index, actions: actions,
                change: { raw, _ in
                    guard raw.isFinite, !request.options.isEmpty else { return }
                    let next = Int((min(1, max(0, raw)) * Double(request.options.count - 1)).rounded())
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.10)) { select(next) }
                },
                settle: { _, _ in },
                adjust: { increasing in
                    let next = min(request.options.count - 1, max(0, (index ?? (increasing ? -1 : request.options.count)) + (increasing ? 1 : -1)))
                    select(next)
                }
            )
        }
    }

    private func select(_ index: Int) {
        guard request.options.indices.contains(index), request.options[index].disabledReason == nil else { return }
        value = request.options[index].value
    }
}

struct SettingsChoiceSelectionRow: View {
    let title: String
    let icon: String
    let value: JSONValue
    let display: String
    let options: [SettingsOption]
    var information: String? = nil
    var accent: Color = .tronPurple
    var identifier = "settings-choice-control"
    var sliderIdentifier = "settings-choice-slider"
    let onChange: (JSONValue) -> Void
    @State private var ownerID = UUID()
    @Environment(\.configurationSliderPresentation) private var sliderPresentation
    @Environment(\.controlSize) private var controlSize
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.tronPresentationActivity) private var activity
    @Environment(\.tronPresentationSurfaceToken) private var surfaceToken
    @Environment(\.tronSettingsVisualTheme) private var theme

    private var canEdit: Bool { options.contains { $0.disabledReason == nil && $0.value != value } }

    var body: some View {
        AgentConfigurationValueRow(icon: icon, title: title, information: information, value: display, accent: accent) {
            Button {
                guard canEdit, isEnabled, activity.allowsPresentationPublication, sliderPresentation?.session == nil else { return }
                sliderPresentation?.open(owner: ownerID, surface: surfaceToken)
            } label: { TronInlineActionLabel(display, accent: accent) }
            .buttonStyle(.plain)
            .disabled(!canEdit || sliderPresentation == nil)
            .opacity(sliderPresentation?.session?.owner == ownerID ? 0 : 1)
            .accessibilityLabel(title)
            .accessibilityValue(display)
            .accessibilityIdentifier(identifier)
            .anchorPreference(key: ConfigurationSliderPreference.self, value: .bounds) { anchor in
                guard let session = sliderPresentation?.session, session.owner == ownerID,
                      canEdit, isEnabled, activity.allowsPresentationPublication else { return nil }
                return ConfigurationSliderRequest(
                    session: session, anchor: anchor, sourceVerticalInset: controlSize == .small ? 8 : 0,
                    accent: theme?.accent ?? accent,
                    editor: .choice(SettingsChoiceSliderRequest(title: title, options: options, value: value, identifier: sliderIdentifier) { next in
                        guard isEnabled, activity.allowsPresentationPublication,
                              options.contains(where: { $0.value == next && $0.disabledReason == nil }) else { return }
                        onChange(next)
                    })
                )
            }
        }
        .onChange(of: value) { _, _ in cancel() }
        .onChange(of: options) { _, _ in cancel() }
        .onChange(of: isEnabled) { _, enabled in if !enabled { cancel() } }
        .onDisappear { cancel() }
        .accessibilityHint(canEdit ? "Opens a slider of available choices. Dismiss to save." : "No alternative choices are available.")
    }

    private func cancel() { sliderPresentation?.cancel(owner: ownerID) }
}
