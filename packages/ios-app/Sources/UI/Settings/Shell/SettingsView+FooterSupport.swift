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
