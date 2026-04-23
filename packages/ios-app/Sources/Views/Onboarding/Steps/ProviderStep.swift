import SwiftUI

/// Step 5 of the wizard — provider authentication.
///
/// **Optional**: chat won't work without at least one provider, but the
/// plan calls this step skippable so users can always defer auth and
/// land in the chat screen first (which then surfaces a banner via
/// `InteractionPolicy.canSendMessage` + the missing-provider check).
///
/// Reuses `OAuthLoginSheet` from the regular Settings flow — the sheet
/// is the same one the providers page uses, so flows tested there
/// (Anthropic browser-OAuth, OpenAI browser-OAuth, Google
/// `ASWebAuthenticationSession` + loopback) all work here unchanged.
///
/// `dependencies.authVersion` increments after every successful OAuth
/// or API-key save (`auth.json` mutation broadcasts via
/// `DependencyContainer.authVersion`). We surface a "Connected" badge on
/// the row whose tile triggered the most recent bump — best-effort UX,
/// the user can always proceed without it.
struct ProviderStep: View {
    @Bindable var state: OnboardingState
    let dependencies: DependencyContainer

    @State private var presentedProvider: OAuthProvider?
    @State private var lastObservedAuthVersion: Int = 0
    @State private var didAuthenticate: Bool = false

    var body: some View {
        OnboardingShell(
            title: "Connect a model provider",
            subtitle: "Sign in with Anthropic, OpenAI, or Google so Tron can talk to a model. You can always add more providers later in Settings.",
            onBack: { state.goBack() },
            content: {
                VStack(alignment: .leading, spacing: TronSpacing.large) {
                    HStack(spacing: TronSpacing.sm) {
                        OnboardingOptionalBadge()
                        Text("You can skip this and add a provider later")
                            .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                            .foregroundStyle(Color.tronTextSecondary)
                    }
                    providerList
                    if didAuthenticate {
                        successBanner
                    }
                }
            },
            footer: {
                VStack(spacing: TronSpacing.md) {
                    OnboardingPrimaryButton(
                        title: didAuthenticate ? "Continue" : "Continue without a provider",
                        systemImage: "arrow.right",
                        action: { state.advance() }
                    )
                    if !didAuthenticate {
                        OnboardingSecondaryButton(
                            title: "Add later in Settings",
                            action: { state.advance() }
                        )
                    }
                }
            }
        )
        .sheet(item: $presentedProvider) { provider in
            OAuthLoginSheet(provider: provider)
                .environment(\.dependencies, dependencies)
        }
        .onAppear {
            // Snapshot the current authVersion so a bump after this step
            // appears (a new provider was added during this step) is detectable.
            lastObservedAuthVersion = dependencies.authVersion
        }
        .onChange(of: dependencies.authVersion) { _, newValue in
            if newValue > lastObservedAuthVersion {
                didAuthenticate = true
            }
        }
    }

    // MARK: - Provider list

    @ViewBuilder
    private var providerList: some View {
        VStack(spacing: TronSpacing.md) {
            providerRow(.anthropic)
            providerRow(.openai)
            providerRow(.google)
        }
    }

    @ViewBuilder
    private func providerRow(_ provider: OAuthProvider) -> some View {
        Button {
            presentedProvider = provider
        } label: {
            HStack(spacing: TronSpacing.section) {
                Image(provider.assetIcon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(provider.accentColor)
                    .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sign in with \(provider.displayName)")
                        .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                        .foregroundStyle(Color.tronTextPrimary)
                    Text(subcopy(for: provider))
                        .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                        .foregroundStyle(Color.tronTextSecondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.tronTextMuted)
            }
            .padding(TronSpacing.section)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: TronSpacing.cornerMD, style: .continuous)
                    .fill(Color.tronSurfaceElevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: TronSpacing.cornerMD, style: .continuous)
                    .stroke(Color.tronBorder, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Sign in with \(provider.displayName)")
    }

    private func subcopy(for provider: OAuthProvider) -> String {
        switch provider.id {
        case "anthropic": return "Use your Claude account."
        case "openai-codex": return "Use your ChatGPT or OpenAI account."
        case "google": return "Use your Google account for Gemini."
        default: return "Continue with \(provider.displayName)."
        }
    }

    @ViewBuilder
    private var successBanner: some View {
        HStack(alignment: .top, spacing: TronSpacing.md) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 16))
                .foregroundStyle(Color.tronEmerald)
            Text("Provider connected. Tap Continue when ready.")
                .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                .foregroundStyle(Color.tronTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(TronSpacing.section)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: TronSpacing.cornerMD, style: .continuous)
                .fill(Color.tronEmerald.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: TronSpacing.cornerMD, style: .continuous)
                .stroke(Color.tronEmerald.opacity(0.4), lineWidth: 1)
        )
    }
}
