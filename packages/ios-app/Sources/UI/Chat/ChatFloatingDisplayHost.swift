import SwiftUI

enum DisplayFloatingLayoutPolicy {
    static let panelCornerRadius: CGFloat = 22
    static let panelEdgeInset: CGFloat = 8
    static let controlDiameter: CGFloat = 32
    static let controlTouchTarget: CGFloat = 44
    static let minimumUsableHeight = controlTouchTarget + 16
    static let minimumUsableWidth = controlTouchTarget * 3 + 36
    // A short, bounded release projection gives a flick direction without an
    // independent deceleration simulation or a second animation clock.
    static let releaseProjectionDuration: CGFloat = 0.15

    static func panelSize(in container: CGSize, browserLive: Bool = false) -> CGSize {
        let availableWidth = max(0, container.width - panelEdgeInset * 2)
        let availableHeight = max(0, container.height - panelEdgeInset * 2)
        let preferredWidth = max(240, container.width * 0.78)
        let width = min(420, min(availableWidth, preferredWidth))
        if browserLive {
            let height = min(width * 3 / 4, availableHeight)
            // Preserve the glass controls at their native touch sizes. In very
            // short regions the 4:3 image letterboxes inside the fitted window;
            // neither the image nor the controls are stretched or scaled down.
            return CGSize(width: max(min(minimumUsableWidth, availableWidth), height * 4 / 3), height: height)
        }
        let preferredHeight = min(320, max(200, min(container.height * 0.32, width * 0.68)))
        return CGSize(width: width, height: min(preferredHeight, availableHeight))
    }

    // The native proposal already excludes toolbar, keyboard and composer.
    // GeometryProxy.safeAreaInsets still describes those ancestor obstructions;
    // subtracting it here counts them twice.
    static func safeCenterRect(container: CGSize, panelSize: CGSize) -> CGRect {
        let minX = panelSize.width / 2 + panelEdgeInset
        let minY = panelSize.height / 2 + panelEdgeInset
        return CGRect(
            x: minX, y: minY,
            width: max(0, container.width - panelSize.width - panelEdgeInset * 2),
            height: max(0, container.height - panelSize.height - panelEdgeInset * 2)
        )
    }

    static func clamped(_ point: CGPoint, to rect: CGRect) -> CGPoint {
        CGPoint(x: min(max(point.x, rect.minX), rect.maxX), y: min(max(point.y, rect.minY), rect.maxY))
    }

    static func center(for anchor: UnitPoint, in rect: CGRect) -> CGPoint {
        clamped(CGPoint(x: rect.minX + rect.width * anchor.x, y: rect.minY + rect.height * anchor.y), to: rect)
    }

    static func anchor(for point: CGPoint, in rect: CGRect, retaining previous: UnitPoint) -> UnitPoint {
        let point = clamped(point, to: rect)
        // A squeezed axis has no placement information. Retain the preference
        // so a bottom-docked window returns with the composer when space grows.
        return UnitPoint(x: rect.width > 0 ? (point.x - rect.minX) / rect.width : previous.x,
                         y: rect.height > 0 ? (point.y - rect.minY) / rect.height : previous.y)
    }

    static func snappedToNearestHorizontalEdge(_ point: CGPoint, in rect: CGRect) -> CGPoint {
        let clamped = clamped(point, to: rect)
        let x = abs(clamped.x - rect.minX) <= abs(rect.maxX - clamped.x) ? rect.minX : rect.maxX
        return CGPoint(x: x, y: clamped.y)
    }
}

struct ChatFloatingDisplayHost: View {
    @Binding var route: DisplayRoute?
    let onOpenSheet: (DisplayRoute) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            if let route {
                FloatingDisplayWindow(route: route, container: geometry.size, onOpenSheet: {
                    if self.route?.id == route.id { onOpenSheet(route) }
                }, onClose: {
                    if self.route?.id == route.id { self.route = nil }
                })
                // Placement and gestures belong to this exact window, not a
                // successor selected while the outgoing window is retiring.
                .id(route.id)
            }
        }
        .coordinateSpace(name: FloatingWindowPanGesture.Space.bounds)
        .animation(reduceMotion ? .linear(duration: 0.10) : .smooth(duration: 0.22), value: route?.id)
        .accessibilityHidden(route == nil)
    }
}

private struct FloatingDisplayWindow: View {
    let route: DisplayRoute
    let container: CGSize
    let onOpenSheet: () -> Void
    let onClose: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.tronPresentationActivityCoordinator) private var activityCoordinator
    @Environment(\.tronPresentationSurfaceToken) private var surfaceToken
    @State private var anchor: UnitPoint = .topTrailing
    @State private var grabPoint: UnitPoint?

    var body: some View {
        let size = DisplayFloatingLayoutPolicy.panelSize(in: container, browserLive: route.display.kind == .browserLive)
        let safeRect = DisplayFloatingLayoutPolicy.safeCenterRect(container: container, panelSize: size)
        // An impossibly small region retains route and placement, not a hidden
        // capture lease or controls painted over the composer.
        if size.width >= DisplayFloatingLayoutPolicy.minimumUsableWidth,
           size.height >= DisplayFloatingLayoutPolicy.minimumUsableHeight {
            floatingPanel(size: size, safeRect: safeRect)
                .frame(width: size.width, height: size.height)
                #if HOSTED_TEST
                .background(FloatingDisplayHostedProbe(move: { move($0) }, pan: {
                    handlePan($0, size: size, safeRect: safeRect)
                }))
                #endif
                .coordinateSpace(name: FloatingWindowPanGesture.Space.window)
                .position(DisplayFloatingLayoutPolicy.center(for: anchor, in: safeRect))
                .transition(reduceMotion ? .opacity : .scale(scale: 0.96).combined(with: .opacity))
        }
        // Layout follows the existing native/structural clock, not a second
        // animation on geometry samples. Only insertion and docking own local
        // animation; neither changes the renderer's identity.
    }

    private func floatingPanel(size: CGSize, safeRect: CGRect) -> some View {
        ZStack(alignment: .top) {
            if activityCoordinator?.hasMountedDescendant(id: route.sheetPresentationID, of: surfaceToken) == true {
                Image(systemName: "rectangle.on.rectangle")
                    .font(TronTypography.sans(size: 28, weight: .medium))
                    .foregroundStyle(Color.tronTextSecondary)
                    #if HOSTED_TEST
                    .background(ChatHostedNativeRowProbe(physicalID: "floating-popped-out", semanticID: "floating-popped-out", identity: UUID()))
                    #endif
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel("Opened in sheet")
            } else {
                DisplayArtifactContent(sessionID: route.sessionID, display: route.display, context: .floating)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            }

            HStack(spacing: 4) {
                controlImage("line.3.horizontal")
                    .gesture(FloatingWindowPanGesture { handlePan($0, size: size, safeRect: safeRect) })
                    .accessibilityElement()
                    .accessibilityLabel("Move \(route.display.title) window")
                    .accessibilityHint("Drag to move; the window snaps to the nearest side")
                Spacer(minLength: 8)
                GlassEffectContainer(spacing: 4) {
                    HStack(spacing: 4) {
                        floatingControl(systemImage: "arrow.up.left.and.arrow.down.right",
                                        accessibilityLabel: "Open \(route.display.title) in sheet", action: onOpenSheet)
                        floatingControl(systemImage: "xmark",
                                        accessibilityLabel: "Close \(route.display.title) window", action: onClose)
                    }
                }
            }
            .padding(8)
        }
        .clipShape(RoundedRectangle(cornerRadius: DisplayFloatingLayoutPolicy.panelCornerRadius, style: .continuous))
        .glassEffect(.regular.tint(Color.tronLavender.opacity(0.06)),
                     in: RoundedRectangle(cornerRadius: DisplayFloatingLayoutPolicy.panelCornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DisplayFloatingLayoutPolicy.panelCornerRadius, style: .continuous)
                .stroke(Color.white.opacity(0.18), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.20), radius: 18, y: 8)
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Move to top left") { move(.topLeading) }
        .accessibilityAction(named: "Move to top right") { move(.topTrailing) }
        .accessibilityAction(named: "Move to bottom left") { move(.bottomLeading) }
        .accessibilityAction(named: "Move to bottom right") { move(.bottomTrailing) }
    }

    private func controlImage(_ systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(TronTypography.sans(size: 14, weight: .semibold))
            .foregroundStyle(Color.tronTextPrimary)
            .frame(width: DisplayFloatingLayoutPolicy.controlDiameter, height: DisplayFloatingLayoutPolicy.controlDiameter)
            .glassEffect(.regular.interactive(), in: .circle)
            .frame(width: DisplayFloatingLayoutPolicy.controlTouchTarget, height: DisplayFloatingLayoutPolicy.controlTouchTarget)
            .contentShape(Circle())
    }

    private func floatingControl(systemImage: String, accessibilityLabel: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { controlImage(systemImage) }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibilityLabel)
    }

    private func handlePan(_ sample: FloatingWindowPanGesture.Sample, size: CGSize, safeRect: CGRect) {
        switch sample.state {
        case .began:
            // Use the actual touched window, including an interrupted docking
            // animation. Its model anchor may already describe the destination.
            grabPoint = UnitPoint(x: sample.locationInWindow.x / size.width,
                                  y: sample.locationInWindow.y / size.height)
            fallthrough
        case .changed:
            guard let grabPoint else { return }
            let center = CGPoint(x: sample.location.x + (0.5 - grabPoint.x) * size.width,
                                 y: sample.location.y + (0.5 - grabPoint.y) * size.height)
            // Replace any in-flight dock immediately. A nil animation only
            // suppresses new interpolation; it can leave the old dock running.
            var transaction = Transaction(animation: .linear(duration: 0))
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                anchor = DisplayFloatingLayoutPolicy.anchor(for: center, in: safeRect, retaining: anchor)
            }
        case .ended, .cancelled, .failed:
            guard grabPoint != nil else { return }
            grabPoint = nil
            let current = DisplayFloatingLayoutPolicy.center(for: anchor, in: safeRect)
            let duration = sample.state == .ended && !reduceMotion
                ? DisplayFloatingLayoutPolicy.releaseProjectionDuration : 0
            let projected = CGPoint(x: current.x + sample.velocity.x * duration,
                                    y: current.y + sample.velocity.y * duration)
            let destination = DisplayFloatingLayoutPolicy.snappedToNearestHorizontalEdge(projected, in: safeRect)
            // Only one visible position changes. Clearing grab metadata cannot
            // expose the pre-drag anchor or inject a separate reset transaction.
            move(DisplayFloatingLayoutPolicy.anchor(for: destination, in: safeRect, retaining: anchor))
        default:
            break
        }
    }

    private func move(_ destination: UnitPoint) {
        if reduceMotion { anchor = destination }
        else { withAnimation(.smooth(duration: 0.28)) { anchor = destination } }
    }
}
