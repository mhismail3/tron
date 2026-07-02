import SwiftUI

struct FooterFeedbackButtonChromeModifier: ViewModifier {
    private let shape = RoundedRectangle(
        cornerRadius: MainSettingsFooterLayout.feedbackButtonCornerRadius,
        style: .continuous
    )

    func body(content: Content) -> some View {
        content.glassEffect(
            .regular
                .tint(Color.tronTextMuted.opacity(MainSettingsFooterLayout.feedbackButtonGlassTintOpacity))
                .interactive(),
            in: shape
        )
    }
}

struct SettingsFooterBackdrop: View {
    var body: some View {
        ZStack {
            Rectangle()
                .fill(.thinMaterial)
                .opacity(0.26)

            Rectangle()
                .fill(
                    LinearGradient(
                        stops: [
                            .init(color: Color.tronBackground.opacity(0.0), location: 0.0),
                            .init(color: Color.tronBackground.opacity(0.12), location: 0.54),
                            .init(color: Color.tronBackground.opacity(0.32), location: 1.0),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        }
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.0),
                    .init(color: .black.opacity(0.18), location: 0.30),
                    .init(color: .black.opacity(0.62), location: 0.64),
                    .init(color: .black, location: 1.0),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .ignoresSafeArea(edges: .bottom)
        .allowsHitTesting(false)
    }
}

extension View {
    func footerFeedbackButtonChrome() -> some View {
        modifier(FooterFeedbackButtonChromeModifier())
    }
}

struct FeedbackMailDraft: Identifiable {
    let id = UUID()
    let subject: String
    let body: String
    let recipient: String
    let attachments: [FeedbackMailAttachment]
}

#if DEBUG
#Preview {
    SettingsView()
        .environment(\.dependencies, DependencyContainer())
}
#endif
