import SwiftUI
import UIKit

private struct TronSheetFitKey: PreferenceKey {
    static let defaultValue: CGFloat? = nil
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        if let next = nextValue() { value = next }
    }
}

extension EnvironmentValues {
    @Entry var tronSheetFitsContent = false
    @Entry var tronSheetMeasuresContent = false
    @Entry var tronSurfaceConcentricBottom = false
}

private struct TronContentFitSheetModifier: ViewModifier {
    @State private var measured: CGFloat?
    @State private var settled: CGFloat?
    @State private var loading = false
    @State private var keyboard = false
    @State private var appeared = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.tronPadSheetScene) private var padScene

    private var fitHeight: CGFloat? {
        guard padScene?.mode == nil, !keyboard, !dynamicTypeSize.isAccessibilitySize, let content = loading ? settled : measured else { return nil }
        let window = TronSheetWindowMetrics.current
        let height = (content - window.bottomInset).rounded(.up)
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
                guard next.map({ abs($0 - (measured ?? -1)) >= 0.5 }) ?? (measured != nil) else { return }
                resize {
                    measured = next
                    if !loading { settled = next }
                }
            }
            .onPreferenceChange(TronSheetLoadingPreferenceKey.self) { request in
                let next = request != nil
                guard next != loading else { return }
                resize {
                    loading = next
                    if !next { settled = measured }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                resize { keyboard = true }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                resize { keyboard = false }
            }
            .onAppear { appeared = true }
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
    @State private var height: CGFloat?
    @Environment(\.tronSheetMeasuresContent) private var measures

    func body(content: Content) -> some View {
        if measures {
            content
                .environment(\.tronSheetMeasuresContent, false)
                .scrollBounceBehavior(.basedOnSize, axes: .vertical)
                .onScrollGeometryChange(for: CGFloat?.self) { geometry in
                    let insets = geometry.contentInsets
                    return insets.top > 0 || insets.bottom > 0 ? insets.top + geometry.contentSize.height : nil
                } action: { _, next in
                    if let next { height = next }
                }
                .preference(key: TronSheetFitKey.self, value: height)
        } else {
            content
        }
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

    func tronSheetBottomContainer(_ active: Bool = true) -> some View {
        modifier(TronSheetBottomContainerModifier(active: active))
    }
}
