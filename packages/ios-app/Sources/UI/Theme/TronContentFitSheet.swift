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
    @State private var opensLarge = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.tronPadSheetScene) private var padScene
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var keyboard: CGFloat = 0
    @State private var appeared = false

    private var settledContent: CGFloat? {
        guard !opensLarge, padScene?.mode == nil, !dynamicTypeSize.isAccessibilitySize else { return nil }
        return loading ? settled : measured
    }

    private var fitHeight: CGFloat? {
        guard TronSheetStage.isEnabled, let content = settledContent else { return nil }
        let height = content.rounded(.up)
        return height < TronSheetStage.maximumHeight ? height : nil
    }

    private var nativeTarget: TronSheetDetentDriver.Target {
        let window = TronSheetWindowMetrics.current
        guard !TronSheetStage.isEnabled, let content = settledContent else { return .large }
        let height = (content - window.bottomInset + keyboard).rounded(.up)
        return height < window.maximumDetent ? .fit(height) : .large
    }

    private var fits: Bool {
        TronSheetStage.isEnabled ? fitHeight != nil : nativeTarget != .large
    }

    private func update(_ change: () -> Void) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction, change)
    }

    func body(content: Content) -> some View {
        content
            .environment(\.tronSheetFitsContent, !loading && fits)
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
                update {
                    loading = next
                    if next, settled == nil { opensLarge = true }
                }
            }
            .background { TronSheetTargetReporter(target: fitHeight.map { .fit($0) } ?? .large, dismiss: dismiss,
                                                   style: colorScheme == .dark ? .dark : .light) }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { note in
                guard !TronSheetStage.isEnabled else { return }
                let frame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue ?? .zero
                update { keyboard = TronSheetWindowMetrics.keyboardLift(frame) }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                guard !TronSheetStage.isEnabled else { return }
                update { keyboard = 0 }
            }
            .onAppear { appeared = true }
            .modifier(TronSheetCover(nativeTarget: nativeTarget, animated: appeared && !reduceMotion))
    }
}

private struct TronSheetCover: ViewModifier {
    let nativeTarget: TronSheetDetentDriver.Target
    let animated: Bool

    func body(content: Content) -> some View {
        if TronSheetStage.isEnabled {
            content.presentationCompactAdaptation(.fullScreenCover).presentationBackground(.clear)
        } else {
            content
                .background { TronSheetDetentDriver(target: nativeTarget, animated: animated) }
                .presentationDragIndicator(.hidden)
        }
    }
}

private struct TronSheetTargetReporter: UIViewControllerRepresentable {
    let target: TronSheetTarget
    let dismiss: DismissAction
    let style: UIUserInterfaceStyle

    final class Controller: UIViewController {
        var target = TronSheetTarget.large
        var dismiss: DismissAction?
        var style = UIUserInterfaceStyle.unspecified

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            report()
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            report()
        }

        func report() {
            var root: UIViewController = self
            while let parent = root.parent { root = parent }
            guard root.presentingViewController != nil, let sheet = TronSheetStage.stage(of: root) else { return }
            sheet.dismissAction = dismiss
            sheet.appearance(style)
            sheet.presentationDidEnd()
            sheet.contentTarget(target)
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
        controller.dismiss = dismiss
        controller.style = style
        controller.report()
    }
}

private struct TronSheetDetentDriver: UIViewControllerRepresentable {
    enum Target: Equatable { case fit(CGFloat), large }
    let target: Target
    let animated: Bool

    final class Controller: UIViewController {
        var target = Target.large
        var animated = false
        private var applied: Target?
        private static let appliedByRoot = NSMapTable<UIViewController, Box>.weakToStrongObjects()
        private final class Box { let target: Target; init(_ target: Target) { self.target = target } }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            apply()
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            apply()
        }

        private func floored(_ target: Target, under presenter: Target?) -> Target {
            switch (target, presenter) {
            case (.fit(let height), .fit(let floor)): .fit(max(height, floor))
            case (.fit, .large): .large
            default: target
            }
        }

        func apply() {
            var root: UIViewController = self
            while let parent = root.parent { root = parent }
            guard !root.isBeingDismissed, root.presentedViewController == nil, let sheet = root.sheetPresentationController else { return }
            let target = floored(target, under: root.presentingViewController.flatMap { Self.appliedByRoot.object(forKey: $0)?.target })
            Self.appliedByRoot.setObject(Box(target), forKey: root)
            let detent: UISheetPresentationController.Detent = switch target {
            case .fit(let height): .custom(identifier: .init("tron.content-fit")) { _ in height }
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

    @MainActor static func keyboardLift(_ screenFrame: CGRect) -> CGFloat {
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first else { return 0 }
        let frame = window.convert(screenFrame, from: window.screen.coordinateSpace)
        let bottom = window.bounds.maxY
        guard frame.maxY >= bottom - 0.5 else { return 0 }
        return max(bottom - frame.minY - window.safeAreaInsets.bottom, 0)
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
                .scrollClipDisabled(fits)
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

    func tronSheetFitReports(_ reports: Bool) -> some View {
        transformPreference(TronSheetFitKey.self) { if !reports { $0 = nil } }
    }
}
