import SwiftUI

struct ChatFloatingDisplayHost: View {
    @Binding var route: DisplayRoute?
    let onOpenSheet: (DisplayRoute) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var center: CGPoint?
    @State private var dragOrigin: CGPoint?

    var body: some View {
        GeometryReader { geometry in
            if let route {
                let size = panelSize(in: geometry.size)
                let safeRect = panelSafeRect(in: geometry, panelSize: size)
                floatingPanel(route: route, size: size, safeRect: safeRect)
                    .frame(width: size.width, height: size.height)
                    .position(clamped(center ?? defaultCenter(in: safeRect), to: safeRect))
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.94).combined(with: .opacity))
                    .onAppear { center = clamped(center ?? defaultCenter(in: safeRect), to: safeRect) }
                    .onChange(of: geometry.size) { _, _ in
                        center = clamped(center ?? defaultCenter(in: safeRect), to: safeRect)
                    }
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
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "line.3.horizontal")
                    .foregroundStyle(Color.tronTextSecondary)
                    .accessibilityHidden(true)
                Text(route.display.title)
                    .font(TronTypography.buttonSM)
                    .foregroundStyle(Color.tronTextPrimary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Button {
                    onOpenSheet(route)
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Open \(route.display.title) in sheet")
                Button {
                    self.route = nil
                } label: {
                    Image(systemName: "xmark")
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Close \(route.display.title) window")
            }
            .padding(.leading, 12)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .global)
                .onChanged { value in
                    if dragOrigin == nil { dragOrigin = center ?? value.startLocation }
                    guard let dragOrigin else { return }
                    center = clamped(CGPoint(
                        x: dragOrigin.x + value.translation.width,
                        y: dragOrigin.y + value.translation.height
                    ), to: safeRect)
                }
                .onEnded { _ in dragOrigin = nil })

            Divider()
            DisplayArtifactContent(
                sessionID: route.sessionID,
                display: route.display,
                context: .floating
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.tronBorder.opacity(0.9), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.24), radius: 18, y: 8)
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Move to top left") { move(.topLeading, in: safeRect) }
        .accessibilityAction(named: "Move to top right") { move(.topTrailing, in: safeRect) }
        .accessibilityAction(named: "Move to bottom left") { move(.bottomLeading, in: safeRect) }
        .accessibilityAction(named: "Move to bottom right") { move(.bottomTrailing, in: safeRect) }
    }

    private enum Corner { case topLeading, topTrailing, bottomLeading, bottomTrailing }

    private func move(_ corner: Corner, in safeRect: CGRect) {
        switch corner {
        case .topLeading: center = CGPoint(x: safeRect.minX, y: safeRect.minY)
        case .topTrailing: center = CGPoint(x: safeRect.maxX, y: safeRect.minY)
        case .bottomLeading: center = CGPoint(x: safeRect.minX, y: safeRect.maxY)
        case .bottomTrailing: center = CGPoint(x: safeRect.maxX, y: safeRect.maxY)
        }
    }

    private func panelSize(in container: CGSize) -> CGSize {
        let width = min(420, max(260, container.width - 32))
        let height = min(360, max(220, container.height * 0.38))
        return CGSize(width: width, height: height)
    }

    private func panelSafeRect(in geometry: GeometryProxy, panelSize: CGSize) -> CGRect {
        let insets = geometry.safeAreaInsets
        let horizontal = panelSize.width / 2 + 12
        let top = insets.top + panelSize.height / 2 + 52
        let bottom = geometry.size.height - insets.bottom - panelSize.height / 2 - 108
        return CGRect(
            x: horizontal,
            y: top,
            width: max(0, geometry.size.width - horizontal * 2),
            height: max(0, bottom - top)
        )
    }

    private func defaultCenter(in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.maxX, y: rect.minY)
    }

    private func clamped(_ point: CGPoint, to rect: CGRect) -> CGPoint {
        CGPoint(
            x: min(max(point.x, rect.minX), rect.maxX),
            y: min(max(point.y, rect.minY), rect.maxY)
        )
    }
}
