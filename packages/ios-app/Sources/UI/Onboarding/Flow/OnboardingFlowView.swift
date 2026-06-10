import SwiftUI
import UIKit

/// Root of the iOS onboarding sheet.
///
/// The app opens to the normal session list first, then presents this compact
/// sheet while `onboardingComplete == false`. The first pages orient and
/// connect the user; the setup pages stay locked until pairing succeeds.
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

                    if state.hasPairedMac {
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
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                OnboardingPageDots(currentStep: state.currentStep)
                .padding(.horizontal, TronSpacing.xlarge)
                .padding(.bottom, OnboardingPageDotsMetrics.bottomPadding)
            }
            .animation(.snappy(duration: 0.28), value: state.currentStep)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItemGroup(placement: .topBarLeading) {
                    if allowsDismiss {
                        Button(action: onDismiss) {
                            Image(systemName: "xmark")
                                .font(TronTypography.buttonSM)
                                .foregroundStyle(.tronEmerald)
                        }
                        .accessibilityLabel("Dismiss onboarding")
                    }

                    if state.canNavigateBackward {
                        toolbarNavigationButton(
                            title: "Back",
                            systemImage: "chevron.left",
                            accessibilityLabel: "Back",
                            action: state.goBack
                        )
                    }
                }

                ToolbarItem(placement: .principal) {
                    SheetTitle(title: state.currentStep.toolbarTitle, color: .tronEmerald)
                }

                ToolbarItem(placement: .topBarTrailing) {
                    if state.canNavigateForward {
                        toolbarNavigationButton(
                            title: "Next",
                            systemImage: "chevron.right",
                            accessibilityLabel: "Next",
                            action: state.goForward
                        )
                    }
                }
            }
        }
        .tint(.tronEmerald)
        .onAppear {
            state.selectStep(state.currentStep)
        }
        .onChange(of: state.hasPairedMac) { _, _ in
            state.selectStep(state.currentStep)
        }
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
                state.selectStep(nextStep)
            }
        )
    }

    private func toolbarNavigationButton(
        title: String,
        systemImage: String,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.24)) {
                action()
            }
        } label: {
            Label(title, systemImage: systemImage)
                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                .foregroundStyle(Color.tronEmerald)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}

internal struct OnboardingInfoCopy: Equatable {
    let systemImage: String
    let title: String
    let subtitle: String
}

internal enum OnboardingCopy {
    static let welcomeSubtitle = "Tron is a local, private AI agent that runs on your machine. Unlike other agents, you talk to Tron from your iPhone."
    static let welcomeRows = [
        OnboardingInfoCopy(
            systemImage: "desktopcomputer",
            title: "Install the Mac server",
            subtitle: "Tron runs in the background on your Mac device"
        ),
        OnboardingInfoCopy(
            systemImage: "network",
            title: "Connect privately",
            subtitle: "Tron uses your Tailscale account to securely and privately link your devices"
        ),
        OnboardingInfoCopy(
            systemImage: "qrcode.viewfinder",
            title: "Pair seamlessly",
            subtitle: "Use the QR code provided during Mac installation to quickly pair your iPhone"
        ),
    ]

    static let tailscaleSubtitle = "Tron uses your Tailscale account to link your devices on your private tailnet. This requires the Tailscale VPN to be set up on this iPhone."
    static let tailscaleRows = [
        OnboardingInfoCopy(
            systemImage: "app.badge",
            title: "Download the Tailscale app",
            subtitle: "Use the link below to download Tailscale from the App Store"
        ),
        OnboardingInfoCopy(
            systemImage: "person.crop.circle",
            title: "Sign in to your account",
            subtitle: "Use the same account you use to sign in on your Mac"
        ),
        OnboardingInfoCopy(
            systemImage: "checkmark.shield",
            title: "Come back here when connected",
            subtitle: "Tron verifies reachability when you connect to the Mac server"
        ),
    ]

    static let installMacSubtitle = "Tron runs on your own Mac device in the background. Install the Tron server on your Mac, then come back here when the installer shows the QR code pairing screen."
    static let installMacCopyButtonTitle = "Copy Link"
    static let installMacCopiedButtonTitle = "Copied"
    static let installMacReleasesButtonTitle = "Open Releases page"
}

internal enum OnboardingPageDotsMetrics {
    static let bottomPadding: CGFloat = 10
    static let spacing: CGFloat = 6
    static let activeWidth: CGFloat = 16
    static let inactiveWidth: CGFloat = 6
    static let dotHeight: CGFloat = 6
    static let horizontalPadding: CGFloat = 10
    static let verticalPadding: CGFloat = 6
}

private struct OnboardingPageDots: View {
    let currentStep: OnboardingState.Step

    var body: some View {
        HStack(spacing: OnboardingPageDotsMetrics.spacing) {
            ForEach(OnboardingState.Step.allCases, id: \.self) { step in
                Capsule()
                    .fill(dotFill(for: step))
                    .frame(
                        width: step == currentStep
                            ? OnboardingPageDotsMetrics.activeWidth
                            : OnboardingPageDotsMetrics.inactiveWidth,
                        height: OnboardingPageDotsMetrics.dotHeight
                    )
            }
        }
        .padding(.horizontal, OnboardingPageDotsMetrics.horizontalPadding)
        .padding(.vertical, OnboardingPageDotsMetrics.verticalPadding)
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

private struct OnboardingInfoRows: View {
    let rows: [OnboardingInfoCopy]

    var body: some View {
        VStack(alignment: .leading, spacing: TronSpacing.md) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                OnboardingInfoRow(
                    systemImage: row.systemImage,
                    title: row.title,
                    subtitle: row.subtitle
                )
                if index < rows.count - 1 {
                    Divider().overlay(Color.tronBorder.opacity(0.4))
                }
            }
        }
    }
}

private struct WelcomeOnboardingPage: View {
    var body: some View {
        OnboardingPage(
            subtitle: OnboardingCopy.welcomeSubtitle
        ) {
            VStack(alignment: .leading, spacing: TronSpacing.section) {
                OnboardingGlassCard {
                    OnboardingInfoRows(rows: OnboardingCopy.welcomeRows)
                }
            }
        }
    }
}

private struct InstallTailscaleOnboardingPage: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        OnboardingPage(
            subtitle: OnboardingCopy.tailscaleSubtitle
        ) {
            VStack(alignment: .leading, spacing: TronSpacing.section) {
                OnboardingGlassCard {
                    OnboardingInfoRows(rows: OnboardingCopy.tailscaleRows)
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

private struct InstallMacOnboardingPage: View {
    @Environment(\.openURL) private var openURL
    @State private var didCopy = false

    var body: some View {
        OnboardingPage(
            subtitle: OnboardingCopy.installMacSubtitle
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

                VStack(spacing: TronSpacing.sm) {
                    OnboardingLinkButton(
                        title: didCopy
                            ? OnboardingCopy.installMacCopiedButtonTitle
                            : OnboardingCopy.installMacCopyButtonTitle,
                        systemImage: didCopy ? "checkmark" : "doc.on.doc",
                        tintOpacity: didCopy ? 0.28 : 0.16,
                        action: copyDownloadURL
                    )

                    OnboardingLinkButton(
                        title: OnboardingCopy.installMacReleasesButtonTitle,
                        systemImage: "safari"
                    ) {
                        openURL(AppConstants.dmgDownloadPage)
                    }
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
