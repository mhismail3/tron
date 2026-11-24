import SwiftUI
import UIKit

private struct TronSheetFit: Equatable {
    let needed: CGFloat
    let bottom: CGFloat
}

private struct TronSheetFitKey: PreferenceKey {
    static let defaultValue: TronSheetFit? = nil
    static func reduce(value: inout TronSheetFit?, nextValue: () -> TronSheetFit?) {
        if let next = nextValue() { value = next }
    }
}

extension EnvironmentValues {
    @Entry var tronSheetFitsContent = false
    @Entry var tronSheetMeasuresContent = false
}

private struct TronContentFitSheetModifier: ViewModifier {
    @State private var measured: CGFloat?
    @State private var settled: CGFloat?
    @State private var loading = false
    @State private var keyboard = false
    @State private var appeared = false
    @State private var sheetBottom: CGFloat?
    @State private var scrollBottom: CGFloat?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.tronPadSheetScene) private var padScene

    private var fitHeight: CGFloat? {
        guard padScene?.mode == nil, !keyboard, !dynamicTypeSize.isAccessibilitySize, let content = loading ? settled : measured else { return nil }
        let window = TronSheetWindowMetrics.current
        let stopsAtSafeArea = sheetBottom.flatMap { sheet in scrollBottom.map { sheet - $0 > window.bottomInset / 2 } } ?? false
        let height = (stopsAtSafeArea ? content : content - window.bottomInset).rounded(.up)
        return height < window.maximumDetent ? height : nil
    }

    private var detent: PresentationDetent {
        if let fitHeight { return .height(fitHeight) }
        return loading && settled == nil && padScene?.mode == nil && !keyboard && !dynamicTypeSize.isAccessibilitySize ? .medium : .large
    }

    func body(content: Content) -> some View {
        content
            .environment(\.tronSheetFitsContent, !loading && fitHeight != nil)
            .environment(\.tronSheetMeasuresContent, true)
            .onPreferenceChange(TronSheetFitKey.self) { next in
                if let bottom = next?.bottom, abs(bottom - (scrollBottom ?? -1)) >= 0.5 { scrollBottom = bottom }
                guard next.map({ abs($0.needed - (measured ?? -1)) >= 0.5 }) ?? (measured != nil) else { return }
                resize {
                    measured = next?.needed
                    if !loading { settled = next?.needed }
                }
            }
            .onPreferenceChange(TronSheetLoadingPreferenceKey.self) { request in
                let next = request != nil
                guard next != loading else { return }
                resize { loading = next }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                resize { keyboard = true }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                resize { keyboard = false }
            }
            .onAppear { appeared = true }
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY + $0.safeAreaInsets.bottom } action: { next in
                if abs(next - (sheetBottom ?? -1)) >= 0.5 { sheetBottom = next }
            }
            .presentationDetents([detent])
            .presentationDragIndicator(.hidden)
    }

    private func resize(_ change: () -> Void) {
        guard appeared, !reduceMotion else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction, change)
            return
        }
        withAnimation(.smooth(duration: 0.35), change)
    }
}

private struct TronSheetWindowMetrics {
    let bottomInset: CGFloat
    let maximumDetent: CGFloat

    @MainActor static var current: TronSheetWindowMetrics {
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first else {
            return TronSheetWindowMetrics(bottomInset: 0, maximumDetent: .infinity)
        }
        let insets = window.safeAreaInsets
        return TronSheetWindowMetrics(bottomInset: insets.bottom,
                                      maximumDetent: window.bounds.height - insets.top - insets.bottom)
    }
}

struct TronSheetFitScrollModifier: ViewModifier {
    @State private var needed: CGFloat?
    @State private var bottom: CGFloat?
    @Environment(\.tronSheetMeasuresContent) private var measures
    @Environment(\.tronSheetFitsContent) private var fits

    func body(content: Content) -> some View {
        if measures {
            content
                .environment(\.tronSheetMeasuresContent, false)
                .ignoresSafeArea(.container, edges: .bottom)
                .contentMargins(.bottom, fits ? 0 : TronSheetWindowMetrics.current.bottomInset)
                .scrollBounceBehavior(.basedOnSize, axes: .vertical)
                .onScrollGeometryChange(for: CGFloat?.self) { geometry in
                    let insets = geometry.contentInsets
                    return insets.top > 0 || insets.bottom > 0 ? insets.top + geometry.contentSize.height : nil
                } action: { _, next in
                    if let next { needed = next }
                }
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: { bottom = $0 }
                .preference(key: TronSheetFitKey.self, value: needed.flatMap { needed in
                    bottom.map { TronSheetFit(needed: needed, bottom: $0) }
                })
        } else {
            content
        }
    }
}

enum TronSurfaceShape {
    static func resolve(cornerRadius: CGFloat, inFittedSheet: Bool) -> AnyShape {
        guard inFittedSheet else { return AnyShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)) }
        return AnyShape(ConcentricRectangle(uniformTopCorners: .fixed(cornerRadius),
                                            uniformBottomCorners: .concentric(minimum: .fixed(cornerRadius))))
    }
}

extension View {
    func tronContentFitSheet() -> some View {
        modifier(TronContentFitSheetModifier())
    }
}
