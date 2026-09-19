import SwiftUI

/// Only the backdrop observes scroll progress. Keeping this reference out of
/// catalogue inputs avoids re-filtering or rebuilding rows on every frame.
@MainActor @Observable
final class DashboardHeaderState {
    static let blurFadeDistance: CGFloat = 80
    private(set) var progress: CGFloat = 0

    func update(offset: CGFloat) {
        guard offset.isFinite else { return }
        let next = min(1, max(0, offset / Self.blurFadeDistance))
        if next != progress { progress = next }
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
            DashboardTitle(mode: mode, isRefreshing: isRefreshing)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .padding(.horizontal, 20)
        }
    }
}

struct DashboardTitle: View {
    let mode: DashboardMode
    var isRefreshing = false

    var body: some View {
        HStack(spacing: 10) {
            Text(mode.title)
                .font(TronTypography.sans(size: 34, weight: .bold))
                .foregroundStyle(mode.accent)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                // A real, fixed-size heading avoids toolbar button semantics.
                // Long names fit narrow/accessibility layouts, never scroll-scale.
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("dashboard.title")
            if isRefreshing {
                TronPulseLoadingIndicator(accent: mode.accent, size: 14)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Refreshing upcoming Automations")
                    .transition(.opacity)
            }
        }
    }
}

private struct DashboardBackdrop: View {
    let state: DashboardHeaderState

    var body: some View {
        TronTopBlurOverlay(style: .dashboard)
            .opacity(state.progress)
    }
}

extension View {
    /// Attach to the concrete List/ScrollView, not a parent containing several
    /// scroll owners. Normalize the resting offset by its real safe-area inset.
    func tronDashboardScroll(_ header: DashboardHeaderState) -> some View {
        onScrollGeometryChange(for: CGFloat.self) { geometry in
            min(DashboardHeaderState.blurFadeDistance, max(0, geometry.contentOffset.y + geometry.contentInsets.top))
        } action: { _, offset in
            header.update(offset: offset)
        }
    }
}
