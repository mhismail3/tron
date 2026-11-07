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
    /// The column plus the system's trailing sheet margin.
    static let sideColumnReflowInset: CGFloat = sideColumnWidth + 16

    /// Nil where managed sheets keep native detents: iPhone, and iPad before iPadOS 27.
    @MainActor
    static func resolve(sceneWidth: CGFloat) -> TronPadSheetMode? {
        guard #available(iOS 27, *), UIDevice.current.userInterfaceIdiom == .pad else { return nil }
        return sceneWidth >= sideColumnMinimumWidth ? .sideColumn : .centeredCard
    }

    /// Sizes a side-column sheet before UIKit presents it. A form-sized sheet
    /// follows its controller's preferred size, the one size UIKit also honors for
    /// a sheet stacked on another sheet.
    @MainActor
    static func prepare(_ presented: UIViewController, in window: UIWindow) {
        guard resolve(sceneWidth: window.bounds.width) == .sideColumn else { return }
        presented.preferredContentSize = CGSize(width: sideColumnWidth, height: window.bounds.height)
    }
}

extension EnvironmentValues {
    /// The scene's iPad sheet mode, set once at the scene root.
    @Entry var tronPadSheetMode: TronPadSheetMode?
}

/// Whether a managed sheet this surface presents is open.
struct TronPadSheetPresented: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

/// Resolves the scene's iPad sheet mode from its width. Scene roots apply it once.
struct TronPadSheetSceneMode: ViewModifier {
    @State private var sceneWidth: CGFloat = 0 // presentation read of the scene's width

    func body(content: Content) -> some View {
        content
            .environment(\.tronPadSheetMode, TronPadSheetMode.resolve(sceneWidth: sceneWidth))
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { sceneWidth = $0 }
    }
}

/// Applied outside a managed sheet's content, so the iPad mode replaces the
/// content's own detents.
private struct TronPadSheetPresentationModifier: ViewModifier {
    @Environment(\.tronPadSheetMode) private var mode

    func body(content: Content) -> some View {
        if #available(iOS 27, *), let mode {
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
