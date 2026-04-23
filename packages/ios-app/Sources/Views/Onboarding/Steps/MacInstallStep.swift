import SwiftUI

/// Step 3 of the wizard. Tells the user to download the DMG on their
/// Mac. Provides:
///   - A copy-able GitHub Releases URL.
///   - A "Open in Safari" button (in case the user is reading on this
///     iPhone and wants to email themselves the link).
///   - A reminder that the Mac wrapper will display its own pairing
///     info — they don't need to remember anything from this screen.
struct MacInstallStep: View {
    @Bindable var state: OnboardingState
    @Environment(\.openURL) private var openURL
    @State private var didCopyURL: Bool = false

    var body: some View {
        OnboardingShell(
            title: "Install Tron on your Mac",
            subtitle: "Download the latest Tron DMG, drag Tron.app into Applications, and open it. The Mac wrapper will walk you through setup.",
            onBack: { state.goBack() },
            content: {
                VStack(alignment: .leading, spacing: TronSpacing.large) {
                    downloadCard
                    nextStepCard
                }
            },
            footer: {
                VStack(spacing: TronSpacing.md) {
                    OnboardingPrimaryButton(
                        title: "Continue when installed",
                        systemImage: "arrow.right",
                        action: { state.advance() }
                    )
                    OnboardingSecondaryButton(
                        title: "Open download page",
                        systemImage: "arrow.up.right.square",
                        action: { openURL(AppConstants.dmgDownloadPage) }
                    )
                }
            }
        )
    }

    @ViewBuilder
    private var downloadCard: some View {
        VStack(alignment: .leading, spacing: TronSpacing.md) {
            HStack(spacing: TronSpacing.md) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Color.tronEmerald)
                Text("Download URL")
                    .font(TronTypography.headline)
                    .foregroundStyle(Color.tronTextPrimary)
            }
            Text(AppConstants.dmgDownloadPage.absoluteString)
                .font(TronTypography.code(size: TronTypography.sizeBodySM))
                .foregroundStyle(Color.tronTextPrimary)
                .lineLimit(2)
                .truncationMode(.middle)
                .padding(.vertical, TronSpacing.md)
                .padding(.horizontal, TronSpacing.section)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: TronSpacing.cornerMD, style: .continuous)
                        .fill(Color.tronSurfaceElevated)
                )
            Button(action: copyURL) {
                HStack(spacing: 8) {
                    Image(systemName: didCopyURL ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 14, weight: .semibold))
                    Text(didCopyURL ? "Copied" : "Copy URL")
                        .font(TronTypography.buttonSM)
                }
                .foregroundStyle(Color.tronEmerald)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Copy download URL")
        }
        .padding(TronSpacing.section)
        .frame(maxWidth: .infinity, alignment: .leading)
        .tronCard()
    }

    @ViewBuilder
    private var nextStepCard: some View {
        HStack(alignment: .top, spacing: TronSpacing.md) {
            Image(systemName: "lightbulb")
                .font(.system(size: 14))
                .foregroundStyle(Color.tronAmber)
            VStack(alignment: .leading, spacing: 4) {
                Text("What happens next")
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM, weight: .semibold))
                    .foregroundStyle(Color.tronTextPrimary)
                Text("After you open Tron.app on your Mac, it'll display a pairing code (host, port, and token). Type or scan it on the next screen.")
                    .font(TronTypography.sans(size: TronTypography.sizeBodySM))
                    .foregroundStyle(Color.tronTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func copyURL() {
        UIPasteboard.general.string = AppConstants.dmgDownloadPage.absoluteString
        didCopyURL = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            await MainActor.run { didCopyURL = false }
        }
    }
}
