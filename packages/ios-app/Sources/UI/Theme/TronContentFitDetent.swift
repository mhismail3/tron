import SwiftUI
import UIKit

/// Visible height, measured from the sheet's top edge, at which a sheet's
/// opening detent shows exactly its leading content (the model picker's two
/// card rails). A destination publishes it; `tronContentFitDetents()` at the sheet
/// root consumes it. Absent a value, the sheet uses medium and large.
struct TronSheetFitHeightKey: PreferenceKey {
    static let defaultValue: CGFloat? = nil
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        if let next = nextValue() { value = next }
    }
}

private struct TronContentFitDetents: ViewModifier {
    @State private var fitHeight: CGFloat?
    @State private var selection: PresentationDetent = .medium

    func body(content: Content) -> some View {
        content
            .onPreferenceChange(TronSheetFitHeightKey.self) { value in
                // Keep the last measured height when the content stops
                // publishing (search hides the rails) so the sheet never jumps.
                guard let value, value > 0 else { return }
                // A custom detent excludes the bottom safe area, which the sheet
                // adds back below it. The sheet's own inset changes while it
                // floats in (23 pt mid-animation, 34 pt settled on a Pro), which
                // republished heights the settled sheet then ignored, so the
                // device's fixed home-indicator inset is used instead.
                let height = (value - Self.deviceBottomInset).rounded()
                guard height != fitHeight else { return }
                let followsFit = selection != .large
                fitHeight = height
                if followsFit { selection = .height(height) }
            }
            .presentationDetents(detents, selection: $selection)
    }

    @MainActor private static var deviceBottomInset: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first?.safeAreaInsets.bottom ?? 0
    }

    private var detents: Set<PresentationDetent> {
        fitHeight.map { [.height($0), .large] } ?? [.medium, .large]
    }
}

extension View {
    /// Opening detent that fits the destination's published leading content,
    /// expandable to large. Apply at the sheet's root content.
    func tronContentFitDetents() -> some View {
        modifier(TronContentFitDetents())
    }
}
