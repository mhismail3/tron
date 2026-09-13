import SwiftUI

/// Detents are navigation aids, not new model limits or a quantized slider.
struct ContextWindowSliderScale {
    let limits: ContextWindowLimits
    let defaultValue: Int

    var detents: [Int] {
        guard limits.maximum > limits.minimum else { return [limits.minimum] }
        // Million-token catalogs sometimes include extra capacity (1,048,576
        // or 1,050,000). Keep familiar quarters, but the endpoint stays exact.
        let reference = (1_000_000...1_100_000).contains(limits.maximum) ? 1_000_000 : limits.maximum
        let quarter = Double(reference) / 4
        let rounding = pow(10, max(0, floor(log10(quarter)) - 1))
        let preferred = clamp(defaultValue)
        // Models whose configured default is already the full million still
        // get a useful 200k landmark; this never changes their actual default.
        let baseline = reference == 1_000_000 && preferred > 400_000 ? clamp(200_000) : preferred
        let separation = Double(limits.maximum - limits.minimum) * 0.08
        let quarters = (1...3).map { Int((quarter * Double($0) / rounding).rounded() * rounding) }
            .filter { limits.admits($0) && abs(Double($0 - preferred)) > separation && abs(Double($0 - baseline)) > separation }
        return Set([limits.minimum, limits.maximum, preferred, baseline] + quarters).sorted()
    }

    func clamp(_ value: Int) -> Int { min(limits.maximum, max(limits.minimum, value)) }

    func progress(for value: Int) -> Double {
        guard limits.maximum > limits.minimum else { return 0 }
        return Double(clamp(value) - limits.minimum) / Double(limits.maximum - limits.minimum)
    }

    func tokens(at progress: Double) -> Int {
        let bounded = min(1, max(0, progress))
        return clamp(limits.minimum + Int((bounded * Double(limits.maximum - limits.minimum)).rounded()))
    }

    func nearestDetent(to progress: Double) -> Int {
        detents.min { abs(self.progress(for: $0) - progress) < abs(self.progress(for: $1) - progress) } ?? limits.minimum
    }

    /// Point-based attraction feels the same on narrow phones and wide sheets.
    /// It is continuous through each well, without a sticky dead zone or jumps.
    func attractedProgress(_ raw: Double, trackWidth: Double) -> Double {
        let bounded = min(1, max(0, raw))
        guard trackWidth > 0 else { return bounded }
        let nearest = nearestDetent(to: bounded)
        let delta = progress(for: nearest) - bounded
        let distance = abs(delta) * trackWidth
        let radius = attractionRadius(for: nearest, trackWidth: trackWidth)
        guard radius > 0, distance < radius else { return bounded }
        return bounded + delta * 0.72 * pow(1 - distance / radius, 2)
    }

    func settledTokens(at progress: Double, trackWidth: Double) -> Int {
        let nearest = nearestDetent(to: progress)
        if abs(self.progress(for: nearest) - progress) * max(1, trackWidth)
            <= attractionRadius(for: nearest, trackWidth: max(1, trackWidth)) / 2 { return nearest }
        return tokens(at: progress)
    }

    private func attractionRadius(for detent: Int, trackWidth: Double) -> Double {
        // Adjacent wells must not overlap: switching nearest stops would
        // otherwise jump when a configured default is close to a bound.
        let spacing = detents.filter { $0 != detent }
            .map { abs(progress(for: $0) - progress(for: detent)) * trackWidth }
            .min() ?? 36
        return min(18, spacing / 2)
    }

    func adjacentDetent(to value: Int, increasing: Bool) -> Int {
        if increasing { return detents.first(where: { $0 > value }) ?? limits.maximum }
        return detents.last(where: { $0 < value }) ?? limits.minimum
    }
}

/// Draft state never writes through the binding during a drag. Merely opening
/// an inherited or bounded value must not silently turn it into an override.
struct ContextWindowSliderDraft {
    private(set) var value: Int
    private(set) var selection: Int?
    private(set) var changed = false

    init(value: Int, selection: Int?) {
        self.value = value
        self.selection = selection
    }

    mutating func select(_ value: Int, defaultValue: Int) {
        self.value = value
        selection = value == defaultValue ? nil : value
        changed = true
    }
}

struct ContextWindowSliderRequest {
    let scale: ContextWindowSliderScale
    let value: Int
    let selection: Int?
    let title: String
    let resetLabel: String
    let detail: String
    let finish: (ContextWindowSliderDraft) -> Void
}

struct ContextWindowSliderEditor: View {
    let request: ContextWindowSliderRequest
    let anchor: ConfigurationSliderRequest
    let source: CGRect
    let availableSize: CGSize
    let presentation: ConfigurationSliderPresentation
    @State private var draft: ContextWindowSliderDraft
    @State private var progress: Double
    @State private var feedbackDetent: Int?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(request: ContextWindowSliderRequest, anchor: ConfigurationSliderRequest, source: CGRect,
         availableSize: CGSize, presentation: ConfigurationSliderPresentation) {
        self.request = request
        self.anchor = anchor
        self.source = source
        self.availableSize = availableSize
        self.presentation = presentation
        _draft = State(initialValue: ContextWindowSliderDraft(value: request.scale.clamp(request.value), selection: request.selection))
        _progress = State(initialValue: request.scale.progress(for: request.value))
    }

    var body: some View {
        ConfigurationSliderContainer(
            title: "Context Window", value: draft.value.formatted(),
            collapsedTitle: draft.changed ? draft.value.formatted() : request.title,
            anchor: anchor, source: source, availableSize: availableSize, presentation: presentation,
            finish: { request.finish(draft) }
        ) { actions in
            VStack(spacing: 4) {
                ConfigurationSliderTrack(
                    progress: progress, stops: request.scale.detents.map(request.scale.progress),
                    emphasizedStop: request.scale.progress(for: request.scale.defaultValue), accent: anchor.accent,
                    title: "Context Window",
                    value: "\(draft.value.formatted()) tokens\(draft.value == request.scale.defaultValue ? ", default" : "")",
                    hint: request.detail + " Adjust to a detent, or drag for any value. Dismiss to save.",
                    identifier: "context-window-slider", feedback: feedbackDetent, actions: actions,
                    change: { raw, width in
                        progress = request.scale.attractedProgress(raw, trackWidth: width)
                        draft.select(request.scale.tokens(at: progress), defaultValue: request.scale.defaultValue)
                        let nearest = request.scale.nearestDetent(to: progress)
                        feedbackDetent = abs(request.scale.progress(for: nearest) - progress) * width < 5 ? nearest : nil
                    },
                    settle: { progress, width in select(request.scale.settledTokens(at: progress, trackWidth: width)) },
                    adjust: { select(request.scale.adjacentDetent(to: draft.value, increasing: $0)) }
                )
                .accessibilityAction(named: request.resetLabel) {
                    guard actions.admitsInput() else { return }
                    withAnimation(reduceMotion ? .easeOut(duration: 0.12) : .easeInOut(duration: 0.28)) {
                        select(request.scale.defaultValue)
                    }
                }
                ContextWindowSliderLabelsLayout(defaultProgress: request.scale.progress(for: request.scale.defaultValue)) {
                    Text(request.scale.limits.minimum.formatted())
                    Text("Default")
                        .font(TronTypography.code(size: TronTypography.sizeBodySM, weight: .semibold))
                        .foregroundStyle(anchor.accent)
                    Text(dynamicTypeSize.isAccessibilitySize
                         ? request.scale.limits.maximum.formatted(.number.notation(.compactName).precision(.fractionLength(0...2)))
                         : request.scale.limits.maximum.formatted())
                }
                .font(TronTypography.secondaryCodeDescription.weight(.bold))
                .foregroundStyle(colorScheme == .dark ? Color.white : Color.tronTextSecondary)
                .lineLimit(1).minimumScaleFactor(0.6).accessibilityHidden(true)
            }
        }
    }

    private func select(_ value: Int) {
        let bounded = request.scale.clamp(value)
        draft.select(bounded, defaultValue: request.scale.defaultValue)
        progress = request.scale.progress(for: bounded)
        feedbackDetent = request.scale.detents.contains(bounded) ? bounded : nil
    }
}
