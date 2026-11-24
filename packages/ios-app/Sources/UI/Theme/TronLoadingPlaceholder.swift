import SwiftUI

enum TronLoadingPlaceholderEngine {
    static let cycleDuration: Double = 1.8
    static let minimumOpacity: Double = 0.32
    static let maximumOpacity: Double = 0.8

    static func opacity(progress: Double) -> Double {
        let clamped = min(1, max(0, progress))
        let wave = (sin(clamped * 2 * .pi) + 1) / 2
        return minimumOpacity + (maximumOpacity - minimumOpacity) * wave
    }
}

struct TronLoadingPlaceholder<Content: View>: View {
    let label: String
    @ViewBuilder let content: () -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.tronPresentationActivity) private var presentationActivity
    @State private var isVisible = false

    var body: some View {
        TimelineView(.animation(
            minimumInterval: 1 / 30,
            paused: TronPulseLoadingIndicatorEngine.animationPaused(
                reduceMotion: reduceMotion,
                sceneActive: scenePhase == .active,
                surfaceActive: presentationActivity.allowsContinuousAnimation && isVisible
            )
        )) { context in
            content()
                .foregroundStyle(Color.tronTextMuted)
                .redacted(reason: .placeholder)
                .opacity(reduceMotion
                    ? TronLoadingPlaceholderEngine.maximumOpacity
                    : TronLoadingPlaceholderEngine.opacity(
                        progress: context.date.timeIntervalSinceReferenceDate
                            .truncatingRemainder(dividingBy: TronLoadingPlaceholderEngine.cycleDuration)
                            / TronLoadingPlaceholderEngine.cycleDuration
                    ))
        }
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }
}
