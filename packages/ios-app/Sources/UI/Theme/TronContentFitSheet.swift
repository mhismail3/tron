import SwiftUI
import UIKit

private struct TronSheetFit: Equatable {
    let needed: CGFloat
    let container: CGFloat
}

private struct TronSheetFitKey: PreferenceKey {
    static let defaultValue: TronSheetFit? = nil
    static func reduce(value: inout TronSheetFit?, nextValue: () -> TronSheetFit?) {
        if let next = nextValue() { value = next }
    }
}

extension EnvironmentValues {
    @Entry var tronSheetFitsContent = false
    @Entry var tronSurfaceConcentricBottom = false
}

private struct TronContentFitSheetModifier: ViewModifier {
    @State private var height: CGFloat?
    @State private var largeHeight: CGFloat?
    @State private var keyboard = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var forcesLarge: Bool { keyboard || dynamicTypeSize.isAccessibilitySize }

    func body(content: Content) -> some View {
        content
            .environment(\.tronSheetFitsContent, height != nil && !forcesLarge)
            .onPreferenceChange(TronSheetFitKey.self) { fit in
                if let fit { resize(fit) }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                keyboard = true
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                keyboard = false
            }
            .presentationDetents([forcesLarge ? .large : height.map { .height($0) } ?? .large])
    }

    private func resize(_ fit: TronSheetFit) {
        if height == nil, fit.container > 0 { largeHeight = max(largeHeight ?? 0, fit.container) }
        guard let largeHeight else { return }
        let target = fit.needed > largeHeight ? nil : fit.needed.rounded(.up)
        if let target, let height, abs(target - height) < 1 { return }
        guard target != height else { return }
        withAnimation(.snappy(duration: 0.28)) { height = target }
    }
}

private struct TronSheetFitScrollModifier: ViewModifier {
    @State private var fit: TronSheetFit?
    @Environment(\.tronSheetFitsContent) private var fits

    func body(content: Content) -> some View {
        content
            .scrollDisabled(fits)
            .onScrollGeometryChange(for: TronSheetFit.self) { geometry in
                TronSheetFit(needed: geometry.contentInsets.top + geometry.contentSize.height - geometry.contentInsets.bottom,
                             container: geometry.containerSize.height)
            } action: { _, next in
                fit = next
            }
            .preference(key: TronSheetFitKey.self, value: fit)
    }
}

private struct TronSheetBottomContainerModifier: ViewModifier {
    let active: Bool
    @Environment(\.tronSheetFitsContent) private var fits

    func body(content: Content) -> some View {
        content.environment(\.tronSurfaceConcentricBottom, fits && active)
    }
}

enum TronSurfaceShape {
    static func resolve(cornerRadius: CGFloat, concentricBottom: Bool) -> AnyShape {
        guard concentricBottom else { return AnyShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)) }
        return AnyShape(ConcentricRectangle(
            uniformTopCorners: .fixed(cornerRadius),
            uniformBottomCorners: .concentric(minimum: .fixed(cornerRadius))
        ))
    }
}

extension View {
    func tronContentFitSheet() -> some View {
        modifier(TronContentFitSheetModifier())
    }

    func tronSheetFitScroll() -> some View {
        modifier(TronSheetFitScrollModifier())
    }

    func tronSheetBottomContainer(_ active: Bool = true) -> some View {
        modifier(TronSheetBottomContainerModifier(active: active))
    }
}
