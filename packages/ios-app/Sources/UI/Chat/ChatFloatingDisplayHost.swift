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

    static func panelSize(
        in container: CGSize,
        live: Bool = false,
        liveAspectRatio: CGFloat? = nil
    ) -> CGSize {
        let availableWidth = max(0, container.width - panelEdgeInset * 2)
        let availableHeight = max(0, container.height - panelEdgeInset * 2)
        let preferredWidth = max(240, container.width * 0.78)
        let width = min(420, min(availableWidth, preferredWidth))
        guard live else {
            let preferredHeight = min(320, max(200, min(container.height * 0.32, width * 0.68)))
            return CGSize(width: width, height: min(preferredHeight, availableHeight))
        }

        // Both live producers use the same 4:3 pre-frame fallback.
        // Once a renderable frame is admitted, fit its pixels to the native
        // proposal. Controls still own a minimum panel, so extreme ratios
        // letterbox rather than shrinking the 44-point hit targets.
        let ratio = liveAspectRatio.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? (4.0 / 3.0)
        let fittedWidth = min(width, availableHeight * ratio)
        let fittedHeight = min(availableHeight, width / ratio)
        // Control minima bound the panel, not the image. Do not expand a wide
        // image to full container width merely to make room for its controls.
        return CGSize(width: max(min(minimumUsableWidth, availableWidth), fittedWidth),
                      height: max(min(minimumUsableHeight, availableHeight), fittedHeight))
    }

    static func matchesLiveSource(_ source: LiveFrameSource, route: DisplayRoute,
                                         profileID: String?, surface: PresentationSurfaceToken?) -> Bool {
        guard route.display.kind.isLive, let liveView = route.display.liveView else { return false }
        return source.sessionID == route.sessionID && source.presentationIdentity == route.display.presentationIdentity
            && source.viewID == liveView.viewId && source.generation == liveView.generation
            && source.profileID == profileID && source.surface == surface
    }

    static func acceptsLiveGeometry(
        _ update: LiveFrameUpdate,
        route: DisplayRoute,
        profileID: String?,
        surface: PresentationSurfaceToken?,
        allowsPublication: Bool,
        previousSource: LiveFrameSource?
    ) -> Bool {
        let source = update.source
        guard matchesLiveSource(source, route: route, profileID: profileID, surface: surface) else { return false }
        if let geometry = update.geometry {
            guard geometry.aspectRatio != nil, allowsPublication else { return false }
        } // A nil update retires geometry; it never admits pixels.
        if let previousSource,
           previousSource.sessionID == source.sessionID,
           previousSource.profileID == source.profileID,
           previousSource.presentationIdentity == source.presentationIdentity,
           previousSource.surface == source.surface,
           previousSource.producerID == source.producerID,
           source.activityGeneration < previousSource.activityGeneration {
            return false
        }
        return true
    }

    // Native proposals already exclude toolbar, keyboard and composer.
    // Subtracting GeometryProxy.safeAreaInsets here would count them twice.
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

    static func draggedCenter(globalLocation: CGPoint, grabPoint: CGPoint,
                              container: CGRect, panelSize: CGSize, in rect: CGRect) -> CGPoint {
        clamped(CGPoint(x: globalLocation.x - container.minX + panelSize.width / 2 - grabPoint.x,
                        y: globalLocation.y - container.minY + panelSize.height / 2 - grabPoint.y), to: rect)
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
                FloatingDisplayWindow(route: route, container: geometry.frame(in: .global), onOpenSheet: {
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
    let container: CGRect
    let onOpenSheet: () -> Void
    let onClose: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.tronPresentationActivityCoordinator) private var activityCoordinator
    @Environment(\.tronPresentationSurfaceToken) private var surfaceToken
    @Environment(AppModel.self) private var model
    @State private var anchor: UnitPoint = .topTrailing
    private struct Drag {
        // The glass handle keeps its native size; its grab offset must not
        // scale with the image's changing aspect ratio.
        let grabPoint: CGPoint
        var globalLocation: CGPoint
    }
    @State private var drag: Drag?
    @State private var liveFrameUpdate: LiveFrameUpdate?

    var body: some View {
        let currentLiveAspectRatio: CGFloat? = {
            guard let update = liveFrameUpdate, let geometry = update.geometry,
                  DisplayFloatingLayoutPolicy.matchesLiveSource(update.source, route: route,
                      profileID: model.selectedGatewayProfileID(), surface: surfaceToken) else { return nil }
            return geometry.aspectRatio
        }()
        let size = DisplayFloatingLayoutPolicy.panelSize(
            in: container.size,
            live: route.display.kind.isLive,
            liveAspectRatio: currentLiveAspectRatio
        )
        let safeRect = DisplayFloatingLayoutPolicy.safeCenterRect(container: container.size, panelSize: size)
        // Held gestures render from the actual touch, not a delayed geometry
        // repair. This also covers a moving/resizing native container.
        let center = drag.map {
            DisplayFloatingLayoutPolicy.draggedCenter(globalLocation: $0.globalLocation, grabPoint: $0.grabPoint,
                                                       container: container, panelSize: size, in: safeRect)
        } ?? DisplayFloatingLayoutPolicy.center(for: anchor, in: safeRect)
        // An impossibly small region retains route and placement, not a hidden
        // capture lease or controls painted over the composer.
        if size.width >= DisplayFloatingLayoutPolicy.minimumUsableWidth,
           size.height >= DisplayFloatingLayoutPolicy.minimumUsableHeight {
            floatingPanel(size: size, safeRect: safeRect)
                .frame(width: size.width, height: size.height)
                .onDisappear { _ = retireDrag(size: size, safeRect: safeRect) }
                #if HOSTED_TEST
                .background(FloatingDisplayHostedProbe(move: { move($0) }, pan: {
                    handlePan($0, size: size, safeRect: safeRect)
                }))
                #endif
                .coordinateSpace(name: FloatingWindowPanGesture.Space.window)
                .position(center)
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
                DisplayArtifactContent(
                    sessionID: route.sessionID,
                    display: route.display,
                    context: .floating,
                    onLiveFrameGeometry: receiveLiveFrameGeometry
                )
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

    private func receiveLiveFrameGeometry(_ update: LiveFrameUpdate) {
        let allowsPublication = update.source.surface.map {
            activityCoordinator?.activity(for: $0).allowsPresentationPublication == true
        } ?? false
        guard DisplayFloatingLayoutPolicy.acceptsLiveGeometry(
            update, route: route, profileID: model.selectedGatewayProfileID(), surface: surfaceToken,
            allowsPublication: allowsPublication, previousSource: liveFrameUpdate?.source
        ) else { return }
        if liveFrameUpdate != update { liveFrameUpdate = update }
    }

    private func retireDrag(size: CGSize, safeRect: CGRect) -> CGPoint? {
        guard let drag else { return nil }
        let current = DisplayFloatingLayoutPolicy.draggedCenter(
            globalLocation: drag.globalLocation, grabPoint: drag.grabPoint,
            container: container, panelSize: size, in: safeRect)
        var transaction = Transaction(animation: .linear(duration: 0))
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            anchor = DisplayFloatingLayoutPolicy.anchor(for: current, in: safeRect, retaining: anchor)
            self.drag = nil
        }
        return current
    }

    private func handlePan(_ sample: FloatingWindowPanGesture.Sample, size: CGSize, safeRect: CGRect) {
        switch sample.state {
        case .began, .changed:
            // The first grab publication must itself cancel the old dock; an
            // equal second assignment can be elided before its transaction runs.
            guard let grabPoint = sample.state == .began ? sample.locationInWindow : drag?.grabPoint else { return }
            let next = Drag(grabPoint: grabPoint,
                            globalLocation: CGPoint(x: sample.location.x + container.minX,
                                                    y: sample.location.y + container.minY))
            var transaction = Transaction(animation: .linear(duration: 0))
            transaction.disablesAnimations = true
            withTransaction(transaction) { drag = next }
        case .ended, .cancelled, .failed:
            guard let current = retireDrag(size: size, safeRect: safeRect) else { return }
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
