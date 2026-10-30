import SwiftUI

/// Only the title and backdrop observe scroll geometry. Catalogue inputs and
/// row identity never depend on this per-frame presentation state.
@MainActor @Observable
final class DashboardHeaderState {
    static let blurFadeDistance: CGFloat = 80
    static let stretchDistance: CGFloat = 120
    static let initialDrop: CGFloat = 25
    static let titleSize: CGFloat = 34
    private(set) var offset: CGFloat = 0

    var progress: CGFloat { max(0, offset / Self.blurFadeDistance) }

    static func boundedOffset(_ offset: CGFloat) -> CGFloat {
        guard offset.isFinite else { return offset }
        return min(blurFadeDistance, max(-stretchDistance, offset))
    }

    func verticalOffset(reduceMotion: Bool) -> CGFloat {
        reduceMotion ? 0 : Self.initialDrop * (1 - Self.ease(progress))
    }

    // Two base font points of shrink, or at most six percent of pull stretch.
    func titleScale(reduceMotion: Bool) -> CGFloat {
        guard !reduceMotion else { return 1 }
        let pull = max(0, -offset / Self.stretchDistance)
        return 1 - (2 / Self.titleSize) * Self.ease(progress) + 0.06 * Self.ease(pull)
    }

    private static func ease(_ value: CGFloat) -> CGFloat {
        // Continuous slope at rest and at both caps, with no delayed animation
        // competing against the scroll view's own deceleration/rubber band.
        value * value * (3 - 2 * value)
    }

    func update(offset: CGFloat) {
        guard offset.isFinite else { return }
        let next = Self.boundedOffset(offset)
        guard next != self.offset else { return }
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) { self.offset = next }
    }
}

/// The Sessions dashboard's chrome: title, top blur and the one floating
/// button. Content and accepted actions remain with the dashboard.
struct DashboardChrome<Content: View>: View {
    let header: DashboardHeaderState
    let onOpenAutomations: @MainActor () -> Void
    let onOpenApps: @MainActor () -> Void
    let actions: DashboardMenuActions
    /// Set where the dashboard offers Home: its one button then opens Home on a
    /// tap and the dashboard menu on touch and hold.
    let home: DashboardHomeControl?
    private let content: Content

    init(
        header: DashboardHeaderState,
        onOpenAutomations: @escaping @MainActor () -> Void,
        onOpenApps: @escaping @MainActor () -> Void,
        actions: DashboardMenuActions,
        home: DashboardHomeControl? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.header = header
        self.onOpenAutomations = onOpenAutomations
        self.onOpenApps = onOpenApps
        self.actions = actions
        self.home = home
        self.content = content()
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            content
            DashboardBackdrop(state: header)
            DashboardModeMenuButton(
                onOpenAutomations: onOpenAutomations,
                onOpenApps: onOpenApps,
                actions: actions,
                home: home
            )
            // UIKit owns the touch, tap/hold and menu; the icon swaps through
            // the shared indicator transition, so Home's states morph in place.
            // It sits behind the transparent button: SwiftUI content layered
            // above a UIKit view takes its touches.
            .background {
                DashboardIndicatorSwap(state: home?.state ?? .resting) { state in
                    HomeButtonIndicator(state: state, accent: .tronPrimary)
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            .tronDashboardFloatingCircle(accent: .tronPrimarySurface)
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { TronBackdrop().ignoresSafeArea() }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .safeAreaInset(edge: .top, spacing: 0) {
            DashboardTitle(state: header)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .padding(.horizontal, 20)
        }
    }
}

struct DashboardTitle: View {
    let state: DashboardHeaderState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Text("Tron")
            .font(TronTypography.sans(size: DashboardHeaderState.titleSize, weight: .bold))
            .foregroundStyle(Color.tronPrimary)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            // Fit long names before applying the small visual transform;
            // motion never changes the header's measured layout footprint.
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("dashboard.title")
            .scaleEffect(state.titleScale(reduceMotion: reduceMotion), anchor: .topLeading)
        .offset(y: state.verticalOffset(reduceMotion: reduceMotion))
    }
}

private struct DashboardBackdrop: View {
    let state: DashboardHeaderState

    var body: some View {
        TronTopBlurOverlay(style: .dashboard)
            .opacity(state.progress)
    }
}

private struct DashboardScrollModifier: ViewModifier {
    let header: DashboardHeaderState
    let topMargin: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            // A constant content margin scrolls away naturally. Translating the
            // UIScrollView itself changes UIKit's safe-area insets mid-gesture.
            .contentMargins(.top, topMargin + (reduceMotion ? 0 : DashboardHeaderState.initialDrop), for: .scrollContent)
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                DashboardHeaderState.boundedOffset(geometry.contentOffset.y + geometry.contentInsets.top)
            } action: { _, offset in
                header.update(offset: offset)
            }
    }
}

private struct DashboardInitialOffset: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        // Loading placeholders have no scroll content margin yet.
        content.offset(y: reduceMotion ? 0 : DashboardHeaderState.initialDrop)
    }
}

/// The floating search control of a dashboard list sheet: a circular button in
/// the sheet's bottom-trailing corner that expands into the search pill.
/// Scrolling the results dismisses the keyboard; only an empty query closes
/// the pill with it.
struct DashboardFloatingSearch: View {
    @Binding var text: String
    @Binding var isPresented: Bool
    let prompt: String
    let accent: Color
    let buttonLabel: String
    let buttonIdentifier: String
    let onDismiss: () -> Void

    var body: some View {
        Group {
            if isPresented {
                TronSearchBar(
                    text: $text,
                    prompt: prompt,
                    accent: accent,
                    focusOnAppear: true,
                    onClose: onDismiss,
                    onFocusChange: { focused in
                        if !focused && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { onDismiss() }
                    }
                )
                .padding(.horizontal, TronSpacing.section)
                .padding(.vertical, 8)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                DashboardFloatingButton(symbol: "magnifyingglass", accent: accent,
                                        label: buttonLabel, identifier: buttonIdentifier) {
                    isPresented = true
                }
            }
        }
        .animation(.snappy(duration: 0.18), value: isPresented)
    }
}

/// One floating circular action in a dashboard list sheet's bottom-trailing corner.
struct DashboardFloatingButton: View {
    let symbol: String
    let accent: Color
    let label: String
    let identifier: String
    var value: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(TronTypography.sans(size: 22, weight: .semibold))
                .foregroundStyle(accent)
                .tronDashboardFloatingCircle(accent: accent)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
        .accessibilityLabel(label)
        .accessibilityValue(value ?? "")
        .accessibilityIdentifier(identifier)
        .transition(.scale(scale: 0.72).combined(with: .opacity))
    }
}

extension View {
    /// The dashboard's one floating circular button chrome.
    func tronDashboardFloatingCircle(accent: Color) -> some View {
        frame(width: 56, height: 56)
            .contentShape(Circle())
            .glassEffect(.regular.tint(accent.opacity(0.22)).interactive(), in: .circle)
    }

    /// Attach to the concrete List/ScrollView, not a parent containing several
    /// scroll owners. Normalize the resting offset by its real safe-area inset.
    func tronDashboardScroll(_ header: DashboardHeaderState, topMargin: CGFloat = 0) -> some View {
        modifier(DashboardScrollModifier(header: header, topMargin: topMargin))
    }

    func tronDashboardInitialOffset() -> some View {
        modifier(DashboardInitialOffset())
    }
}
