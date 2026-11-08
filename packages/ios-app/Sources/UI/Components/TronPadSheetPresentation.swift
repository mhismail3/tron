import SwiftUI
import UIKit

/// iPad geometry for every managed sheet. The managed sheet modifiers apply it to
/// each sheet's content, `NativeSheetCanvas` sizes the sheets it presents, and
/// scene and route surfaces reflow beside an open side column. iPhone, and iPad
/// before iPadOS 27 (no sheet placement), keep the sheets' own detents.
///
/// - A scene at least `sideColumnMinimumWidth` wide (every full-screen landscape
///   iPad) shows a sheet as a full-height trailing column without dimming. The
///   route surface that presented it lays out beside the column, so its chat keeps
///   scrolling, taking taps and text. A sheet opened from the column stacks on it
///   in the same column, its parent's top edge showing above it.
/// - A narrower scene (portrait, split or windowed) shows one large, centered,
///   page-sized sheet. Neither mode has a detent to change.
enum TronPadSheetMode: Equatable, Sendable {
    case sideColumn
    case centeredCard

    static let sideColumnMinimumWidth: CGFloat = 1100
    static let sideColumnWidth: CGFloat = 420
    /// The system's margin between a trailing sheet and the window edge (measured: a
    /// 420 pt column spans 765–1185 pt in a 1210 pt window).
    static let sideColumnTrailingMargin: CGFloat = 25
    /// The column, the system's trailing sheet margin and the panel gap.
    static let sideColumnReflowInset: CGFloat = sideColumnWidth + sideColumnTrailingMargin + panelGap
    /// The constant gap between the shrunken scene panel and the column.
    static let panelGap: CGFloat = 12
    static let panelCornerRadius: CGFloat = 28

    /// Nil where managed sheets keep native detents: iPhone, and iPad before iPadOS 27.
    @MainActor
    static func resolve(sceneWidth: CGFloat) -> TronPadSheetMode? {
        guard #available(iOS 27, *), UIDevice.current.userInterfaceIdiom == .pad else { return nil }
        return sceneWidth >= sideColumnMinimumWidth ? .sideColumn : .centeredCard
    }

    /// Sizes a side-column sheet the surface canvas presents: a form-sized sheet
    /// follows its controller's preferred size. A sheet stacked on a column sheet is
    /// presented by SwiftUI's own sheet host, so its column width comes from the
    /// `.form` sizing alone (`testWideLandscapeSubSheetStacksInsideTheSideColumn`).
    @MainActor
    static func prepare(_ presented: UIViewController, in window: UIWindow) {
        guard resolve(sceneWidth: window.bounds.width) == .sideColumn else { return }
        presented.preferredContentSize = CGSize(width: sideColumnWidth, height: window.bounds.height)
    }
}

/// The scene's live width and the sheet mode it implies. A reference the
/// environment hands out, never a value: a managed sheet's source captures its
/// environment when it is installed, often before the first layout, and a copied
/// width or mode would stay stale there (the dashboard's sheets opened as
/// centered cards in a 1210 pt scene). Observation keeps every reader current.
@MainActor @Observable
final class TronPadSheetScene {
    fileprivate(set) var width: CGFloat = 0

    /// Nil until the scene has been measured, and where sheets keep native detents.
    var mode: TronPadSheetMode? { width > 0 ? TronPadSheetMode.resolve(sceneWidth: width) : nil }
}

extension EnvironmentValues {
    /// The scene's iPad sheet geometry, set once at the scene root.
    @Entry var tronPadSheetScene: TronPadSheetScene?
}

/// Whether a managed sheet this surface presents is open.
struct TronPadSheetPresented: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

/// Resolves the scene's iPad sheet mode from its width. Scene roots apply it once.
struct TronPadSheetSceneMode: ViewModifier {
    #if HOSTED_TEST
    /// Simulated windowed width: a simulator cannot be put in Stage Manager, so a
    /// test names the width the mode resolves from (`-tron-scene-width-override`).
    /// Layout still uses the real window; only the mode decision is simulated.
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

/// Applied outside a managed sheet's content, so the iPad mode replaces the
/// content's own detents.
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

/// The scene beside an open side column: one rounded panel that narrows with a
/// spring (interruptible, so a dismissal mid-open reverses from where it is),
/// carrying its navigation chrome with it. Reduce Motion crossfades instead.
struct TronSideColumnPanel: ViewModifier {
    let isOpen: Bool
    /// Only a scene that can reflow beside a side column (an iPad scene root in
    /// side-column mode) is that panel; iPhone scenes and sheets carry no marker.
    let isPanel: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .background {
                if isPanel { Color.clear.accessibilityElement().accessibilityIdentifier("tron-scene-panel").allowsHitTesting(false) }
            }
            // A mask, not a clip: a clip cuts at the layout frame, which excludes the
            // safe areas, so the scene's background stopped at the status bar and
            // home indicator and the window behind showed as black bars. The mask
            // extends under them and only rounds the corners while a column is open.
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
