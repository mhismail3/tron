import SwiftUI
import UIKit

/// Root of the iOS onboarding sheet.
///
/// The app opens to the normal dashboard first, then presents this compact
/// paged sheet while `onboardingComplete == false`. Pages one and two orient
/// the user; page three is the only step that persists anything.
@available(iOS 26.0, *)
struct OnboardingFlowView: View {
    @State var state: OnboardingState
    let dependencies: DependencyContainer
    let onComplete: () -> Void

    init(
        state: OnboardingState,
        dependencies: DependencyContainer,
        onComplete: @escaping () -> Void
    ) {
        _state = State(initialValue: state)
        self.dependencies = dependencies
        self.onComplete = onComplete
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                OnboardingTopBar(step: state.currentStep)

                TabView(selection: stepSelection) {
                    WelcomeOnboardingPage()
                        .tag(OnboardingState.Step.welcome)

                    InstallMacOnboardingPage()
                        .tag(OnboardingState.Step.installMac)

                    PairingStep(
                        state: state,
                        dependencies: dependencies,
                        onPaired: onComplete
                    )
                    .tag(OnboardingState.Step.connect)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .animation(.snappy(duration: 0.28), value: state.currentStep)
            }
            .tronScreenBackground()
            .navigationBarHidden(true)
        }
    }

    private var stepSelection: Binding<OnboardingState.Step> {
        Binding(
            get: { state.currentStep },
            set: { state.currentStep = $0 }
        )
    }
}

@available(iOS 26.0, *)
private struct WelcomeOnboardingPage: View {
    var body: some View {
        OnboardingPage(
            systemImage: "sparkles",
            title: "Welcome to Tron",
            subtitle: "Tron lets this iPhone talk to the server running on your Mac."
        ) {
            VStack(alignment: .leading, spacing: TronSpacing.section) {
                OnboardingGlassCard {
                    VStack(alignment: .leading, spacing: TronSpacing.md) {
                        OnboardingInfoRow(
                            systemImage: "desktopcomputer",
                            title: "Your Mac does the work",
                            subtitle: "Install Tron Server once, then keep using this app as the remote."
                        )
                        Divider().overlay(Color.tronBorder.opacity(0.4))
                        OnboardingInfoRow(
                            systemImage: "network",
                            title: "Tailscale keeps it private",
                            subtitle: "Both devices need to be signed into the same tailnet."
                        )
                        Divider().overlay(Color.tronBorder.opacity(0.4))
                        OnboardingInfoRow(
                            systemImage: "qrcode.viewfinder",
                            title: "Pair with a QR code",
                            subtitle: "The Mac app shows the code after the server is ready."
                        )
                    }
                }

                OnboardingSwipeHint(title: "Swipe left to install the Mac server")
                    .padding(.top, TronSpacing.sm)
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
            systemImage: "arrow.down.app",
            title: "Install the Tron server on your Mac",
            subtitle: "Download the Mac app, run the installer, then continue here when it shows the pairing screen."
        ) {
            VStack(alignment: .leading, spacing: TronSpacing.section) {
                OnboardingGlassCard {
                    VStack(alignment: .leading, spacing: TronSpacing.md) {
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

                        HStack(spacing: TronSpacing.sm) {
                            Button {
                                openURL(AppConstants.dmgDownloadPage)
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "safari")
                                    Text("Open releases")
                                }
                                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                                .foregroundStyle(Color.tronEmerald)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .contentShape(RoundedRectangle(cornerRadius: TronSpacing.cornerMD, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .glassEffect(
                                .regular.tint(Color.tronEmerald.opacity(0.16)).interactive(),
                                in: RoundedRectangle(cornerRadius: TronSpacing.cornerMD, style: .continuous)
                            )

                            Button {
                                copyDownloadURL()
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                                    Text(didCopy ? "Copied" : "Copy")
                                }
                                .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                                .foregroundStyle(Color.tronEmerald)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 12)
                                .contentShape(RoundedRectangle(cornerRadius: TronSpacing.cornerMD, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .glassEffect(
                                .regular.tint(Color.tronEmerald.opacity(didCopy ? 0.28 : 0.16)).interactive(),
                                in: RoundedRectangle(cornerRadius: TronSpacing.cornerMD, style: .continuous)
                            )
                        }
                    }
                }

                Text(AppConstants.dmgDownloadPage.absoluteString)
                    .font(TronTypography.codeCaption)
                    .foregroundStyle(Color.tronTextMuted)
                    .lineLimit(2)
                    .textSelection(.enabled)

                OnboardingSwipeHint(title: "Swipe left after the Mac app is ready")
                    .padding(.top, TronSpacing.sm)
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
