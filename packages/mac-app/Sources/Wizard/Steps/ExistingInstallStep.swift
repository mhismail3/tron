import SwiftUI

/// Existing-install detection step. The shell owns the icon, title,
/// progress pill, and the bottom action bar (Back / "Skip install" or
/// Continue, dispatched by `WizardStep`). This view contributes the
/// description plus a status card whose copy adapts to whether a
/// prior install was found, partial, or absent.
struct ExistingInstallStep: View {
    @Bindable var state: WizardState
    @Environment(\.environmentSetup) private var setup

    @State private var cleanupIsRunning = false
    @State private var cleanupMessage: String?
    @State private var cleanupError: String?
    @State private var showCleanupConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: ExistingInstallStepLayout.contentSpacing) {
                Text("Before installing, we check for an existing setup. If we find one, we skip the install step to preserve your settings, sessions, and auth tokens.")
                    .font(TronTypography.wizardBody)
                    .foregroundStyle(.secondary)

                statusCard

                if shouldShowCleanupCard {
                    cleanupCard
                }

                if let cleanupMessage {
                    Text(cleanupMessage)
                        .font(TronTypography.wizardCaption)
                        .foregroundStyle(.secondary)
                }
                if let cleanupError {
                    Text(cleanupError)
                        .font(TronTypography.wizardCaption)
                        .foregroundStyle(.red)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)
        }
        .onAppear {
            state.existingInstallStatus = setup.detectExistingInstall()
        }
        .confirmationDialog(
            "Clean up install artifacts?",
            isPresented: $showCleanupConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clean up install", role: .destructive) {
                runCleanup()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This unloads the LaunchAgent and removes the installed Tron.app plus plist. Auth, settings, sessions, and database files are preserved.")
        }
    }

    @ViewBuilder
    private var statusCard: some View {
        WizardInfoCard {
            VStack(alignment: .leading, spacing: 12) {
                switch state.existingInstallStatus {
                case .none:
                    cardRow(
                        icon: "circle.dashed",
                        iconColor: .secondary,
                        title: "No prior install detected",
                        body: "We'll proceed with a fresh install in the next step."
                    )
                case .partial(let reason):
                    cardRow(
                        icon: "exclamationmark.triangle.fill",
                        iconColor: .orange,
                        title: "Partial install detected",
                        body: reason + ". This usually means a previous install was interrupted or removed after launchd state was written. Continuing will replace the plist and install Tron.app; your auth and settings are preserved."
                    )
                case .installed(let version):
                    cardRow(
                        icon: "checkmark.seal.fill",
                        iconColor: .green,
                        title: "Tron is already installed",
                        body: version.map { "Version \($0). The install step will be skipped." }
                            ?? "Existing install detected. The install step will be skipped."
                    )
                }
            }
        }
    }

    private var shouldShowCleanupCard: Bool {
        switch state.existingInstallStatus {
        case .partial, .installed:
            return true
        case .none:
            return false
        }
    }

    @ViewBuilder
    private var cleanupCard: some View {
        WizardInfoCard(verticalPadding: ExistingInstallStepLayout.cleanupCardVerticalPadding) {
            cleanupControls
        }
    }

    @ViewBuilder
    private var cleanupControls: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Need a fresh start?")
                    .font(TronTypography.wizardSubheadline)
                Text("Keep auth and settings; remove app and LaunchAgent.")
                    .font(TronTypography.wizardCaption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .layoutPriority(1)
            Spacer(minLength: 12)
            Button {
                showCleanupConfirmation = true
            } label: {
                Image(systemName: cleanupIsRunning ? "hourglass" : "trash.fill")
            }
            .buttonStyle(.wizardTertiary)
            .help(cleanupIsRunning ? "Cleaning up install artifacts" : "Clean up install artifacts")
            .accessibilityLabel(cleanupIsRunning ? "Cleaning up install artifacts" : "Clean up install artifacts")
            .disabled(cleanupIsRunning)
        }
    }

    private func runCleanup() {
        guard !cleanupIsRunning else { return }
        cleanupIsRunning = true
        cleanupMessage = nil
        cleanupError = nil

        Task {
            let outcome = await setup.cleanupInstallArtifacts()
            await MainActor.run {
                cleanupIsRunning = false
                switch outcome {
                case .success:
                    cleanupMessage = outcome.userMessage
                    state.existingInstallStatus = setup.detectExistingInstall()
                    state.resetInstallRunState()
                case .failed:
                    cleanupError = outcome.userMessage
                }
            }
        }
    }

    @ViewBuilder
    private func cardRow(icon: String, iconColor: Color, title: String, body: String) -> some View {
        WizardIconTextRow {
            Image(systemName: icon).font(.title).foregroundStyle(iconColor)
        } content: {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(TronTypography.wizardHeadline)
                Text(body).font(TronTypography.wizardBodySmall).foregroundStyle(.secondary)
            }
        }
    }
}

enum ExistingInstallStepLayout {
    static let contentSpacing: CGFloat = 12
    static let cleanupCardVerticalPadding: CGFloat = 8
}
