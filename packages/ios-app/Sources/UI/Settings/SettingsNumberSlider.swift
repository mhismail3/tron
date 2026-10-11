import SwiftUI
import TronMobileCore

/// A bounded numeric setting uses the same anchored, dismiss-to-save slider as
/// the context-window control; the Gateway remains the validator.
struct SettingsNumberSliderRequest {
    let title: String
    let value: Int
    let range: SettingsRange
    let unit: String?
    let finish: (Int) -> Void
}

struct SettingsNumberSliderEditor: View {
    let request: SettingsNumberSliderRequest
    let anchor: ConfigurationSliderRequest
    let source: CGRect
    let availableSize: CGSize
    let presentation: ConfigurationSliderPresentation
    @State private var value: Int
    @State private var changed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(request: SettingsNumberSliderRequest, anchor: ConfigurationSliderRequest, source: CGRect,
         availableSize: CGSize, presentation: ConfigurationSliderPresentation) {
        self.request = request
        self.anchor = anchor
        self.source = source
        self.availableSize = availableSize
        self.presentation = presentation
        _value = State(initialValue: min(Int(request.range.max), max(Int(request.range.min), request.value)))
    }

    private var minimum: Int { Int(request.range.min) }
    private var maximum: Int { Int(request.range.max) }
    private var scale: ContextWindowSliderScale {
        ContextWindowSliderScale(
            limits: ContextWindowLimits(minimum: minimum, maximum: maximum, default: request.value, longContextThreshold: nil),
            defaultValue: request.value
        )
    }
    private var suffix: String { request.unit.map { " \($0)" } ?? "" }

    var body: some View {
        let progress = scale.progress(for: value)
        ConfigurationSliderContainer(
            title: request.title, value: "\(value.formatted())\(suffix)",
            collapsedTitle: "\(value.formatted())\(suffix)",
            anchor: anchor, source: source, availableSize: availableSize, presentation: presentation,
            finish: { if changed, value != request.value { request.finish(value) } }
        ) { actions in
            ConfigurationSliderTrack(
                progress: progress, stops: scale.detents.map(scale.progress), emphasizedStop: progress,
                accent: anchor.accent, title: request.title, value: "\(value.formatted())\(suffix)",
                hint: "Range: \(minimum.formatted())–\(maximum.formatted())\(suffix). Drag or adjust to choose. Dismiss to save.",
                identifier: "settings-number-slider", feedback: scale.detents.first { $0 == value }, actions: actions,
                change: { raw, _ in
                    guard raw.isFinite else { return }
                    changed = true
                    let stepped = steppedValue(scale.tokens(at: raw))
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.10)) { value = stepped }
                },
                settle: { raw, _ in changed = true; value = steppedValue(scale.tokens(at: raw)) },
                adjust: { increasing in
                    // A declared step must advance even when a decorative detent
                    // would round back to the current value.
                    changed = true
                    let step = Int(request.range.step ?? 1)
                    value = steppedValue(value + (increasing ? step : -step))
                }
            )
            HStack {
                Text(minimum.formatted())
                Spacer()
                Text(dynamicTypeSize.isAccessibilitySize
                 ? maximum.formatted(.number.notation(.compactName).precision(.fractionLength(0...2)))
                 : maximum.formatted())
            }
            .font(TronTypography.secondaryCodeDescription.weight(.bold))
            .foregroundStyle(Color.tronTextSecondary)
            .accessibilityHidden(true)
        }
    }

    private func steppedValue(_ candidate: Int) -> Int {
        let step = max(1, Int(request.range.step ?? 1))
        let bounded = min(maximum, max(minimum, candidate))
        let aligned = minimum + Int((Double(bounded - minimum) / Double(step)).rounded()) * step
        return min(maximum, max(minimum, aligned))
    }
}

struct SettingsNumberSelectionRow: View {
    let title: String
    let value: Int
    let display: String
    let range: SettingsRange
    let onChange: (Int) -> Void
    @State private var ownerID = UUID()
    @Environment(\.configurationSliderPresentation) private var sliderPresentation
    @Environment(\.controlSize) private var controlSize
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.tronPresentationActivity) private var activity
    @Environment(\.tronPresentationSurfaceToken) private var surfaceToken
    @Environment(\.tronSettingsVisualTheme) private var theme

    var body: some View {
        AgentConfigurationValueRow(icon: "number", title: title,
                                    detail: "Range: \(Int(range.min))–\(Int(range.max))\(range.unit.map { " \($0)" } ?? "")",
                                    value: display, accent: theme?.accent ?? .tronTeal) {
            Button {
                guard isEnabled, activity.allowsPresentationPublication, sliderPresentation?.session == nil else { return }
                sliderPresentation?.open(owner: ownerID, surface: surfaceToken)
            } label: { TronInlineActionLabel(display, accent: theme?.accent ?? .tronTeal) }
            .buttonStyle(.plain)
            .disabled(sliderPresentation == nil)
            .opacity(sliderPresentation?.session?.owner == ownerID ? 0 : 1)
            .accessibilityLabel(title)
            .accessibilityValue(display)
            .accessibilityIdentifier("settings-number-control")
            .anchorPreference(key: ConfigurationSliderPreference.self, value: .bounds) { anchor in
                guard let session = sliderPresentation?.session, session.owner == ownerID,
                      isEnabled, activity.allowsPresentationPublication else { return nil }
                return ConfigurationSliderRequest(
                    session: session, anchor: anchor, sourceVerticalInset: controlSize == .small ? 8 : 0,
                    accent: theme?.accent ?? .tronTeal,
                    editor: .number(SettingsNumberSliderRequest(title: title, value: value, range: range, unit: range.unit) { next in
                        guard isEnabled, activity.allowsPresentationPublication else { return }
                        onChange(next)
                    })
                )
            }
        }
        .onChange(of: value) { _, _ in cancel() }
        .onChange(of: range) { _, _ in cancel() }
        .onChange(of: isEnabled) { _, enabled in if !enabled { cancel() } }
        .onDisappear { cancel() }
        .accessibilityHint("Opens a bounded slider. Dismiss to save.")
    }

    private func cancel() { sliderPresentation?.cancel(owner: ownerID) }
}
