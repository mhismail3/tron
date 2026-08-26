import SwiftUI
import UIKit

/// The single scene-level notice surface. A dedicated non-key window keeps
/// cards in app coordinates while sheets animate independently underneath it.
struct InAppNoticeHost: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showLogs = false
    @State private var toolbarCenterY: CGFloat?

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                InAppNoticeStack(notices: model.visibleNotices, reduceMotion: reduceMotion)
                    .frame(width: proxy.size.width)
                    .position(
                        x: proxy.size.width / 2,
                        y: toolbarCenterY ?? proxy.safeAreaInsets.top + InAppNoticeLayout.fallbackToolbarHalfHeight
                    )
                NoticeToolbarAlignmentReader { centerY in
                    guard toolbarCenterY.map({ abs($0 - centerY) > 0.5 }) ?? true else { return }
                    toolbarCenterY = centerY
                }
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
            }
        }
        .ignoresSafeArea()
        .onAppear { consumeLogsIfOwner() }
        .onChange(of: model.logsPresentationRequested) { _, _ in consumeLogsIfOwner() }
        .sheet(isPresented: $showLogs) {
            NavigationStack {
                GatewayLogsSettingsView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showLogs = false }
                        }
                    }
            }
        }
    }

    private func consumeLogsIfOwner() {
        guard model.logsPresentationRequested else { return }
        model.consumeLogsPresentationRequest()
        showLogs = true
    }
}

private enum InAppNoticeLayout {
    // Leaves enough room for the shell's leading/trailing toolbar controls.
    static let horizontalControlReservation: CGFloat = 80
    static let fallbackToolbarHalfHeight: CGFloat = 22
}

enum InAppNoticeSwipePolicy {
    static let dismissalDistance: CGFloat = 36
    static let horizontalDominance: CGFloat = 1.15

    static func shouldDismiss(translation: CGSize, predicted: CGSize) -> Bool {
        let horizontal = max(abs(translation.width), abs(predicted.width))
        let vertical = max(abs(translation.height), abs(predicted.height))
        return horizontal >= dismissalDistance
            && horizontal > vertical * horizontalDominance
    }
}

private enum NoticeOverlayCoordinateSpace {
    static let name = "tron-notice-overlay"
}

@MainActor
private final class NoticeOverlayInteractionRegistry {
    private var frames: [UUID: CGRect] = [:]

    func setFrame(_ frame: CGRect, for noticeID: UUID) {
        frames[noticeID] = frame
    }

    func removeFrame(for noticeID: UUID) {
        frames[noticeID] = nil
    }

    func contains(_ point: CGPoint, noticeID: UUID?) -> Bool {
        guard let noticeID, let frame = frames[noticeID] else { return false }
        return frame.contains(point)
    }
}

private struct NoticeOverlayInteractionRegistryKey: EnvironmentKey {
    static let defaultValue: NoticeOverlayInteractionRegistry? = nil
}

private extension EnvironmentValues {
    var noticeOverlayInteractionRegistry: NoticeOverlayInteractionRegistry? {
        get { self[NoticeOverlayInteractionRegistryKey.self] }
        set { self[NoticeOverlayInteractionRegistryKey.self] = newValue }
    }
}

private struct InAppNoticeStack: View {
    let notices: [InAppNoticeCenter.Notice]
    let reduceMotion: Bool

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            ZStack(alignment: .top) {
                ForEach(Array(notices.enumerated()), id: \.element.id) { index, notice in
                    InAppNoticeCard(notice: notice, index: index, reduceMotion: reduceMotion)
                        .scaleEffect(index == 0 ? 1 : 1 - CGFloat(index) * 0.035, anchor: .top)
                        .offset(y: CGFloat(index) * 9)
                        .opacity(index == 0 ? 1 : max(0.45, 0.78 - CGFloat(index) * 0.12))
                        .zIndex(Double(notices.count - index))
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, InAppNoticeLayout.horizontalControlReservation)
        .animation(reduceMotion ? nil : .smooth(duration: 0.24), value: notices)
    }
}

private struct InAppNoticeCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.noticeOverlayInteractionRegistry) private var interactionRegistry
    let notice: InAppNoticeCenter.Notice
    let index: Int
    let reduceMotion: Bool
    @State private var dragX: CGFloat = 0
    @GestureState private var interactionActive = false

    private var accent: Color {
        switch notice.role {
        case .error: .tronError
        case .warning: .tronAmber
        case .success, .progress: .tronEmerald
        case .info: .tronCyan
        }
    }
    private var symbol: String {
        switch notice.role {
        case .error: "exclamationmark.triangle.fill"
        case .warning: "exclamationmark.circle.fill"
        case .success: "checkmark.circle.fill"
        case .progress: "arrow.triangle.2.circlepath"
        case .info: "info.circle.fill"
        }
    }
    private var isCompactPill: Bool {
        notice.message == nil && notice.actions.isEmpty
    }
    private var cornerRadius: CGFloat {
        isCompactPill ? 1_000 : 18
    }
    private var contentAlignment: VerticalAlignment {
        isCompactPill ? .center : .top
    }

    var body: some View {
        HStack(alignment: contentAlignment, spacing: 9) {
            Image(systemName: symbol).foregroundStyle(accent).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(notice.title)
                    .font(TronTypography.bodySM.weight(.semibold))
                    .foregroundStyle(Color.tronTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if let message = notice.message {
                    Text(message)
                        .font(TronTypography.caption)
                        .foregroundStyle(Color.tronTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !notice.actions.isEmpty {
                    Group {
                        if dynamicTypeSize.isAccessibilitySize {
                            actionButtons(.vertical)
                        } else {
                            ViewThatFits(in: .horizontal) {
                                actionButtons(.horizontal)
                                actionButtons(.vertical)
                            }
                        }
                    }
                    .padding(.top, 3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
        .frame(maxWidth: 420, minHeight: 44, alignment: .leading)
        .background(
            Color.tronSurfaceElevated.opacity(index == 0 ? 0.88 : 0.76),
            in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        )
        .glassEffect(
            .regular.tint(accent.opacity(index == 0 ? 0.26 : 0.16)),
            in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        )
        .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .offset(x: dragX)
        .simultaneousGesture(index == 0 ? swipeGesture : nil)
        .allowsHitTesting(index == 0)
        .accessibilityHidden(index != 0)
        .accessibilityElement(children: notice.actions.isEmpty ? .combine : .contain)
        .accessibilityIdentifier("in-app-notice-card")
        .accessibilityLabel([notice.title, notice.message].compactMap { $0 }.joined(separator: ". "))
        .accessibilityAddTraits(notice.actions.isEmpty ? .isStaticText : [])
        .accessibilityAction(named: "Dismiss notification") { model.noticeCenter.dismiss(notice.id) }
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .named(NoticeOverlayCoordinateSpace.name))
        } action: { frame in
            interactionRegistry?.setFrame(frame, for: notice.id)
        }
        .onAppear { announceIfNeeded() }
        .onDisappear {
            interactionRegistry?.removeFrame(for: notice.id)
            model.noticeCenter.setInteraction(notice.id, active: false)
        }
        .onChange(of: interactionActive) { _, active in
            model.noticeCenter.setInteraction(notice.id, active: active)
        }
        .onChange(of: index) { _, _ in announceIfNeeded() }
        .onChange(of: notice) { _, _ in
            dragX = 0
            announceIfNeeded()
        }
        .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
    }

    @ViewBuilder
    private func actionButtons(_ axis: Axis) -> some View {
        let layout = axis == .horizontal ? AnyLayout(HStackLayout(spacing: 10)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
        layout {
            ForEach(notice.actions) { action in
                Button(action.title) { model.noticeCenter.performAction(action, for: notice.id) }
                    .font(TronTypography.caption.weight(.semibold))
                    .foregroundStyle(action.role == .destructive ? Color.tronError : accent)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
        }
    }

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .updating($interactionActive) { _, active, _ in active = true }
            .onChanged { value in
                guard abs(value.translation.width) > abs(value.translation.height) else {
                    dragX = 0
                    return
                }
                dragX = value.translation.width
            }
            .onEnded { value in
                if InAppNoticeSwipePolicy.shouldDismiss(
                    translation: value.translation,
                    predicted: value.predictedEndTranslation
                ) {
                    model.noticeCenter.dismiss(notice.id)
                } else if reduceMotion {
                    dragX = 0
                } else {
                    withAnimation(.smooth(duration: 0.18)) { dragX = 0 }
                }
            }
    }

    private func announceIfNeeded() {
        guard index == 0, model.noticeCenter.markForegroundAnnounced(notice.id) else { return }
        AccessibilityNotification.Announcement(
            [notice.title, notice.message].compactMap { $0 }.joined(separator: ". ")
        ).post()
    }
}

private struct NoticeToolbarAlignmentReader: UIViewRepresentable {
    let onChange: @MainActor (CGFloat) -> Void

    func makeUIView(context: Context) -> ProbeView {
        ProbeView(onChange: onChange)
    }

    func updateUIView(_ view: ProbeView, context: Context) {
        view.onChange = onChange
        view.refresh()
    }

    @MainActor
    final class ProbeView: UIView {
        var onChange: @MainActor (CGFloat) -> Void
        private var lastCenterY: CGFloat?

        init(onChange: @escaping @MainActor (CGFloat) -> Void) {
            self.onChange = onChange
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            backgroundColor = .clear
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            refresh()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            refresh()
        }

        func refresh() {
            guard let overlayWindow = window, let scene = overlayWindow.windowScene else { return }
            let centerY = Self.toolbarCenter(in: scene, excluding: overlayWindow)
                ?? overlayWindow.safeAreaInsets.top + InAppNoticeLayout.fallbackToolbarHalfHeight
            guard lastCenterY.map({ abs($0 - centerY) > 0.5 }) ?? true else { return }
            lastCenterY = centerY
            onChange(centerY)
        }

        private static func toolbarCenter(in scene: UIWindowScene, excluding overlayWindow: UIWindow) -> CGFloat? {
            let windows = scene.windows
                .filter { $0 !== overlayWindow && !$0.isHidden && $0.alpha > 0.01 }
                .sorted { $0.windowLevel.rawValue > $1.windowLevel.rawValue }
            for sourceWindow in windows {
                let centers = navigationBars(in: sourceWindow)
                    .filter { !$0.isHidden && $0.alpha > 0.01 && $0.window === sourceWindow }
                    .map { bar -> CGFloat in
                        let frame = bar.convert(bar.bounds, to: sourceWindow)
                        return sourceWindow.convert(frame, to: overlayWindow).midY
                    }
                if let center = centers.max() { return center }
            }
            return nil
        }

        private static func navigationBars(in view: UIView) -> [UINavigationBar] {
            var result: [UINavigationBar] = []
            if let bar = view as? UINavigationBar { result.append(bar) }
            for child in view.subviews where !child.isHidden && child.alpha > 0.01 {
                result.append(contentsOf: navigationBars(in: child))
            }
            return result
        }
    }
}

struct InAppNoticeWindowInstaller: UIViewRepresentable {
    let model: AppModel
    let colorScheme: ColorScheme?

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model, colorScheme: colorScheme)
    }

    func makeUIView(context: Context) -> NoticeWindowAnchorView {
        let view = NoticeWindowAnchorView()
        view.coordinator = context.coordinator
        return view
    }

    func updateUIView(_ view: NoticeWindowAnchorView, context: Context) {
        context.coordinator.update(model: model, colorScheme: colorScheme)
        context.coordinator.attach(to: view.window?.windowScene)
    }

    static func dismantleUIView(_ view: NoticeWindowAnchorView, coordinator: Coordinator) {
        coordinator.detach()
        view.coordinator = nil
    }

    @MainActor
    final class Coordinator {
        private var model: AppModel
        private var colorScheme: ColorScheme?
        private var scene: UIWindowScene?
        private var overlayWindow: NoticeOverlayWindow?
        private let interactionRegistry = NoticeOverlayInteractionRegistry()
        private let hostingController: UIHostingController<AnyView>

        init(model: AppModel, colorScheme: ColorScheme?) {
            self.model = model
            self.colorScheme = colorScheme
            hostingController = UIHostingController(rootView: AnyView(EmptyView()))
            hostingController.view.backgroundColor = .clear
            updateRootView()
        }

        func update(model: AppModel, colorScheme: ColorScheme?) {
            self.model = model
            self.colorScheme = colorScheme
            updateRootView()
        }

        func attach(to scene: UIWindowScene?) {
            guard let scene else {
                detach()
                return
            }
            guard self.scene !== scene || overlayWindow == nil else { return }
            detach()
            self.scene = scene

            let window = NoticeOverlayWindow(windowScene: scene)
            window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.normal.rawValue + 2)
            window.backgroundColor = .clear
            window.rootViewController = hostingController
            window.model = model
            window.interactionRegistry = interactionRegistry
            window.isHidden = false
            overlayWindow = window
        }

        func detach() {
            overlayWindow?.isHidden = true
            overlayWindow?.rootViewController = nil
            overlayWindow = nil
            scene = nil
        }

        private func updateRootView() {
            hostingController.rootView = AnyView(
                InAppNoticeHost()
                .coordinateSpace(name: NoticeOverlayCoordinateSpace.name)
                .environment(model)
                .environment(\.noticeOverlayInteractionRegistry, interactionRegistry)
                .tronPresentation()
                .preferredColorScheme(colorScheme)
            )
            overlayWindow?.model = model
        }
    }
}

@MainActor
final class NoticeWindowAnchorView: UIView {
    weak var coordinator: InAppNoticeWindowInstaller.Coordinator?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        coordinator?.attach(to: window?.windowScene)
    }
}

@MainActor
private final class NoticeOverlayWindow: UIWindow {
    weak var model: AppModel?
    var interactionRegistry: NoticeOverlayInteractionRegistry?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if rootViewController?.presentedViewController != nil {
            return super.hitTest(point, with: event)
        }
        guard interactionRegistry?.contains(
            point,
            noticeID: model?.noticeCenter.foremostNoticeID
        ) == true else { return nil }
        return super.hitTest(point, with: event)
    }
}
