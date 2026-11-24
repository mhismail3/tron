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
        guard padScene?.mode == nil, !keyboard, !dynamicTypeSize.isAccessibilitySize else { return nil }
        let window = TronSheetWindowMetrics.current
        guard let content = loading ? settled : measured else { return nil }
        let height = (content - window.bottomInset).rounded(.up)
        return height < window.maximumDetent ? height : nil
    }

    private var target: TronSheetDetentDriver.Target {
        if let fitHeight { return .fit(fitHeight) }
        let opensMedium = loading && settled == nil && padScene?.mode == nil && !keyboard && !dynamicTypeSize.isAccessibilitySize
        return opensMedium ? .medium : .large
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
            .background { TronSheetDetentDriver(target: target, animated: appeared && !reduceMotion) }
            .presentationDragIndicator(.hidden)
    }
}

private struct TronSheetDetentDriver: UIViewControllerRepresentable {
    enum Target: Equatable { case fit(CGFloat), medium, large }
    let target: Target
    let animated: Bool

    final class Controller: UIViewController {
        var target = Target.large
        var animated = false
        private var applied: Target?

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            apply()
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            apply()
        }

        func apply() {
            var root: UIViewController = self
            while let parent = root.parent { root = parent }
            guard !root.isBeingDismissed, root.presentedViewController == nil, let sheet = root.sheetPresentationController else { return }
            let detent: UISheetPresentationController.Detent = switch target {
            case .fit(let height): .custom(identifier: .init("tron.content-fit")) { _ in height }
            case .medium: .medium()
            case .large: .large()
            }
            guard applied != target || sheet.detents.map(\.identifier) != [detent.identifier] else { return }
            let first = applied == nil
            applied = target
            let change = {
                sheet.detents = [detent]
                sheet.selectedDetentIdentifier = detent.identifier
            }
            if animated, !first, !root.isBeingPresented { sheet.animateChanges(change) } else { change() }
        }
    }

    func makeUIViewController(context: Context) -> Controller {
        let controller = Controller()
        controller.view.isUserInteractionEnabled = false
        controller.view.isHidden = true
        return controller
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.target = target
        controller.animated = animated
        controller.apply()
        DispatchQueue.main.async { controller.apply() }
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

