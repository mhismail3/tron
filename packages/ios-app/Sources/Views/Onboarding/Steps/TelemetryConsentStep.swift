import SwiftUI

/// Step 6 of the wizard. Opt-in telemetry consent (default OFF).
///
/// The decision is persisted via `OnboardingState.setTelemetryConsent(_:)`
/// — that writes through to UserDefaults under the
/// `OnboardingState.telemetryConsentStorageKey` key, which is the same
/// key the PostHog client (Phase 7) reads when deciding whether to emit
/// events.
///
/// Both the primary "Help improve Tron" button and the secondary
/// "Not now" button advance the wizard — the consent value just differs.
/// We deliberately do NOT model a third "decide later" state: a missing
/// answer is treated as "no" so we never silently emit telemetry from a
/// user who never explicitly opted in.
struct TelemetryConsentStep: View {
    @Bindable var state: OnboardingState

    var body: some View {
        OnboardingShell(
            title: "Help improve Tron",
            subtitle: "Tron can send anonymous usage data so we know what's broken and what's working. You can change this anytime in Settings → Privacy.",
            onBack: { state.goBack() },
            content: {
                VStack(alignment: .leading, spacing: TronSpacing.large) {
                    summaryCards
                    privacyNote
                }
            },
            footer: {
                VStack(spacing: TronSpacing.md) {
                    OnboardingPrimaryButton(
                        title: "Help improve Tron",
                        systemImage: "heart.fill",
                        action: {
                            state.setTelemetryConsent(true)
                            state.advance()
                        }
                    )
                    OnboardingSecondaryButton(
                        title: "Not now",
                        action: {
                            state.setTelemetryConsent(false)
                            state.advance()
                        }
                    )
                }
            }
        )
    }

    @ViewBuilder
    private var summaryCards: some View {
        VStack(spacing: TronSpacing.md) {
            consentCard(
                icon: "checkmark.seal.fill",
                tint: Color.tronEmerald,
                title: "What gets sent",
                bullets: [
                    "Which features you use",
                    "Anonymous error rates",
                    "How long onboarding took"
                ]
            )
            consentCard(
                icon: "hand.raised.fill",
                tint: Color.tronError,
                title: "What never leaves your device",
                bullets: [
                    "Your chat messages and prompts",
                    "Provider keys and bearer tokens",
                    "Filenames, paths, or workspace contents"
                ]
            )
        }
    }

    private func consentCard(
        icon: String,
        tint: Color,
        title: String,
        bullets: [String]
    ) -> some View {
        VStack(alignment: .leading, spacing: TronSpacing.md) {
            HStack(spacing: TronSpacing.md) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(tint)
                Text(title)
                    .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                    .foregroundStyle(Color.tronTextPrimary)
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(bullets, id: \.self) { line in
                    HStack(alignment: .top, spacing: 8) {
                        Text("•")
                            .foregroundStyle(Color.tronTextMuted)
                        Text(line)
                            .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                            .foregroundStyle(Color.tronTextSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .padding(TronSpacing.section)
        .frame(maxWidth: .infinity, alignment: .leading)
        .tronCard()
    }

    @ViewBuilder
    private var privacyNote: some View {
        HStack(alignment: .top, spacing: TronSpacing.md) {
            Image(systemName: "info.circle")
                .font(.system(size: 14))
                .foregroundStyle(Color.tronTextMuted)
            Text("Default is **off**. We only enable telemetry if you tap “Help improve Tron”.")
                .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                .foregroundStyle(Color.tronTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
