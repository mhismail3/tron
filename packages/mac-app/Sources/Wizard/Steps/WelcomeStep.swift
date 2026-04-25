import SwiftUI

/// Welcome is the wizard's entry step. The shell owns the icon, title,
/// progress pill, and both action buttons (primary "Get started", link
/// "I already have Tron running"); this view contributes only the
/// description text plus a contextual banner if an existing install
/// has already been detected on disk.
///
/// Layout note: the description and optional existing-install banner
/// are treated as one centered middle unit so detection state cannot
/// push the bottom buttons or snap the page from centered to leading.
struct WelcomeStep: View {
    @Bindable var state: WizardState

    private let copy = "Tron is an agent that lives on your Mac.\nYou talk to Tron from your iPhone."

    var body: some View {
        VStack(spacing: WelcomeStepLayout.middleGroupSpacing) {
            descriptionText
                .multilineTextAlignment(.center)

            if case .installed(let version) = state.existingInstallStatus {
                existingInstallBanner(version: version)
            }
        }
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

    @ViewBuilder
    private func existingInstallBanner(version: String?) -> some View {
        HStack(alignment: .center, spacing: WelcomeStepLayout.detectedBannerIconSpacing) {
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(Color.tronSuccess)
                .font(.callout)
                .frame(width: WelcomeStepLayout.detectedBannerIconWidth, alignment: .center)
            VStack(alignment: .leading, spacing: 2) {
                Text("Existing Tron install detected")
                    .font(TronTypography.wizardSubheadline)
                    .foregroundStyle(Color.tronEmerald)
                if let version {
                    Text("Version \(version) — onboarding will skip the install step.")
                        .font(TronTypography.wizardCaption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, WelcomeStepLayout.detectedBannerVerticalPadding)
        .padding(.horizontal, WelcomeStepLayout.detectedBannerHorizontalPadding)
        .wizardGlassCard()
    }
}

enum WelcomeStepLayout {
    static let middleGroupSpacing: CGFloat = 48
    static let detectedBannerIconWidth: CGFloat = 20
    static let detectedBannerIconSpacing: CGFloat = 10
    static let detectedBannerHorizontalPadding: CGFloat = 18
    static let detectedBannerVerticalPadding: CGFloat = 9
}
