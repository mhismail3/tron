import SwiftUI
import UIKit

/// Root of the iOS onboarding sheet.
///
/// The app opens to the normal dashboard first, then presents this compact
/// sheet while `onboardingComplete == false`. The first pages orient and
/// connect the user; the setup pages stay locked until pairing succeeds.
@available(iOS 26.0, *)
struct OnboardingFlowView: View {
    @State var state: OnboardingState
    let dependencies: DependencyContainer
    let allowsDismiss: Bool
    let onDismiss: () -> Void
    let onComplete: () -> Void

    init(
        state: OnboardingState,
        dependencies: DependencyContainer,
        allowsDismiss: Bool = false,
        onDismiss: @escaping () -> Void = {},
        onComplete: @escaping () -> Void
    ) {
        _state = State(initialValue: state)
        self.dependencies = dependencies
        self.allowsDismiss = allowsDismiss
        self.onDismiss = onDismiss
        self.onComplete = onComplete
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                TabView(selection: stepSelection) {
                    WelcomeOnboardingPage()
                        .tag(OnboardingState.Step.welcome)

                    InstallTailscaleOnboardingPage()
                        .tag(OnboardingState.Step.installTailscale)

                    InstallMacOnboardingPage()
                        .tag(OnboardingState.Step.installMac)

                    PairingStep(
                        state: state,
                        dependencies: dependencies,
                        onPaired: {
                            withAnimation(.snappy(duration: 0.28)) {
                                state.hasPairedMac = true
                                state.currentStep = .workspace
                            }
                        }
                    )
                    .tag(OnboardingState.Step.connect)

                    WorkspaceSetupOnboardingPage(
                        state: state,
                        dependencies: dependencies
                    )
                    .tag(OnboardingState.Step.workspace)

                    ProviderSetupOnboardingPage(
                        state: state,
                        provider: Self.anthropicProvider,
                        dependencies: dependencies,
                        allowsOAuth: true
                    )
                    .tag(OnboardingState.Step.anthropic)

                    ProviderSetupOnboardingPage(
                        state: state,
                        provider: Self.openAIProvider,
                        dependencies: dependencies,
                        allowsOAuth: true
                    )
                    .tag(OnboardingState.Step.openAI)

                    RemainingProvidersOnboardingPage(
                        state: state,
                        dependencies: dependencies
                    )
                    .tag(OnboardingState.Step.providers)

                    ServicesSetupOnboardingPage(
                        state: state,
                        dependencies: dependencies
                    )
                    .tag(OnboardingState.Step.services)

                    ModelSetupOnboardingPage(
                        state: state,
                        dependencies: dependencies,
                        onComplete: {
                            state.complete()
                            onComplete()
                        }
                    )
                    .tag(OnboardingState.Step.model)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                OnboardingPageDots(currentStep: state.currentStep)
                    .padding(.bottom, TronSpacing.large)
            }
            .animation(.snappy(duration: 0.28), value: state.currentStep)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                if allowsDismiss {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(action: onDismiss) {
                            Image(systemName: "xmark")
                                .font(TronTypography.buttonSM)
                                .foregroundStyle(.tronEmerald)
                        }
                        .accessibilityLabel("Dismiss onboarding")
                    }
                }
                ToolbarItem(placement: .principal) {
                    SheetTitle(title: state.currentStep.toolbarTitle, color: .tronEmerald)
                }
            }
        }
        .tint(.tronEmerald)
    }

    private static let anthropicProvider = ProviderInfo(
        id: "anthropic",
        displayName: "Anthropic",
        assetIcon: "IconAnthropic",
        color: .tronCoral,
        supportsOAuth: true
    )

    private static let openAIProvider = ProviderInfo(
        id: "openai-codex",
        displayName: "OpenAI",
        assetIcon: "IconOpenAI",
        color: .tronSlate,
        supportsOAuth: true
    )

    private var stepSelection: Binding<OnboardingState.Step> {
        Binding(
            get: { state.currentStep },
            set: { nextStep in
                guard nextStep.rawValue <= OnboardingState.Step.connect.rawValue || state.hasPairedMac else {
                    state.currentStep = .connect
                    return
                }
                state.currentStep = nextStep
            }
        )
    }
}

@available(iOS 26.0, *)
private struct OnboardingPageDots: View {
    let currentStep: OnboardingState.Step

    var body: some View {
        HStack(spacing: 7) {
            ForEach(OnboardingState.Step.allCases, id: \.self) { step in
                Capsule()
                    .fill(dotFill(for: step))
                    .frame(
                        width: step == currentStep ? 18 : 7,
                        height: 7
                    )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassEffect(.regular.tint(Color.tronEmerald.opacity(0.14)), in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Onboarding step \(currentStep.rawValue + 1) of \(OnboardingState.Step.allCases.count)")
    }

    private func dotFill(for step: OnboardingState.Step) -> Color {
        step.rawValue <= currentStep.rawValue
            ? Color.tronEmerald
            : Color.tronTextMuted.opacity(0.45)
    }
}

@available(iOS 26.0, *)
private struct WelcomeOnboardingPage: View {
    var body: some View {
        OnboardingPage(
            subtitle: "Set up the pieces once, then use this iPhone as the remote for your Mac."
        ) {
            VStack(alignment: .leading, spacing: TronSpacing.section) {
                OnboardingGlassCard {
                    VStack(alignment: .leading, spacing: TronSpacing.md) {
                        OnboardingInfoRow(
                            systemImage: "network",
                            title: "Connect privately",
                            subtitle: "Tailscale links this iPhone to your Mac over your tailnet."
                        )
                        Divider().overlay(Color.tronBorder.opacity(0.4))
                        OnboardingInfoRow(
                            systemImage: "desktopcomputer",
                            title: "Install the Mac server",
                            subtitle: "Tron Server runs quietly in the background on your Mac."
                        )
                        Divider().overlay(Color.tronBorder.opacity(0.4))
                        OnboardingInfoRow(
                            systemImage: "qrcode.viewfinder",
                            title: "Pair with a QR code",
                            subtitle: "The Mac app shows the code after the server is ready."
                        )
                    }
                }
            }
        }
    }
}

@available(iOS 26.0, *)
private struct InstallTailscaleOnboardingPage: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        OnboardingPage(
            subtitle: "Install Tailscale on this iPhone, sign in, and come back when it says Connected."
        ) {
            VStack(alignment: .leading, spacing: TronSpacing.section) {
                OnboardingGlassCard {
                    VStack(alignment: .leading, spacing: TronSpacing.md) {
                        OnboardingInfoRow(
                            systemImage: "network",
                            title: "Tailscale for iPhone",
                            subtitle: "Use the same Tailscale account you use on the Mac."
                        )
                        Divider().overlay(Color.tronBorder.opacity(0.4))
                        OnboardingInfoRow(
                            systemImage: "checkmark.shield",
                            title: "Come back when connected",
                            subtitle: "Tron verifies reachability when you connect to the Mac server."
                        )
                    }
                }

                OnboardingLinkButton(
                    title: "Open Tailscale in the App Store",
                    systemImage: "app.badge"
                ) {
                    openURL(AppConstants.tailscaleAppStorePage)
                }
            }
        }
    }
}

@available(iOS 26.0, *)
private struct InstallMacOnboardingPage: View {
    @Environment(\.openURL) private var openURL
    @State private var didCopy = false

    var body: some View {
        OnboardingPage(
            subtitle: "Install Tron Server on your Mac, then come back here when the Mac installer shows the pairing screen."
        ) {
            VStack(alignment: .leading, spacing: TronSpacing.section) {
                OnboardingGlassCard {
                    HStack(alignment: .top, spacing: TronSpacing.md) {
                        Image(systemName: "macbook.and.iphone")
                            .font(TronTypography.sans(size: TronTypography.sizeTitle, weight: .semibold))
                            .foregroundStyle(Color.tronEmerald)
                            .frame(width: 34, height: 34)

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Mac installer")
                                .font(TronTypography.sans(size: TronTypography.sizeBody, weight: .semibold))
                                .foregroundStyle(Color.tronTextPrimary)
                            Text("Open the releases page on your Mac and download the latest DMG.")
                                .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                                .foregroundStyle(Color.tronTextSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer(minLength: 0)
                    }
                }

                HStack(spacing: TronSpacing.sm) {
                    OnboardingLinkButton(
                        title: "Open releases",
                        systemImage: "safari"
                    ) {
                        openURL(AppConstants.dmgDownloadPage)
                    }

                    OnboardingLinkButton(
                        title: didCopy ? "Copied" : "Copy",
                        systemImage: didCopy ? "checkmark" : "doc.on.doc",
                        width: 128,
                        tintOpacity: didCopy ? 0.28 : 0.16,
                        action: copyDownloadURL
                    )
                }
            }
        }
    }

    private func copyDownloadURL() {
        UIPasteboard.general.string = AppConstants.dmgDownloadPage.absoluteString
        withAnimation(.snappy(duration: 0.2)) {
            didCopy = true
        }
        Task {
            try? await Task.sleep(for: .seconds(1.4))
            await MainActor.run {
                withAnimation(.snappy(duration: 0.2)) {
                    didCopy = false
                }
            }
        }
    }
}

@available(iOS 26.0, *)
private struct OnboardingLinkButton: View {
    let title: String
    let systemImage: String
    var width: CGFloat? = nil
    var tintOpacity: Double = 0.16
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                Text(title)
            }
            .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
            .foregroundStyle(Color.tronEmerald)
            .frame(maxWidth: width == nil ? .infinity : nil)
            .frame(width: width)
            .padding(.vertical, 12)
            .contentShape(RoundedRectangle(cornerRadius: TronSpacing.cornerMD, style: .continuous))
        }
        .buttonStyle(.plain)
        .glassEffect(
            .regular.tint(Color.tronEmerald.opacity(tintOpacity)).interactive(),
            in: RoundedRectangle(cornerRadius: TronSpacing.cornerMD, style: .continuous)
        )
    }
}
