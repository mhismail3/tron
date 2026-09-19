import SwiftUI

/// Only the title and backdrop observe scroll geometry. Catalogue inputs and
/// row identity never depend on this per-frame presentation state.
@MainActor @Observable
final class DashboardHeaderState {
    static let blurFadeDistance: CGFloat = 80
    static let stretchDistance: CGFloat = 120
    static let initialDrop: CGFloat = 10
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

    // Two base font points of shrink, or at most four percent of pull stretch.
    func titleScale(reduceMotion: Bool) -> CGFloat {
        guard !reduceMotion else { return 1 }
        let pull = max(0, -offset / Self.stretchDistance)
        return 1 - (2 / Self.titleSize) * Self.ease(progress) + 0.04 * Self.ease(pull)
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

/// One visual owner for all root dashboards. Content, searches, and accepted
/// actions remain with their dashboard; this view owns only common chrome.
struct DashboardChrome<Content: View, SearchContent: View>: View {
    let mode: DashboardMode
    let header: DashboardHeaderState
    let onSelect: @MainActor (DashboardMode) -> Void
    let actions: DashboardMenuActions
    let showingSearch: Bool
    let isRefreshing: Bool
    private let content: Content
    private let search: SearchContent

    init(
        mode: DashboardMode,
        header: DashboardHeaderState,
        onSelect: @escaping @MainActor (DashboardMode) -> Void,
        actions: DashboardMenuActions,
        showingSearch: Bool,
        isRefreshing: Bool = false,
        @ViewBuilder content: () -> Content,
        @ViewBuilder search: () -> SearchContent
    ) {
        self.mode = mode
        self.header = header
        self.onSelect = onSelect
        self.actions = actions
        self.showingSearch = showingSearch
        self.isRefreshing = isRefreshing
        self.content = content()
        self.search = search()
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            ZStack(alignment: .bottomTrailing) {
                content
                DashboardBackdrop(state: header)
                DashboardModeMenuButton(mode: mode, onSelect: onSelect, actions: actions)
                    .frame(width: 56, height: 56)
                    .contentShape(Circle())
                    .glassEffect(.regular.tint(mode.accent.opacity(0.22)).interactive(), in: .circle)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
                    .accessibilityHidden(showingSearch)
                    .allowsHitTesting(!showingSearch)
            }
            .ignoresSafeArea(.keyboard, edges: .bottom)

            if showingSearch {
                search.transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.tronBackground)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .safeAreaInset(edge: .top, spacing: 0) {
            DashboardTitle(mode: mode, state: header, isRefreshing: isRefreshing)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .padding(.horizontal, 20)
        }
    }
}

struct DashboardTitle: View {
    let mode: DashboardMode
    let state: DashboardHeaderState
    var isRefreshing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 10) {
            Text(mode.title)
                .font(TronTypography.sans(size: DashboardHeaderState.titleSize, weight: .bold))
                .foregroundStyle(mode.accent)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                // Fit long names before applying the small visual transform;
                // motion never changes the header's measured layout footprint.
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("dashboard.title")
            if isRefreshing {
                TronPulseLoadingIndicator(accent: mode.accent, size: 14)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Refreshing upcoming Automations")
                    .transition(.opacity)
            }
        }
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

extension View {
    /// Attach to the concrete List/ScrollView, not a parent containing several
    /// scroll owners. Normalize the resting offset by its real safe-area inset.
    func tronDashboardScroll(_ header: DashboardHeaderState, topMargin: CGFloat = 0) -> some View {
        modifier(DashboardScrollModifier(header: header, topMargin: topMargin))
    }

    func tronDashboardInitialOffset() -> some View {
        modifier(DashboardInitialOffset())
    }
}
