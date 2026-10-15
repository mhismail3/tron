import SwiftUI
import TronMobileCore

/// One numeric editor for bounded steps and continuous values with a reference.
/// The caller owns inheritance; merely opening or cancelling never writes it.
struct SettingsNumberSliderRequest {
    let title: String
    let value: Int
    let range: SettingsRange
    let unit: String?
    var referenceValue: Int? = nil
    var resetLabel: String? = nil
    var collapsedTitle: String? = nil
    var detail: String? = nil
    var identifier = "settings-number-slider"
    let finish: (Int) -> Void
}

struct SettingsNumberSliderEditor: View {
    let request: SettingsNumberSliderRequest
    let anchor: ConfigurationSliderRequest
    let source: CGRect
    let availableSize: CGSize
    let presentation: ConfigurationSliderPresentation
    @State private var value: Int
    @State private var progress: Double
    @State private var changed = false
    @State private var feedbackDetent: Int?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorScheme) private var colorScheme

    init(request: SettingsNumberSliderRequest, anchor: ConfigurationSliderRequest, source: CGRect,
         availableSize: CGSize, presentation: ConfigurationSliderPresentation) {
        self.request = request
        self.anchor = anchor
        self.source = source
        self.availableSize = availableSize
        self.presentation = presentation
        let scale = SettingsNumberSliderScale(minimum: Int(request.range.min), maximum: Int(request.range.max),
                                              defaultValue: request.referenceValue ?? request.value)
        _value = State(initialValue: scale.clamp(request.value))
        _progress = State(initialValue: scale.progress(for: request.value))
    }

    private var minimum: Int { Int(request.range.min) }
    private var maximum: Int { Int(request.range.max) }
    private var scale: SettingsNumberSliderScale {
        SettingsNumberSliderScale(minimum: minimum, maximum: maximum,
                                  defaultValue: request.referenceValue ?? request.value)
    }
    private var suffix: String { request.unit.map { " \($0)" } ?? "" }
    private var continuous: Bool { request.referenceValue != nil }
    private var formatted: String { value.formatted() }
    private var hint: String {
        request.detail.map { $0 + " Adjust to a detent, or drag for any value. Dismiss to save." }
            ?? "Range: \(minimum.formatted())–\(maximum.formatted())\(suffix). Drag or adjust to choose. Dismiss to save."
    }

    var body: some View {
        ConfigurationSliderContainer(
            title: request.title, value: continuous ? formatted : formatted + suffix,
            collapsedTitle: continuous ? (changed ? formatted : request.collapsedTitle ?? formatted) : formatted + suffix,
            anchor: anchor, source: source, availableSize: availableSize, presentation: presentation,
            finish: {
                // A reference reset may intentionally clear an explicit value even
                // when its numeric value is unchanged. The layer adapter decides.
                if changed, continuous || value != request.value { request.finish(value) }
            }
        ) { actions in
            if continuous {
                VStack(spacing: SettingsSliderLabelPolicy.gap) {
                    track(actions)
                        .accessibilityAction(named: request.resetLabel ?? "Use default") {
                            guard actions.admitsInput(), let reference = request.referenceValue else { return }
                            withAnimation(reduceMotion ? .easeOut(duration: 0.12) : .easeInOut(duration: 0.28)) {
                                select(reference)
                            }
                        }
                    SettingsNumberSliderLabelsLayout(defaultProgress: scale.progress(for: scale.defaultValue)) {
                        Text(minimum.formatted())
                        Text("Default")
                            .font(TronTypography.code(size: TronTypography.sizeBodySM, weight: .semibold))
                            .foregroundStyle(anchor.accent)
                        Text(maximumLabel)
                    }
                    .font(TronTypography.secondaryCodeDescription.weight(.bold))
                    .foregroundStyle(colorScheme == .dark ? Color.white : Color.tronTextSecondary)
                    .lineLimit(1).minimumScaleFactor(0.6).accessibilityHidden(true)
                    .padding(.horizontal, SettingsSliderLabelPolicy.inset)
                }
            } else {
                VStack(spacing: SettingsSliderLabelPolicy.gap) {
                    track(actions)
                    HStack {
                        Text(minimum.formatted())
                        Spacer()
                        Text(maximumLabel)
                    }
                    .font(TronTypography.secondaryCodeDescription.weight(.bold))
                    .foregroundStyle(Color.tronTextSecondary)
                    .padding(.horizontal, SettingsSliderLabelPolicy.inset)
                    .accessibilityHidden(true)
                }
            }
        }
    }

    private var maximumLabel: String {
        dynamicTypeSize.isAccessibilitySize
            ? maximum.formatted(.number.notation(.compactName).precision(.fractionLength(0...2)))
            : maximum.formatted()
    }

    private func track(_ actions: ConfigurationSliderActions) -> some View {
        ConfigurationSliderTrack(
            progress: progress, stops: scale.detents.map(scale.progress),
            emphasizedStop: continuous ? scale.progress(for: scale.defaultValue) : progress,
            accent: anchor.accent, title: request.title,
            value: formatted + suffix + (continuous && value == request.referenceValue ? ", default" : ""),
            hint: hint, identifier: request.identifier,
            feedback: continuous ? feedbackDetent : scale.detents.first { $0 == value }, actions: actions,
            change: { raw, width in
                guard raw.isFinite else { return }
                if continuous {
                    progress = scale.attractedProgress(raw, trackWidth: width)
                    value = scale.value(at: progress)
                    changed = true
                    let nearest = scale.nearestDetent(to: progress)
                    feedbackDetent = abs(scale.progress(for: nearest) - progress) * width < 5 ? nearest : nil
                } else {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.10)) { select(steppedValue(scale.value(at: raw))) }
                }
            },
            settle: { raw, width in
                guard raw.isFinite else { return }
                select(continuous ? scale.settledValue(at: raw, trackWidth: width) : steppedValue(scale.value(at: raw)))
            },
            adjust: { increasing in
                if continuous { select(scale.adjacentDetent(to: value, increasing: increasing)) }
                else { select(steppedValue(value + (increasing ? Int(request.range.step ?? 1) : -Int(request.range.step ?? 1)))) }
            }
        )
    }

    private func select(_ candidate: Int) {
        value = scale.clamp(candidate)
        progress = scale.progress(for: value)
        feedbackDetent = scale.detents.contains(value) ? value : nil
        changed = true
    }

    private func steppedValue(_ candidate: Int) -> Int {
        let step = max(1, Int(request.range.step ?? 1))
        let bounded = scale.clamp(candidate)
        let aligned = minimum + Int((Double(bounded - minimum) / Double(step)).rounded()) * step
        return scale.clamp(aligned)
    }
}

/// Slider end labels sit under the track's ends, near the track rather than at
/// the container's edges: inset by about the thumb's radius, a small gap below.
enum SettingsSliderLabelPolicy {
    static let inset: CGFloat = 18
    static let gap: CGFloat = 4
}

struct SettingsNumberSelectionRow: View {
    let title: String
    let value: Int
    let display: String
    let range: SettingsRange
    var icon = "number"
    var detail: String? = nil
    var information: String? = nil
    var accent: Color? = nil
    var actionDisplay: String? = nil
    var referenceValue: Int? = nil
    var resetLabel: String? = nil
    var selectionIdentity: Int? = nil
    var identifier = "settings-number-control"
    var sliderIdentifier = "settings-number-slider"
    let onChange: (Int) -> Void
    @State private var ownerID = UUID()
    @Environment(\.configurationSliderPresentation) private var sliderPresentation
    @Environment(\.controlSize) private var controlSize
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.tronPresentationActivity) private var activity
    @Environment(\.tronPresentationSurfaceToken) private var surfaceToken
    @Environment(\.tronSettingsVisualTheme) private var theme

    private var rowAccent: Color { accent ?? theme?.accent ?? .tronTeal }

    var body: some View {
        AgentConfigurationValueRow(icon: icon, title: title,
                                    detail: detail ?? "Range: \(Int(range.min))–\(Int(range.max))\(range.unit.map { " \($0)" } ?? "")",
                                    information: information, value: display, accent: rowAccent) {
            Button {
                guard isEnabled, activity.allowsPresentationPublication, sliderPresentation?.session == nil else { return }
                sliderPresentation?.open(owner: ownerID, surface: surfaceToken)
            } label: { TronInlineActionLabel(actionDisplay ?? display, accent: rowAccent) }
            .buttonStyle(.plain)
            .disabled(sliderPresentation == nil)
            .opacity(sliderPresentation?.session?.owner == ownerID ? 0 : 1)
            .accessibilityLabel(title)
            .accessibilityValue(display)
            .accessibilityIdentifier(identifier)
            .anchorPreference(key: ConfigurationSliderPreference.self, value: .bounds) { anchor in
                guard let session = sliderPresentation?.session, session.owner == ownerID,
                      isEnabled, activity.allowsPresentationPublication else { return nil }
                return ConfigurationSliderRequest(
                    session: session, anchor: anchor, sourceVerticalInset: controlSize == .small ? 8 : 0,
                    accent: theme?.accent ?? rowAccent,
                    editor: .number(SettingsNumberSliderRequest(
                        title: title, value: value, range: range, unit: range.unit,
                        referenceValue: referenceValue, resetLabel: resetLabel, collapsedTitle: actionDisplay,
                        detail: detail, identifier: sliderIdentifier
                    ) { next in
                        guard isEnabled, activity.allowsPresentationPublication else { return }
                        onChange(next)
                    })
                )
            }
        }
        .onChange(of: value) { _, _ in cancel() }
        .onChange(of: range) { _, _ in cancel() }
        .onChange(of: referenceValue) { _, _ in cancel() }
        .onChange(of: selectionIdentity) { _, _ in cancel() }
        .onChange(of: isEnabled) { _, enabled in if !enabled { cancel() } }
        .onDisappear { cancel() }
        .accessibilityHint(referenceValue == nil ? "Opens a bounded slider. Dismiss to save."
                           : "\(detail ?? "") Opens a continuous slider with gentle detents. Dismiss to save.")
    }

    private func cancel() { sliderPresentation?.cancel(owner: ownerID) }
}
