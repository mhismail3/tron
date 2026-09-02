import SwiftUI

enum DisplayFloatingLayoutPolicy {
    static let panelCornerRadius: CGFloat = 22
    static let panelEdgeInset: CGFloat = 8
    static let controlDiameter: CGFloat = 32
    static let controlTouchTarget: CGFloat = 44

    static func panelSize(in container: CGSize) -> CGSize {
        let availableWidth = max(0, container.width - panelEdgeInset * 2)
        let preferredWidth = max(240, container.width * 0.78)
        let width = min(420, min(availableWidth, preferredWidth))
        let height = min(320, max(200, min(container.height * 0.32, width * 0.68)))
        return CGSize(width: width, height: height)
    }

    static func safeCenterRect(
        container: CGSize,
        safeTop: CGFloat,
        safeBottom: CGFloat,
        bottomExclusion: CGFloat,
        panelSize: CGSize
    ) -> CGRect {
        let minX = panelSize.width / 2 + panelEdgeInset
        let maxX = max(minX, container.width - panelSize.width / 2 - panelEdgeInset)
        let minY = safeTop + panelSize.height / 2 + panelEdgeInset
        let requestedMaxY = container.height
            - safeBottom
            - max(0, bottomExclusion)
            - panelSize.height / 2
            - panelEdgeInset
        let maxY = max(minY, requestedMaxY)
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    static func clamped(_ point: CGPoint, to rect: CGRect) -> CGPoint {
        CGPoint(
            x: min(max(point.x, rect.minX), rect.maxX),
            y: min(max(point.y, rect.minY), rect.maxY)
        )
    }

    static func snappedToNearestHorizontalEdge(_ point: CGPoint, in rect: CGRect) -> CGPoint {
        let clamped = clamped(point, to: rect)
        let x = abs(clamped.x - rect.minX) <= abs(rect.maxX - clamped.x)
            ? rect.minX
            : rect.maxX
        return CGPoint(x: x, y: clamped.y)
    }
}

struct ChatFloatingDisplayHost: View {
    @Binding var route: DisplayRoute?
    let bottomExclusion: CGFloat
    let onOpenSheet: (DisplayRoute) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var center: CGPoint?
    @State private var dragOrigin: CGPoint?

    var body: some View {
        GeometryReader { geometry in
            if let route {
                let size = DisplayFloatingLayoutPolicy.panelSize(in: geometry.size)
                let safeRect = DisplayFloatingLayoutPolicy.safeCenterRect(
                    container: geometry.size,
                    safeTop: geometry.safeAreaInsets.top,
                    safeBottom: geometry.safeAreaInsets.bottom,
                    bottomExclusion: bottomExclusion,
                    panelSize: size
                )
                floatingPanel(route: route, size: size, safeRect: safeRect)
                    .frame(width: size.width, height: size.height)
                    .position(DisplayFloatingLayoutPolicy.clamped(
                        center ?? defaultCenter(in: safeRect),
                        to: safeRect
                    ))
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.96).combined(with: .opacity))
                    .onAppear {
                        center = DisplayFloatingLayoutPolicy.clamped(
                            center ?? defaultCenter(in: safeRect),
                            to: safeRect
                        )
                    }
                    .onChange(of: geometry.size) { _, _ in clampCenter(to: safeRect) }
                    .onChange(of: bottomExclusion) { _, _ in clampCenter(to: safeRect) }
                    .onChange(of: route.id) { _, _ in
                        center = defaultCenter(in: safeRect)
                        dragOrigin = nil
                    }
            }
        }
        .animation(reduceMotion ? .linear(duration: 0.10) : .smooth(duration: 0.22), value: route?.id)
        .accessibilityHidden(route == nil)
    }

    private func floatingPanel(route: DisplayRoute, size: CGSize, safeRect: CGRect) -> some View {
        ZStack(alignment: .top) {
            DisplayArtifactContent(
                sessionID: route.sessionID,
                display: route.display,
                context: .floating
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()

            HStack(spacing: 4) {
                dragHandle(route: route, safeRect: safeRect)
                Spacer(minLength: 8)
                GlassEffectContainer(spacing: 4) {
                    HStack(spacing: 4) {
                        floatingControl(
                            systemImage: "arrow.up.left.and.arrow.down.right",
                            accessibilityLabel: "Open \(route.display.title) in sheet"
                        ) { onOpenSheet(route) }
                        floatingControl(
                            systemImage: "xmark",
                            accessibilityLabel: "Close \(route.display.title) window"
                        ) { self.route = nil }
                    }
                }
            }
            .padding(8)
        }
        .clipShape(RoundedRectangle(
            cornerRadius: DisplayFloatingLayoutPolicy.panelCornerRadius,
            style: .continuous
        ))
        .glassEffect(
            .regular.tint(Color.tronLavender.opacity(0.06)),
            in: RoundedRectangle(
                cornerRadius: DisplayFloatingLayoutPolicy.panelCornerRadius,
                style: .continuous
            )
        )
        .overlay {
            RoundedRectangle(
                cornerRadius: DisplayFloatingLayoutPolicy.panelCornerRadius,
                style: .continuous
            )
            .stroke(Color.white.opacity(0.18), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.20), radius: 18, y: 8)
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Move to top left") { move(.topLeading, in: safeRect) }
        .accessibilityAction(named: "Move to top right") { move(.topTrailing, in: safeRect) }
        .accessibilityAction(named: "Move to bottom left") { move(.bottomLeading, in: safeRect) }
        .accessibilityAction(named: "Move to bottom right") { move(.bottomTrailing, in: safeRect) }
    }

    private func dragHandle(route: DisplayRoute, safeRect: CGRect) -> some View {
        Image(systemName: "line.3.horizontal")
            .font(TronTypography.sans(size: 14, weight: .semibold))
            .foregroundStyle(Color.tronTextPrimary)
            .frame(
                width: DisplayFloatingLayoutPolicy.controlDiameter,
                height: DisplayFloatingLayoutPolicy.controlDiameter
            )
            .glassEffect(.regular.interactive(), in: .circle)
            .frame(
                width: DisplayFloatingLayoutPolicy.controlTouchTarget,
                height: DisplayFloatingLayoutPolicy.controlTouchTarget
            )
            .contentShape(Circle())
            .gesture(dragGesture(in: safeRect))
            .accessibilityElement()
            .accessibilityLabel("Move \(route.display.title) window")
            .accessibilityHint("Drag to move; the window snaps to the nearest side")
    }

    private func floatingControl(
        systemImage: String,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(TronTypography.sans(size: 14, weight: .semibold))
                .foregroundStyle(Color.tronTextPrimary)
                .frame(
                    width: DisplayFloatingLayoutPolicy.controlDiameter,
                    height: DisplayFloatingLayoutPolicy.controlDiameter
                )
                .glassEffect(.regular.interactive(), in: .circle)
                .frame(
                    width: DisplayFloatingLayoutPolicy.controlTouchTarget,
                    height: DisplayFloatingLayoutPolicy.controlTouchTarget
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }

    private func dragGesture(in safeRect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { value in
                if dragOrigin == nil {
                    dragOrigin = center ?? defaultCenter(in: safeRect)
                }
                guard let dragOrigin else { return }
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    center = DisplayFloatingLayoutPolicy.clamped(
                        CGPoint(
                            x: dragOrigin.x + value.translation.width,
                            y: dragOrigin.y + value.translation.height
                        ),
                        to: safeRect
                    )
                }
            }
            .onEnded { value in
                guard let dragOrigin else { return }
                let projected = CGPoint(
                    x: dragOrigin.x + value.predictedEndTranslation.width,
                    y: dragOrigin.y + value.predictedEndTranslation.height
                )
                let destination = DisplayFloatingLayoutPolicy.snappedToNearestHorizontalEdge(
                    projected,
                    in: safeRect
                )
                self.dragOrigin = nil
                if reduceMotion {
                    center = destination
                } else {
                    withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
                        center = destination
                    }
                }
            }
    }

    private enum Corner { case topLeading, topTrailing, bottomLeading, bottomTrailing }

    private func move(_ corner: Corner, in safeRect: CGRect) {
        let destination = switch corner {
        case .topLeading: CGPoint(x: safeRect.minX, y: safeRect.minY)
        case .topTrailing: CGPoint(x: safeRect.maxX, y: safeRect.minY)
        case .bottomLeading: CGPoint(x: safeRect.minX, y: safeRect.maxY)
        case .bottomTrailing: CGPoint(x: safeRect.maxX, y: safeRect.maxY)
        }
        if reduceMotion {
            center = destination
        } else {
            withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
                center = destination
            }
        }
    }

    private func clampCenter(to safeRect: CGRect) {
        center = DisplayFloatingLayoutPolicy.clamped(
            center ?? defaultCenter(in: safeRect),
            to: safeRect
        )
    }

    private func defaultCenter(in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.maxX, y: rect.minY)
    }
}
