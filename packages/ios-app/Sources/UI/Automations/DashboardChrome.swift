import SwiftUI

@MainActor @Observable
final class DashboardHeaderState {
    static let blurFadeDistance: CGFloat = 80
    static let stretchDistance: CGFloat = 120
    static let initialDrop: CGFloat = 25
    static let titleSize: CGFloat = 34
    static let inlineTitleSize: CGFloat = 22
    private(set) var offset: CGFloat = 0
    private(set) var windowControls: CGSize = .zero

    var isInline: Bool { windowControls.height > 0 }

    private(set) var safeTop: CGFloat = 0

    func update(windowControls: CGSize, safeTop: CGFloat) {
        if windowControls != self.windowControls { self.windowControls = windowControls }
        if safeTop != self.safeTop { self.safeTop = safeTop }
    }

    var progress: CGFloat { max(0, offset / Self.blurFadeDistance) }

    static func boundedOffset(_ offset: CGFloat) -> CGFloat {
        guard offset.isFinite else { return offset }
        return min(blurFadeDistance, max(-stretchDistance, offset))
    }

    func verticalOffset(reduceMotion: Bool) -> CGFloat {
        reduceMotion || isInline ? 0 : Self.initialDrop * (1 - Self.ease(progress))
    }

    func titleScale(reduceMotion: Bool) -> CGFloat {
        guard !reduceMotion, !isInline else { return 1 }
        let pull = max(0, -offset / Self.stretchDistance)
        return 1 - (2 / Self.titleSize) * Self.ease(progress) + 0.06 * Self.ease(pull)
    }

    private static func ease(_ value: CGFloat) -> CGFloat {
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

struct DashboardChrome<Content: View>: View {
    let header: DashboardHeaderState
    let onOpenAutomations: @MainActor () -> Void
    let onOpenApps: @MainActor () -> Void
    let actions: DashboardMenuActions
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
            DashboardTitleRow(state: header)
        }
        .onGeometryChange(for: DashboardWindowCorner.self) { geometry in
            var controls = geometry.containerCornerInsets.topLeading
            #if HOSTED_TEST
            if let fixture = DashboardWindowCorner.fixtureControls { controls = fixture }
            #endif
            return DashboardWindowCorner(controls: controls, safeTop: geometry.safeAreaInsets.top)
        } action: { corner in
            header.update(windowControls: corner.controls, safeTop: corner.safeTop)
        }
    }
}

struct DashboardWindowCorner: Equatable {
    var controls: CGSize
    var safeTop: CGFloat

    #if HOSTED_TEST
    static let fixtureControls: CGSize? = {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-tron-window-controls-inset"), arguments.indices.contains(index + 1) else { return nil }
        let parts = arguments[index + 1].split(separator: ",").compactMap { Double($0) }
        return parts.count == 2 ? CGSize(width: parts[0], height: parts[1]) : nil
    }()
    #endif
}

private struct DashboardTitleRow: View {
    let state: DashboardHeaderState

    var body: some View {
        if state.isInline {
            let controls = state.windowControls
            Color.clear
                .frame(height: max(controls.height - state.safeTop, 0))
                .overlay(alignment: .topLeading) {
                    DashboardTitle(state: state)
                        .frame(height: controls.height, alignment: .leading)
                        .padding(.leading, controls.width + 8)
                        .offset(y: -state.safeTop)
                }
        } else {
            DashboardTitle(state: state)
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
            .font(TronTypography.sans(size: state.isInline ? DashboardHeaderState.inlineTitleSize : DashboardHeaderState.titleSize, weight: .bold))
            .foregroundStyle(Color.tronPrimary)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
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
            .contentMargins(.top, topMargin + (reduceMotion || header.isInline ? 0 : DashboardHeaderState.initialDrop), for: .scrollContent)
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
        content.offset(y: reduceMotion ? 0 : DashboardHeaderState.initialDrop)
    }
}

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
    func tronDashboardFloatingCircle(accent: Color) -> some View {
        frame(width: 56, height: 56)
            .contentShape(Circle())
            .glassEffect(.regular.tint(accent.opacity(0.22)).interactive(), in: .circle)
    }

    func tronDashboardScroll(_ header: DashboardHeaderState, topMargin: CGFloat = 0) -> some View {
        modifier(DashboardScrollModifier(header: header, topMargin: topMargin))
    }

    func tronDashboardInitialOffset() -> some View {
        modifier(DashboardInitialOffset())
    }
}
