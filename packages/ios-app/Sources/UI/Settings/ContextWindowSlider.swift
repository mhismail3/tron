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
    let id: UUID
    let anchor: Anchor<CGRect>
    let sourceVerticalInset: CGFloat
    let scale: ContextWindowSliderScale
    let value: Int
    let selection: Int?
    let title: String
    let resetLabel: String
    let detail: String
    let accent: Color
    let finish: (ContextWindowSliderDraft) -> Void
}

struct ContextWindowSliderPreference: PreferenceKey {
    static var defaultValue: ContextWindowSliderRequest? { nil }
    static func reduce(value: inout ContextWindowSliderRequest?, nextValue: () -> ContextWindowSliderRequest?) {
        value = nextValue() ?? value
    }
}

extension View {
    /// Install outside the scrolling surface so glass can grow beyond the row
    /// without relayout, scroll jumps, or taps leaking into neighboring actions.
    func tronContextWindowSliderHost() -> some View {
        overlayPreferenceValue(ContextWindowSliderPreference.self) { request in
            if let request {
                GeometryReader { geometry in
                    ContextWindowSliderOverlay(
                        request: request,
                        source: geometry[request.anchor].insetBy(dx: 0, dy: request.sourceVerticalInset),
                        availableSize: geometry.size
                    )
                    .id(request.id)
                }
                .transition(.identity)
            }
        }
    }
}

private struct ContextWindowSliderOverlay: View {
    let request: ContextWindowSliderRequest
    let source: CGRect
    let availableSize: CGSize
    @State private var draft: ContextWindowSliderDraft
    @State private var progress: Double
    @State private var expanded = false
    @State private var closing = false
    @State private var dragging = false
    @State private var dragOrigin: Double?
    @State private var feedbackDetent: Int?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var panelHeight: CGFloat = 170
    @AccessibilityFocusState private var sliderFocused: Bool

    init(request: ContextWindowSliderRequest, source: CGRect, availableSize: CGSize) {
        self.request = request
        self.source = source
        self.availableSize = availableSize
        _draft = State(initialValue: ContextWindowSliderDraft(value: request.scale.clamp(request.value), selection: request.selection))
        _progress = State(initialValue: request.scale.progress(for: request.value))
    }

    private var target: CGRect {
        let width = min(480, max(1, availableSize.width - 36))
        let height = min(panelHeight, max(170, availableSize.height - 24))
        let x = min(max(18, source.maxX - width), max(18, availableSize.width - width - 18))
        let y = min(max(12, source.midY - height / 2), max(12, availableSize.height - height - 12))
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private var motion: Animation {
        reduceMotion ? .easeOut(duration: 0.12) : .spring(duration: 0.42, bounce: 0.12)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { close() }
                .accessibilityHidden(true)
            ContextWindowSliderSurface(
                source: source, target: target, fraction: expanded ? 1 : 0,
                reduceMotion: reduceMotion, accent: request.accent
            ) {
                panel
                    .allowsHitTesting(expanded && !closing)
            } label: {
                Text(draft.changed ? draft.value.formatted() : request.title)
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                    .monospacedDigit()
                    .tronSettingsButtonForeground(request.accent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.horizontal, 10)
            }
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isModal)
            .accessibilityAction(.escape) { close() }
        }
        .onAppear {
            withAnimation(motion) { expanded = true }
            sliderFocused = true
        }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 12) {
                    headerTitle.fixedSize()
                    Spacer(minLength: 0)
                    headerValue.fixedSize()
                }
                VStack(alignment: .leading, spacing: 8) {
                    headerTitle.fixedSize(horizontal: false, vertical: true)
                    headerValue.frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .font(TronTypography.buttonSM)
            .accessibilityHidden(true)

            VStack(spacing: 4) {
                track
                ContextWindowSliderLabelsLayout(defaultProgress: request.scale.progress(for: request.scale.defaultValue)) {
                    Text(request.scale.limits.minimum.formatted())
                    Text("Default")
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                        .foregroundStyle(request.accent)
                    Text(dynamicTypeSize.isAccessibilitySize
                         ? request.scale.limits.maximum.formatted(.number.notation(.compactName).precision(.fractionLength(0...2)))
                         : request.scale.limits.maximum.formatted())
                }
                .font(TronTypography.secondaryCodeDescription)
                .foregroundStyle(Color.tronTextSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .accessibilityHidden(true)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var headerTitle: some View {
        Text("Context Window").foregroundStyle(Color.tronTextSecondary)
    }

    private var headerValue: some View {
        Text(draft.value.formatted())
            .monospacedDigit()
            .tronSettingsButtonForeground(request.accent)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }

    private var track: some View {
        GeometryReader { geometry in
            let inset = ContextWindowSliderLabelsLayout.trackInset
            let width = max(1, geometry.size.width - inset * 2)
            let thumbX = inset + CGFloat(progress) * width
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(request.accent.opacity(0.10))
                    .overlay { Capsule().strokeBorder(request.accent.opacity(0.12), lineWidth: 0.5) }
                    .frame(height: 42)
                Capsule()
                    .fill(LinearGradient(colors: [request.accent.opacity(0.24), request.accent.opacity(0.55)], startPoint: .leading, endPoint: .trailing))
                    .frame(width: thumbX + inset, height: 42)
                ForEach(request.scale.detents, id: \.self) { value in
                    Circle()
                        .fill(value == request.scale.defaultValue ? request.accent : Color.tronTextSecondary.opacity(0.4))
                        .frame(width: value == request.scale.defaultValue ? 5 : 3,
                               height: value == request.scale.defaultValue ? 5 : 3)
                        .position(x: inset + CGFloat(request.scale.progress(for: value)) * width, y: 26)
                }
                Circle()
                    .fill(request.accent.opacity(0.16))
                    .overlay {
                        Circle().strokeBorder(.white.opacity(0.65), lineWidth: 1)
                            .padding(1)
                    }
                    .glassEffect(.regular.tint(request.accent.opacity(0.16)).interactive(), in: .circle)
                    .frame(width: 38, height: 38)
                    .scaleEffect(dragging && !reduceMotion ? 1.12 : 1)
                    .shadow(color: request.accent.opacity(0.22), radius: 5, y: 2)
                    .position(x: thumbX, y: 26)
            }
            .frame(height: 52)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        guard !closing else { return }
                        if dragOrigin == nil {
                            // Preserve the finger's offset when grabbing the knob;
                            // tapping elsewhere on the track seeks immediately.
                            let start = (gesture.startLocation.x - inset) / width
                            dragOrigin = abs(gesture.startLocation.x - thumbX) <= 24 ? progress : Double(start)
                            withAnimation(.smooth(duration: 0.16)) { dragging = true }
                        }
                        let raw = (dragOrigin ?? progress) + Double(gesture.translation.width / width)
                        progress = request.scale.attractedProgress(raw, trackWidth: Double(width))
                        draft.select(request.scale.tokens(at: progress), defaultValue: request.scale.defaultValue)
                        let nearest = request.scale.nearestDetent(to: progress)
                        feedbackDetent = abs(request.scale.progress(for: nearest) - progress) * Double(width) < 5 ? nearest : nil
                    }
                    .onEnded { _ in
                        guard !closing else { return }
                        dragOrigin = nil
                        withAnimation(.spring(duration: 0.22, bounce: 0.08)) {
                            dragging = false
                            select(request.scale.settledTokens(at: progress, trackWidth: Double(width)))
                        }
                    }
            )
        }
        .frame(height: 52)
        .sensoryFeedback(.selection, trigger: feedbackDetent) { _, next in next != nil }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Context Window")
        .accessibilityValue("\(draft.value.formatted()) tokens\(draft.value == request.scale.defaultValue ? ", default" : "")")
        .accessibilityHint(request.detail + " Adjust to a detent, or drag for any value. Dismiss to save.")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: select(request.scale.adjacentDetent(to: draft.value, increasing: true))
            case .decrement: select(request.scale.adjacentDetent(to: draft.value, increasing: false))
            @unknown default: break
            }
        }
        .accessibilityAction(named: request.resetLabel) {
            withAnimation(motion) { select(request.scale.defaultValue) }
        }
        .accessibilityAction(named: "Save and close") { close() }
        .accessibilityFocused($sliderFocused)
        .accessibilityIdentifier("context-window-slider")
    }

    private func select(_ value: Int) {
        let bounded = request.scale.clamp(value)
        draft.select(bounded, defaultValue: request.scale.defaultValue)
        progress = request.scale.progress(for: bounded)
        feedbackDetent = request.scale.detents.contains(bounded) ? bounded : nil
    }

    private func close() {
        guard !closing else { return }
        closing = true
        sliderFocused = false
        // Completion belongs to this exact editor identity. The row checks it
        // again before committing, so model/runtime replacement discards drafts.
        withAnimation(motion, completionCriteria: .logicallyComplete) {
            expanded = false
        } completion: {
            request.finish(draft)
        }
    }
}
