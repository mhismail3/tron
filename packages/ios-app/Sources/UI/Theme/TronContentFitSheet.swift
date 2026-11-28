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

    private var fitHeight: CGFloat? {
        guard !opensLarge, padScene?.mode == nil, !dynamicTypeSize.isAccessibilitySize else { return nil }
        guard let content = loading ? settled : measured else { return nil }
        let height = content.rounded(.up)
        return height < TronSheetStage.maximumHeight ? height : nil
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
                update {
                    loading = next
                    if next, settled == nil { opensLarge = true }
                }
            }
            .background { TronSheetTargetReporter(target: fitHeight.map { .fit($0) } ?? .large, dismiss: dismiss) }
            .modifier(TronSheetCover())
    }
}

private struct TronSheetCover: ViewModifier {
    func body(content: Content) -> some View {
        if TronSheetStage.isEnabled {
            content.presentationCompactAdaptation(.fullScreenCover).presentationBackground(.clear)
        } else {
            content.presentationDragIndicator(.hidden)
        }
    }
}

private struct TronSheetTargetReporter: UIViewControllerRepresentable {
    let target: TronSheetTarget
    let dismiss: DismissAction

    final class Controller: UIViewController {
        var target = TronSheetTarget.large
        var dismiss: DismissAction?

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
        controller.report()
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
                .contentMargins(.bottom, fits ? 0 : TronSheetStage.bottomSafeArea)
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
