import SwiftUI

/// Welcome is the wizard's entry step. The shell owns the icon, title,
/// progress pill, and both action buttons (primary "Get started", link
/// "I already have Tron running"); this view contributes only the
/// centered description text.
struct WelcomeStep: View {
    private let copy = "Tron is an agent that lives on your Mac.\nYou talk to Tron from your iPhone."

    var body: some View {
        descriptionText
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    @ViewBuilder
    private var descriptionText: some View {
        Text(copy)
            .font(TronTypography.wizardBody)
            .foregroundStyle(.secondary)
            .lineSpacing(4)
            .fixedSize(horizontal: false, vertical: true)
    }
}
