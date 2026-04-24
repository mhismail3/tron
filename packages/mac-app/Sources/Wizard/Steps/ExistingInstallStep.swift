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
        VStack(alignment: .leading, spacing: 16) {
            Text("Before installing, we check for an existing setup. If we find one, we skip the install step to preserve your settings, sessions, and auth tokens.")
                .font(.body)
                .foregroundStyle(.secondary)

            statusCard

            if let cleanupMessage {
                Text(cleanupMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let cleanupError {
                Text(cleanupError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

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
        GroupBox {
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
                    cleanupControls
                case .installed(let version):
                    cardRow(
                        icon: "checkmark.seal.fill",
                        iconColor: .green,
                        title: "Tron is already installed",
                        body: version.map { "Version \($0). The install step will be skipped." }
                            ?? "Existing install detected. The install step will be skipped."
                    )
                    cleanupControls
                }
            }
        }
    }

    @ViewBuilder
    private var cleanupControls: some View {
        Divider()
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Need a clean retry?")
                    .font(.subheadline.weight(.semibold))
                Text("Remove only the app bundle and LaunchAgent; keep auth, settings, and database files.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Button {
                showCleanupConfirmation = true
            } label: {
                Label(cleanupIsRunning ? "Cleaning..." : "Clean up", systemImage: "trash")
            }
            .buttonStyle(.bordered)
            .tint(.red)
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
                    state.installOutcome = nil
                    state.installRequestID = 0
                case .failed:
                    cleanupError = outcome.userMessage
                }
            }
        }
    }

    @ViewBuilder
    private func cardRow(icon: String, iconColor: Color, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.title).foregroundStyle(iconColor)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(body).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 8)
    }
}
