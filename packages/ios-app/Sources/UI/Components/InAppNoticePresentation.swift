import SwiftUI
import UIKit

/// The single scene-level notice surface. A dedicated non-key window keeps
/// cards in app coordinates while sheets animate independently underneath it.
struct InAppNoticeHost: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var toolbarCenterY: CGFloat?

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                InAppNoticeStack(notices: model.noticeCenter.notices, reduceMotion: reduceMotion)
                    .frame(width: proxy.size.width)
                    // Anchor by the top so multiline cards grow downward,
                    // rather than moving their first line into the status area.
                    .offset(y: InAppNoticeLayout.topEdge(
                        safeAreaTop: proxy.safeAreaInsets.top,
                        toolbarCenterY: toolbarCenterY,
                        accessibilitySize: dynamicTypeSize.isAccessibilitySize
                    ))
                NoticeToolbarAlignmentReader { centerY in
                    guard toolbarCenterY.map({ abs($0 - centerY) > 0.5 }) ?? true else { return }
                    toolbarCenterY = centerY
                }
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
            }
        }
        .ignoresSafeArea()
    }
}

enum InAppNoticeLayout {
    static let cornerRadius: CGFloat = 24
    // Leaves enough room for the shell's leading/trailing toolbar controls.
    static let horizontalControlReservation: CGFloat = 80
    static let fallbackToolbarHalfHeight: CGFloat = 22
    static let safeAreaSpacing: CGFloat = 8

    /// Uses the compact card height as the toolbar reference. This stays
    /// stable when the foremost card gains body lines.
    static func topEdge(safeAreaTop: CGFloat, toolbarCenterY: CGFloat?, accessibilitySize: Bool = false) -> CGFloat {
        let toolbarAlignedTop = (toolbarCenterY ?? safeAreaTop + fallbackToolbarHalfHeight)
            - fallbackToolbarHalfHeight
        // Larger type uses the available width below, rather than between,
        // toolbar controls so ordinary words need not wrap mid-word.
        return max(safeAreaTop + safeAreaSpacing, toolbarAlignedTop)
            + (accessibilitySize ? fallbackToolbarHalfHeight * 2 : 0)
    }
}

enum InAppNoticeSwipePolicy {
    static let dismissalDistance: CGFloat = 36
    static let directionalDominance: CGFloat = 1.15

    static func shouldDismiss(translation: CGSize, predicted: CGSize) -> Bool {
        let horizontal = max(abs(translation.width), abs(predicted.width))
        let upward = max(-translation.height, -predicted.height)
        let vertical = max(abs(translation.height), abs(predicted.height))
        let horizontalSwipe = horizontal >= dismissalDistance
            && horizontal > vertical * directionalDominance
        let upwardSwipe = upward >= dismissalDistance
            && upward > horizontal * directionalDominance
        return horizontalSwipe || upwardSwipe
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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let notices: [InAppNoticeCenter.Notice]
    let reduceMotion: Bool

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            ZStack(alignment: .top) {
                if let notice = notices.first {
                    InAppNoticeCard(notice: notice, reduceMotion: reduceMotion)
                        .id(notice.id)
                        // Let SwiftUI retire the outgoing card visually; the center
                        // still removes its authority and hit target immediately.
                        .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                        .background {
                            // Pending notices are silhouettes, never competing text.
                            // The foreground card owns their geometry, including Dynamic Type.
                            ForEach(0..<min(2, max(0, notices.count - 1)), id: \.self) { index in
                                RoundedRectangle(cornerRadius: InAppNoticeLayout.cornerRadius, style: .continuous)
                                    .fill(Color.tronSurfaceElevated)
                                    .overlay {
                                        RoundedRectangle(cornerRadius: InAppNoticeLayout.cornerRadius, style: .continuous)
                                            .strokeBorder(Color.tronTextSecondary.opacity(0.15))
                                    }
                                    .offset(y: CGFloat(index + 1) * 6)
                                    .zIndex(-Double(index + 1))
                            }
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                        }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, dynamicTypeSize.isAccessibilitySize ? 16 : InAppNoticeLayout.horizontalControlReservation)
        .animation(reduceMotion ? .easeOut(duration: 0.18) : .smooth(duration: 0.24), value: notices)
    }
}

private struct InAppNoticeCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.noticeOverlayInteractionRegistry) private var interactionRegistry
    let notice: InAppNoticeCenter.Notice
    let reduceMotion: Bool
    @State private var dragX: CGFloat = 0
    @State private var dragY: CGFloat = 0

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
    private let cornerRadius = InAppNoticeLayout.cornerRadius

    var body: some View {
        HStack(alignment: .center, spacing: 9) {
            Image(systemName: symbol)
                .font(TronTypography.headline)
                .foregroundStyle(accent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(notice.title)
                    .font(TronTypography.sans(size: TronTypography.sizeBody - 0.5, weight: .semibold))
                    .foregroundStyle(Color.tronTextPrimary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                if let message = notice.message {
                    Text(message)
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM - 0.5))
                        .foregroundStyle(Color.tronTextSecondary)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(maxWidth: 420, minHeight: 44, alignment: .leading)
        .background(
            Color.tronSurfaceElevated.opacity(0.96),
            in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        )
        .glassEffect(
            .regular.tint(accent.opacity(0.26)),
            in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        )
        .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .offset(x: dragX, y: dragY)
        .simultaneousGesture(swipeGesture)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("in-app-notice-card")
        .accessibilityLabel([notice.title, notice.message].compactMap { $0 }.joined(separator: ". "))
        .accessibilityAddTraits(.isStaticText)
        .accessibilityAction(named: "Dismiss notification") { model.noticeCenter.dismiss(notice.id) }
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .named(NoticeOverlayCoordinateSpace.name))
        } action: { frame in
            interactionRegistry?.setFrame(frame, for: notice.id)
        }
        .onAppear { announceIfNeeded() }
        .onDisappear {
            interactionRegistry?.removeFrame(for: notice.id)
        }
        .onChange(of: notice) { _, _ in
            dragX = 0
            dragY = 0
            announceIfNeeded()
        }
    }

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                let horizontal = max(abs(value.translation.width), abs(value.predictedEndTranslation.width))
                let upward = max(-value.translation.height, -value.predictedEndTranslation.height)
                if horizontal > upward * InAppNoticeSwipePolicy.directionalDominance {
                    dragX = value.translation.width
                    dragY = 0
                } else if upward > horizontal * InAppNoticeSwipePolicy.directionalDominance {
                    dragX = 0
                    dragY = min(0, value.translation.height)
                } else {
                    dragX = 0
                    dragY = 0
                }
            }
            .onEnded { value in
                if InAppNoticeSwipePolicy.shouldDismiss(
                    translation: value.translation,
                    predicted: value.predictedEndTranslation
                ) {
                    model.noticeCenter.dismiss(notice.id)
                } else if reduceMotion {
                    dragX = 0
                    dragY = 0
                } else {
                    withAnimation(.smooth(duration: 0.18)) {
                        dragX = 0
                        dragY = 0
                    }
                }
            }
    }

    private func announceIfNeeded() {
        guard model.noticeCenter.markForegroundAnnounced(notice.id) else { return }
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
    let presentationActivity: PresentationActivityCoordinator

    func makeCoordinator() -> Coordinator {
        Coordinator(
            model: model,
            colorScheme: colorScheme,
            presentationActivity: presentationActivity
        )
    }

    func makeUIView(context: Context) -> NoticeWindowAnchorView {
        let view = NoticeWindowAnchorView()
        view.coordinator = context.coordinator
        return view
    }

    func updateUIView(_ view: NoticeWindowAnchorView, context: Context) {
        context.coordinator.update(
            model: model,
            colorScheme: colorScheme,
            presentationActivity: presentationActivity
        )
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
        private var presentationActivity: PresentationActivityCoordinator
        private var scene: UIWindowScene?
        private var overlayWindow: NoticeOverlayWindow?
        private let interactionRegistry = NoticeOverlayInteractionRegistry()
        private let hostingController: UIHostingController<AnyView>

        init(
            model: AppModel,
            colorScheme: ColorScheme?,
            presentationActivity: PresentationActivityCoordinator
        ) {
            self.model = model
            self.colorScheme = colorScheme
            self.presentationActivity = presentationActivity
            hostingController = UIHostingController(rootView: AnyView(EmptyView()))
            hostingController.view.backgroundColor = .clear
            updateRootView()
        }

        func update(
            model: AppModel,
            colorScheme: ColorScheme?,
            presentationActivity: PresentationActivityCoordinator
        ) {
            self.model = model
            self.colorScheme = colorScheme
            self.presentationActivity = presentationActivity
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
                .environment(\.tronPresentationActivityCoordinator, presentationActivity)
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
        guard interactionRegistry?.contains(
            point,
            noticeID: model?.noticeCenter.foremostNoticeID
        ) == true else { return nil }
        return super.hitTest(point, with: event)
    }
}
