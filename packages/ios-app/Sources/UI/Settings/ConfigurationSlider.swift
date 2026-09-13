import SwiftUI

/// One host admits one exact editor. Replacement, cancellation and completion
/// retire its input authority synchronously, before another animation callback.
@MainActor @Observable
final class ConfigurationSliderPresentation {
    struct Session: Equatable {
        let id = UUID()
        let owner: UUID
        // Pinned at admission; completion cannot substitute a newer generation.
        let surface: PresentationSurfaceToken?
    }
    private(set) var session: Session?
    private(set) var closing = false

    @discardableResult
    func open(owner: UUID, surface: PresentationSurfaceToken? = nil) -> Session {
        let next = Session(owner: owner, surface: surface)
        session = next
        closing = false
        return next
    }

    func admitsInput(_ candidate: Session) -> Bool { session == candidate && !closing }

    func beginClosing(_ candidate: Session) -> Bool {
        guard admitsInput(candidate) else { return false }
        closing = true
        return true
    }

    func finish(_ candidate: Session, commit: () -> Void) {
        guard session == candidate, closing else { return }
        session = nil
        closing = false
        commit()
    }

    func cancel(_ candidate: Session) {
        guard session == candidate else { return }
        session = nil
        closing = false
    }

    func cancel(owner: UUID) {
        if let session, session.owner == owner { cancel(session) }
    }
}

extension EnvironmentValues {
    @Entry var configurationSliderPresentation: ConfigurationSliderPresentation? = nil
}

struct ConfigurationSliderRequest {
    enum Editor {
        case contextWindow(ContextWindowSliderRequest)
        case thinking(ThinkingSliderRequest)
    }
    let session: ConfigurationSliderPresentation.Session
    let anchor: Anchor<CGRect>
    let sourceVerticalInset: CGFloat
    let accent: Color
    let editor: Editor
}

struct ConfigurationSliderPreference: PreferenceKey {
    static var defaultValue: ConfigurationSliderRequest? { nil }
    static func reduce(value: inout ConfigurationSliderRequest?, nextValue: () -> ConfigurationSliderRequest?) {
        value = nextValue() ?? value
    }
}

extension View {
    /// Install outside scrolling content: both controls share one overlay and
    /// cannot relayout rows, leak outside taps, or leave a hidden second editor.
    func tronConfigurationSliderHost(_ presentation: ConfigurationSliderPresentation) -> some View {
        modifier(ConfigurationSliderHost(presentation: presentation))
    }
}

private struct ConfigurationSliderHost: ViewModifier {
    let presentation: ConfigurationSliderPresentation
    @Environment(\.tronPresentationSurfaceToken) private var surfaceToken
    @Environment(\.tronPresentationActivity) private var activity

    func body(content: Content) -> some View {
        content
            .environment(\.configurationSliderPresentation, presentation)
            .overlayPreferenceValue(ConfigurationSliderPreference.self) { request in
                if let request, request.session == presentation.session {
                    GeometryReader { geometry in
                        let source = geometry[request.anchor].insetBy(dx: 0, dy: request.sourceVerticalInset)
                        Group {
                            switch request.editor {
                            case .contextWindow(let editor):
                                ContextWindowSliderEditor(request: editor, anchor: request, source: source,
                                                          availableSize: geometry.size, presentation: presentation)
                            case .thinking(let editor):
                                ThinkingSliderEditor(request: editor, anchor: request, source: source,
                                                     availableSize: geometry.size, presentation: presentation)
                            }
                        }
                        .id(request.session.id)
                    }
                    .transition(.identity)
                }
            }
            .onChange(of: surfaceToken) { _, _ in cancel() }
            .onChange(of: activity) { _, value in if !value.allowsPresentationPublication { cancel() } }
            .onDisappear { cancel() }
    }

    private func cancel() {
        if let owner = presentation.session?.owner { presentation.cancel(owner: owner) }
    }
}

struct ConfigurationSliderActions {
    let admitsInput: () -> Bool
    let dismiss: () -> Void
    let focus: AccessibilityFocusState<Bool>.Binding
}

/// Shared motion, header, focus and dismissal lifecycle. Domain editors own
/// their local drafts; this container never stores a canonical setting.
struct ConfigurationSliderContainer<Content: View>: View {
    let title: String
    let value: String
    let collapsedTitle: String
    let anchor: ConfigurationSliderRequest
    let source: CGRect
    let availableSize: CGSize
    let presentation: ConfigurationSliderPresentation
    let finish: () -> Void
    @ViewBuilder let content: (ConfigurationSliderActions) -> Content
    @State private var expanded = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.tronPresentationActivity) private var activity
    @Environment(\.tronPresentationSurfaceToken) private var surfaceToken
    @Environment(\.tronPresentationActivityCoordinator) private var activityCoordinator
    @ScaledMetric(relativeTo: .body) private var contextPanelHeight: CGFloat = 170
    @ScaledMetric(relativeTo: .body) private var thinkingPanelHeight: CGFloat = 140
    @AccessibilityFocusState private var sliderFocused: Bool

    private var target: CGRect {
        let width = min(480, max(1, availableSize.width - 36))
        let preferredHeight: CGFloat
        switch anchor.editor {
        case .contextWindow: preferredHeight = contextPanelHeight
        case .thinking: preferredHeight = thinkingPanelHeight
        }
        let height = min(preferredHeight, max(1, availableSize.height - 24))
        return CGRect(
            x: min(max(18, source.maxX - width), max(18, availableSize.width - width - 18)),
            y: min(max(12, source.midY - height / 2), max(12, availableSize.height - height - 12)),
            width: width, height: height
        )
    }

    private var motion: Animation {
        // A finite curve cannot bounce across the clamped interaction boundary.
        reduceMotion ? .easeOut(duration: 0.12) : .easeInOut(duration: 0.28)
    }

    private var admitsPresentation: Bool {
        activity.allowsPresentationPublication && surfaceToken == anchor.session.surface
            && (activityCoordinator?.activity(for: anchor.session.surface).allowsPresentationPublication ?? true)
    }

    var body: some View {
        let actions = ConfigurationSliderActions(
            admitsInput: { admitsPresentation && presentation.admitsInput(anchor.session) }, dismiss: close, focus: $sliderFocused
        )
        ZStack(alignment: .topLeading) {
            Color.clear.ignoresSafeArea().contentShape(Rectangle())
                .onTapGesture { close() }.accessibilityHidden(true)
            ConfigurationSliderSurface(
                source: source, target: target, fraction: expanded ? 1 : 0,
                reduceMotion: reduceMotion, accent: anchor.accent
            ) {
                // Keep one content tree. Fitting content centers; large text
                // or a short viewport can scroll without duplicating glass.
                ScrollView { panel(actions).frame(minHeight: target.height) }
                    .scrollBounceBehavior(.basedOnSize)
                    .scrollIndicatorsFlash(onAppear: true)
                    .allowsHitTesting(expanded && presentation.admitsInput(anchor.session))
            } label: {
                Text(collapsedTitle)
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                    .monospacedDigit()
                    .tronSettingsButtonForeground(anchor.accent)
                    .lineLimit(1).minimumScaleFactor(0.7).padding(.horizontal, 10)
            }
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isModal)
            .accessibilityAction(.escape) { close() }
        }
        .onAppear {
            guard admitsPresentation, presentation.admitsInput(anchor.session) else { return }
            withAnimation(motion, completionCriteria: .logicallyComplete) { expanded = true } completion: {
                if admitsPresentation, presentation.admitsInput(anchor.session) { sliderFocused = true }
            }
        }
        .onChange(of: presentation.closing, initial: true) { _, closing in
            guard closing, presentation.session == anchor.session else { return }
            sliderFocused = false
            withAnimation(motion, completionCriteria: .logicallyComplete) { expanded = false } completion: {
                // Read the owning surface registry again: retirement can precede
                // SwiftUI's next onChange/onDisappear pass.
                guard admitsPresentation else { presentation.cancel(anchor.session); return }
                presentation.finish(anchor.session, commit: finish)
            }
        }
    }

    private func panel(_ actions: ConfigurationSliderActions) -> some View {
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
            .font(TronTypography.buttonSM).accessibilityHidden(true)
            content(actions)
        }
        .padding(20)
        .frame(maxWidth: .infinity)
    }

    private var headerTitle: some View {
        Text(title).foregroundStyle(colorScheme == .dark ? Color.white : Color.tronTextSecondary)
    }
    private var headerValue: some View {
        Text(value).monospacedDigit().tronSettingsButtonForeground(anchor.accent)
            .lineLimit(1).minimumScaleFactor(0.7)
    }

    private func close() {
        guard admitsPresentation else { presentation.cancel(anchor.session); return }
        _ = presentation.beginClosing(anchor.session)
    }
}

/// One rail/knob and gesture owner for continuous tokens and discrete levels.
/// The editor supplies domain mapping; raw finger movement is never persisted.
struct ConfigurationSliderTrack: View {
    let progress: Double
    let stops: [Double]
    var emphasizedStop: Double? = nil
    var showsThumb = true
    let accent: Color
    let title: String
    let value: String
    let hint: String
    let identifier: String
    let feedback: Int?
    let actions: ConfigurationSliderActions
    let change: (Double, Double) -> Void
    let settle: (Double, Double) -> Void
    let adjust: (Bool) -> Void
    @State private var dragging = false
    @State private var dragOrigin: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    nonisolated static let inset: CGFloat = 22

    var body: some View {
        GeometryReader { geometry in
            let width = max(1, geometry.size.width - Self.inset * 2)
            let thumbX = Self.inset + CGFloat(progress) * width
            ZStack(alignment: .leading) {
                Capsule().fill(accent.opacity(0.10))
                    .overlay { Capsule().strokeBorder(accent.opacity(0.12), lineWidth: 0.5) }
                    .frame(height: 42)
                Capsule()
                    .fill(LinearGradient(colors: [accent.opacity(0.24), accent.opacity(0.55)], startPoint: .leading, endPoint: .trailing))
                    .frame(width: thumbX + Self.inset, height: 42).opacity(showsThumb ? 1 : 0)
                ForEach(stops, id: \.self) { stop in
                    Circle().fill(stop == emphasizedStop ? accent : Color.tronTextSecondary.opacity(0.4))
                        .frame(width: stop == emphasizedStop ? 5 : 3, height: stop == emphasizedStop ? 5 : 3)
                        .position(x: Self.inset + CGFloat(stop) * width, y: 26)
                }
                Circle().fill(accent.opacity(0.16))
                    .overlay { Circle().strokeBorder(.white.opacity(0.65), lineWidth: 1).padding(1) }
                    .glassEffect(.regular.tint(accent.opacity(0.16)).interactive(), in: .circle)
                    .frame(width: 38, height: 38)
                    .scaleEffect(dragging && !reduceMotion ? 1.12 : 1)
                    .shadow(color: accent.opacity(0.22), radius: 5, y: 2)
                    .position(x: thumbX, y: 26).opacity(showsThumb ? 1 : 0)
            }
            .frame(height: 52).contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { gesture in
                    guard actions.admitsInput() else { return }
                    if dragOrigin == nil {
                        let start = (gesture.startLocation.x - Self.inset) / width
                        dragOrigin = showsThumb && abs(gesture.startLocation.x - thumbX) <= 24 ? progress : Double(start)
                        withAnimation(reduceMotion ? nil : .smooth(duration: 0.16)) { dragging = true }
                    }
                    change((dragOrigin ?? progress) + Double(gesture.translation.width / width), Double(width))
                }
                .onEnded { _ in
                    guard actions.admitsInput() else { return }
                    dragOrigin = nil
                    withAnimation(reduceMotion ? nil : .spring(duration: 0.22, bounce: 0.08)) {
                        dragging = false
                        settle(progress, Double(width))
                    }
                })
        }
        .frame(height: 52)
        .sensoryFeedback(.selection, trigger: feedback) { _, next in next != nil }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title).accessibilityValue(value).accessibilityHint(hint)
        .accessibilityAdjustableAction { direction in
            guard actions.admitsInput() else { return }
            switch direction {
            case .increment: adjust(true)
            case .decrement: adjust(false)
            @unknown default: break
            }
        }
        .accessibilityAction(named: "Save and close", actions.dismiss)
        .accessibilityFocused(actions.focus)
        .accessibilityIdentifier(identifier)
    }
}
