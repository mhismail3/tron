import SwiftUI

/// Step 2 of the wizard. iOS can't detect Tailscale due to sandboxing
/// (per Section D edge case in the plan), so this step is purely
/// informational + trust-the-user. The CTA is "Open Tailscale" (deep
/// links to the App Store) and "I have Tailscale" advances.
struct TailscaleStep: View {
    @Bindable var state: OnboardingState
    @Environment(\.openURL) private var openURL

    var body: some View {
        OnboardingShell(
            title: "Install Tailscale",
            subtitle: "Tailscale is the private network that connects your iPhone to your Mac. It's free for personal use.",
            onBack: { state.goBack() },
            content: {
                VStack(alignment: .leading, spacing: TronSpacing.large) {
                    explanationCard
                    onBothDevicesNote
                }
            },
            footer: {
                VStack(spacing: TronSpacing.md) {
                    OnboardingPrimaryButton(
                        title: "I have Tailscale",
                        systemImage: "checkmark",
                        action: { state.advance() }
                    )
                    OnboardingSecondaryButton(
                        title: "Get Tailscale",
                        systemImage: "arrow.up.right.square",
                        action: { openURL(AppConstants.tailscaleAppStoreURL) }
                    )
                }
            }
        )
    }

    @ViewBuilder
    private var explanationCard: some View {
        VStack(alignment: .leading, spacing: TronSpacing.md) {
            HStack(spacing: TronSpacing.md) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Color.tronEmerald)
                Text("Why Tailscale?")
                    .font(TronTypography.headline)
                    .foregroundStyle(Color.tronTextPrimary)
            }
            Text("It encrypts every byte between this iPhone and your Mac. Tron never opens your Mac to the public internet.")
                .font(TronTypography.sans(size: TronTypography.sizeBody))
                .foregroundStyle(Color.tronTextSecondary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(TronSpacing.section)
        .frame(maxWidth: .infinity, alignment: .leading)
        .tronCard()
    }

    @ViewBuilder
    private var onBothDevicesNote: some View {
        HStack(alignment: .top, spacing: TronSpacing.md) {
            Image(systemName: "info.circle")
                .font(.system(size: 14))
                .foregroundStyle(Color.tronTextMuted)
            Text("Make sure Tailscale is installed and signed in on **both** your Mac and this iPhone, with the same account.")
                .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                .foregroundStyle(Color.tronTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
