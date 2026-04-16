import SwiftUI

// MARK: - Card Entrance Modifier

struct CardEntranceModifier: ViewModifier {
    let visible: Bool
    let index: Int

    func body(content: Content) -> some View {
        content
            .opacity(visible ? 1 : 0)
            .offset(y: visible ? 0 : 24)
            .animation(
                .spring(response: 0.35, dampingFraction: 0.68)
                    .delay(Double(index) * 0.04),
                value: visible
            )
    }
}

extension View {
    func cardEntrance(visible: Bool, index: Int) -> some View {
        modifier(CardEntranceModifier(visible: visible, index: index))
    }
}
