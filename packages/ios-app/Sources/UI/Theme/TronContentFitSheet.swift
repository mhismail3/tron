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
    @Entry var tronSheetFloor: CGFloat = 0
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
    @Environment(\.tronSheetFloor) private var floor

    private var fitHeight: CGFloat? {
        guard padScene?.mode == nil, !keyboard, !dynamicTypeSize.isAccessibilitySize else { return nil }
        let window = TronSheetWindowMetrics.current
        guard let content = loading ? settled : measured else { return floor > 0 && floor < window.maximumDetent ? floor : nil }
        let height = max((content - window.bottomInset).rounded(.up), floor)
        return height < window.maximumDetent ? height : nil
    }

    private var detent: PresentationDetent {
        if let fitHeight { return .height(fitHeight) }
        return loading && settled == nil && floor == 0 && padScene?.mode == nil && !keyboard && !dynamicTypeSize.isAccessibilitySize ? .medium : .large
    }

    private func update(_ change: () -> Void) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction, change)
    }

    func body(content: Content) -> some View {
        content
            .environment(\.tronSheetFitsContent, !loading && fitHeight != nil)
            .environment(\.tronSheetMeasuresContent, true)
            .environment(\.tronSheetFloor, fitHeight ?? .infinity)
            .onPreferenceChange(TronSheetFitKey.self) { next in
                guard next.map({ abs($0 - (measured ?? -1)) >= 0.5 }) ?? (measured != nil) else { return }
                update {
                    measured = next
                    if !loading { settled = next }
                }
            }
            .transformPreference(TronSheetFitKey.self) { $0 = nil }
            .onPreferenceChange(TronSheetLoadingPreferenceKey.self) { request in
                let next = request != nil
                guard next != loading else { return }
                update { loading = next }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                update { keyboard = true }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                update { keyboard = false }
            }
            .onAppear { appeared = true }
            .background { TronSheetDetentDriver(height: fitHeight, medium: detent == .medium, animated: appeared && !reduceMotion) }
            .presentationDragIndicator(.hidden)
    }


}

private struct TronSheetDetentDriver: UIViewControllerRepresentable {
    let height: CGFloat?
    let medium: Bool
    let animated: Bool

    final class Controller: UIViewController {
        var applied: String?
    }

    func makeUIViewController(context: Context) -> Controller {
        let controller = Controller()
        controller.view.isUserInteractionEnabled = false
        controller.view.isHidden = true
        return controller
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        apply(to: controller)
        DispatchQueue.main.async { apply(to: controller) }
    }

    private func apply(to controller: Controller) {
        var root: UIViewController = controller
        while let parent = root.parent { root = parent }
        guard !root.isBeingDismissed, let sheet = root.sheetPresentationController else { return }
        let key = height.map { "fit:\($0)" } ?? (medium ? "medium" : "large")
        let identifier: UISheetPresentationController.Detent.Identifier = height == nil ? (medium ? .medium : .large) : .init("tron.content-fit")
        guard controller.applied != key || sheet.detents.map(\.identifier) != [identifier] else { return }
        let first = controller.applied == nil
        controller.applied = key
        let detent: UISheetPresentationController.Detent = height.map { value in
            .custom(identifier: identifier) { _ in value }
        } ?? (medium ? .medium() : .large())
        let change = {
            sheet.detents = [detent]
            sheet.selectedDetentIdentifier = detent.identifier
        }
        if animated, !first { sheet.animateChanges(change) } else { change() }
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
                .preference(key: TronSheetFitKey.self, value: needed)
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
