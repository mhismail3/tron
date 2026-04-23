import SwiftUI

/// First step of the wizard. Two-call-to-action layout:
///   1. **Set up new Mac** — walk through the full flow.
///   2. **I already have Tron running** — power-user shortcut that
///      jumps straight to Pairing (Section A.7 of the plan, "skip the
///      install steps if the user already did them via the CLI").
///
/// No back button (this is the entry point).
struct WelcomeStep: View {
    @Bindable var state: OnboardingState

    var body: some View {
        OnboardingShell(
            title: "Welcome to Tron",
            subtitle: "Tron runs as a coding agent on your Mac. This iPhone app talks to it over Tailscale.",
            showsBackButton: false,
            content: {
                VStack(alignment: .leading, spacing: TronSpacing.large) {
                    bulletList
                    requirementsCard
                }
            },
            footer: {
                VStack(spacing: TronSpacing.md) {
                    OnboardingPrimaryButton(
                        title: "Set up a new Mac",
                        systemImage: "arrow.right",
                        action: { state.advance() }
                    )
                    OnboardingSecondaryButton(
                        title: "I already have Tron running",
                        action: { state.skipToPairing() }
                    )
                }
            }
        )
    }

    @ViewBuilder
    private var bulletList: some View {
        VStack(alignment: .leading, spacing: TronSpacing.md) {
            bullet(icon: "macbook", text: "Tron itself runs on your Mac. You'll install it from a DMG.")
            bullet(icon: "network", text: "Tailscale connects this iPhone to your Mac privately — no public internet needed.")
            bullet(icon: "iphone", text: "This app gives you a chat interface and notifications when work finishes.")
        }
    }

    private func bullet(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: TronSpacing.xl) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Color.tronEmerald)
                .frame(width: 24, alignment: .center)
            Text(text)
                .font(TronTypography.sans(size: TronTypography.sizeBody))
                .foregroundStyle(Color.tronTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var requirementsCard: some View {
        VStack(alignment: .leading, spacing: TronSpacing.sm) {
            Text("You'll need")
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                .foregroundStyle(Color.tronTextSecondary)
                .textCase(.uppercase)
            Text("• A Mac running macOS Sonoma or later\n• Tailscale installed on both devices")
                .font(TronTypography.sans(size: TronTypography.sizeBody))
                .foregroundStyle(Color.tronTextPrimary)
                .lineSpacing(4)
        }
        .padding(TronSpacing.section)
        .frame(maxWidth: .infinity, alignment: .leading)
        .tronCard()
    }
}
