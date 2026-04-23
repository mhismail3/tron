import SwiftUI

/// Step 7 of the wizard. Push notifications.
///
/// On a fresh install the system permission prompt is gated to a
/// deliberate user tap on this step's primary button — we deliberately
/// do NOT call `pushNotificationService.requestAuthorization()` from
/// `TronMobileApp.initializeApp()` anymore (Phase 4.3 moved that out).
///
/// Whichever button the user taps — Allow or Skip — we advance to
/// `done`. Allowing pushes the system prompt; the result (granted /
/// denied) is reflected in `pushNotificationService.isAuthorized` and
/// the user can re-request later from Settings → Notifications. The
/// wizard never blocks on the permission outcome.
struct NotificationsStep: View {
    @Bindable var state: OnboardingState
    let dependencies: DependencyContainer

    @State private var isRequesting: Bool = false

    var body: some View {
        OnboardingShell(
            title: "Stay in the loop",
            subtitle: "Tron can ping you when an agent finishes a long task. You can change this later in Settings or in System Settings.",
            onBack: { state.goBack() },
            content: {
                VStack(alignment: .leading, spacing: TronSpacing.large) {
                    notificationCard
                    bullets
                }
            },
            footer: {
                VStack(spacing: TronSpacing.md) {
                    OnboardingPrimaryButton(
                        title: isRequesting ? "Asking…" : "Allow notifications",
                        systemImage: isRequesting ? nil : "bell.fill",
                        isLoading: isRequesting,
                        isEnabled: !isRequesting,
                        action: requestThenAdvance
                    )
                    OnboardingSecondaryButton(
                        title: "Skip for now",
                        action: { state.advance() }
                    )
                }
            }
        )
    }

    @ViewBuilder
    private var notificationCard: some View {
        VStack(alignment: .leading, spacing: TronSpacing.md) {
            HStack(spacing: TronSpacing.md) {
                Image(systemName: "bell.badge.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Color.tronEmerald)
                Text("Why notifications?")
                    .font(TronTypography.headline)
                    .foregroundStyle(Color.tronTextPrimary)
            }
            Text("Long-running agent tasks can take minutes — a single push at the end means you can put your phone down and come back when there's something to look at.")
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
    private var bullets: some View {
        VStack(alignment: .leading, spacing: TronSpacing.sm) {
            bullet(icon: "checkmark", text: "Agent completion pings")
            bullet(icon: "checkmark", text: "Approval requests when an agent needs you")
            bullet(icon: "xmark", tint: Color.tronTextMuted, text: "We never push marketing or news")
        }
    }

    private func bullet(icon: String, tint: Color = Color.tronEmerald, text: String) -> some View {
        HStack(alignment: .top, spacing: TronSpacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 18, alignment: .center)
            Text(text)
                .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                .foregroundStyle(Color.tronTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Action

    private func requestThenAdvance() {
        // Best-effort: ask once, then advance regardless of grant. The
        // system prompt is one-shot per install, but `isAuthorized` is
        // surfaced in Settings so users can recover later.
        isRequesting = true
        Task {
            _ = await dependencies.pushNotificationService.requestAuthorization()
            await MainActor.run {
                isRequesting = false
                state.advance()
            }
        }
    }
}
