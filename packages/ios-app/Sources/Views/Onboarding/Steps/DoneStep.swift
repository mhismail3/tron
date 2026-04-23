import SwiftUI

/// Final step of the wizard. Confetti + a single CTA that closes
/// onboarding and presents `ContentView`.
///
/// Tapping "Get started" calls:
///   1. `state.complete()` — flips
///      `@AppStorage("onboardingComplete") = true` (the first-run gate
///      observes this and swaps in the regular `ContentView`).
///   2. `onComplete()` — closure injected by `OnboardingFlowView` so the
///      gate (or a test harness) can observe completion explicitly.
///
/// No back button — once you're here, going back to "Notifications"
/// would be confusing and rolling back the consent flag has no
/// meaningful effect.
struct DoneStep: View {
    @Bindable var state: OnboardingState
    let onComplete: () -> Void

    var body: some View {
        OnboardingShell(
            title: "You're all set",
            subtitle: "Tron is paired with your Mac. Open a chat to start an agent — or jump into Settings to add more providers.",
            showsBackButton: false,
            content: {
                VStack(alignment: .leading, spacing: TronSpacing.large) {
                    successHero
                    quickTips
                }
            },
            footer: {
                OnboardingPrimaryButton(
                    title: "Get started",
                    systemImage: "arrow.right",
                    action: complete
                )
            }
        )
    }

    @ViewBuilder
    private var successHero: some View {
        VStack(alignment: .center, spacing: TronSpacing.md) {
            ZStack {
                Circle()
                    .fill(Color.tronEmerald.opacity(0.15))
                    .frame(width: 96, height: 96)
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 56, weight: .semibold))
                    .foregroundStyle(Color.tronEmerald)
            }
            Text("Welcome to Tron")
                .font(TronTypography.headline)
                .foregroundStyle(Color.tronTextPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, TronSpacing.lg)
    }

    @ViewBuilder
    private var quickTips: some View {
        VStack(alignment: .leading, spacing: TronSpacing.md) {
            Text("Where to go from here")
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                .foregroundStyle(Color.tronTextSecondary)
                .textCase(.uppercase)
            tip(icon: "bubble.left.and.bubble.right.fill", text: "Tap the compose button to start a chat with your agent.")
            tip(icon: "gearshape.fill", text: "Open Settings → Model Providers to add or change your model account.")
            tip(icon: "server.rack", text: "Pair more Macs from Settings → Server — switch between them anytime.")
        }
        .padding(TronSpacing.section)
        .frame(maxWidth: .infinity, alignment: .leading)
        .tronCard()
    }

    private func tip(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: TronSpacing.md) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.tronEmerald)
                .frame(width: 22, alignment: .center)
            Text(text)
                .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                .foregroundStyle(Color.tronTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private func complete() {
        state.complete()
        onComplete()
    }
}
