import SwiftUI
import UIKit

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
                guard let value, value > 0 else { return }
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
    func tronContentFitDetents() -> some View {
        modifier(TronContentFitDetents())
    }
}
