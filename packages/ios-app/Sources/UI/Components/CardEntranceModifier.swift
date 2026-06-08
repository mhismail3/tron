import SwiftUI

// MARK: - Card Entrance Modifier

enum CardEntranceConfiguration {
    static let initialOffsetY: CGFloat = 16
    static let response = 0.32
    static let dampingFraction = 0.86
    static let staggerInterval = 0.035
    static let maxStaggerDelay = 0.18

    static func delay(for index: Int) -> Double {
        min(Double(max(index, 0)) * staggerInterval, maxStaggerDelay)
    }

    static func animation(for index: Int, reduceMotion: Bool) -> Animation {
        let delay = delay(for: index)
        if reduceMotion {
            return .easeOut(duration: 0.12).delay(delay)
        }
        return .spring(
            response: response,
            dampingFraction: dampingFraction,
            blendDuration: 0.04
        )
        .delay(delay)
    }
}

struct CardEntranceModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let visible: Bool
    let index: Int

    func body(content: Content) -> some View {
        content
            .transaction { transaction in
                // Sheet presentation springs should not animate the card's
                // glass layout. The wrapper below owns only opacity/offset.
                transaction.animation = nil
            }
            .opacity(visible ? 1 : 0)
            .offset(y: visible || reduceMotion ? 0 : CardEntranceConfiguration.initialOffsetY)
            .animation(
                CardEntranceConfiguration.animation(for: index, reduceMotion: reduceMotion),
                value: visible
            )
    }
}

extension View {
    func cardEntrance(visible: Bool, index: Int) -> some View {
        modifier(CardEntranceModifier(visible: visible, index: index))
    }
}
