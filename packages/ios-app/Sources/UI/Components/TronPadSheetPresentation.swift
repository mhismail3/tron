import SwiftUI
import UIKit

enum TronPadSheetMode: Equatable, Sendable {
    case sideColumn
    case centeredCard

    static let sideColumnMinimumWidth: CGFloat = 1100
    static let sideColumnWidth: CGFloat = 420
    static let sideColumnTrailingMargin: CGFloat = 25
    static let sideColumnReflowInset: CGFloat = sideColumnWidth + sideColumnTrailingMargin + panelGap
    static let panelGap: CGFloat = 12
    static let panelCornerRadius: CGFloat = 28

    @MainActor
    static func resolve(sceneWidth: CGFloat) -> TronPadSheetMode? {
        guard #available(iOS 27, *), UIDevice.current.userInterfaceIdiom == .pad else { return nil }
        return sceneWidth >= sideColumnMinimumWidth ? .sideColumn : .centeredCard
    }

    @MainActor
    static func prepare(_ presented: UIViewController, in window: UIWindow) {
        guard resolve(sceneWidth: window.bounds.width) == .sideColumn else { return }
        presented.preferredContentSize = CGSize(width: sideColumnWidth, height: window.bounds.height)
    }
}

@MainActor @Observable
final class TronPadSheetScene {
    fileprivate(set) var width: CGFloat = 0

    var mode: TronPadSheetMode? { width > 0 ? TronPadSheetMode.resolve(sceneWidth: width) : nil }
}

extension EnvironmentValues {
    @Entry var tronPadSheetScene: TronPadSheetScene?
}

struct TronPadSheetPresented: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

struct TronPadSheetSceneMode: ViewModifier {
    #if HOSTED_TEST
    private static let widthOverride: CGFloat? = {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-tron-scene-width-override"), arguments.indices.contains(index + 1) else { return nil }
        return Double(arguments[index + 1]).map { CGFloat($0) }
    }()
    #else
    private static let widthOverride: CGFloat? = nil
    #endif

    @State private var scene = TronPadSheetScene()

    func body(content: Content) -> some View {
        content
            .environment(\.tronPadSheetScene, scene)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { scene.width = Self.widthOverride ?? $0 }
    }
}

private struct TronPadSheetPresentationModifier: ViewModifier {
    @Environment(\.tronPadSheetScene) private var scene

    func body(content: Content) -> some View {
        if #available(iOS 27, *), let mode = scene?.mode {
            switch mode {
            case .sideColumn:
                content
                    .presentationDetents([.large])
                    .presentationSizing(.form)
                    .presentationPlacement(.trailing)
                    .presentationBackgroundInteraction(.enabled(upThrough: .large))
            case .centeredCard:
                content
                    .presentationDetents([.large])
                    .presentationSizing(.page)
                    .presentationPlacement(.center)
            }
        } else {
            content
        }
    }
}

extension View {
    func tronPadSheetPresentation() -> some View {
        modifier(TronPadSheetPresentationModifier())
    }
}

struct TronSideColumnPanel: ViewModifier {
    let isOpen: Bool
    let isPanel: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .background {
                if isPanel { Color.clear.accessibilityElement().accessibilityIdentifier("tron-scene-panel").allowsHitTesting(false) }
            }
            .mask { RoundedRectangle(cornerRadius: isOpen ? TronPadSheetMode.panelCornerRadius : 0, style: .continuous).ignoresSafeArea() }
            .padding(.trailing, isOpen ? TronPadSheetMode.sideColumnReflowInset : 0)
            .background(isOpen ? Color(uiColor: .systemGroupedBackground) : .clear)
            .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 1), value: isOpen)
            .keyframeAnimator(initialValue: 1.0, trigger: isOpen) { view, opacity in
                view.opacity(reduceMotion ? opacity : 1)
            } keyframes: { _ in
                CubicKeyframe(0.55, duration: 0.12)
                CubicKeyframe(1, duration: 0.18)
            }
    }
}
