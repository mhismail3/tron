import SwiftUI

/// Existing-install detection step. The shell owns the icon, title,
/// progress pill, and the bottom action bar (Back / "Skip install" or
/// Continue, dispatched by `WizardStep`). This view contributes the
/// description plus a status card whose copy adapts to whether a
/// prior install was found, partial, or absent.
struct ExistingInstallStep: View {
    @Bindable var state: WizardState
    @Environment(\.environmentSetup) private var setup

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Tron checks for a prior install before laying down its files. If we detect one, we skip the install step so we don't clobber your settings, sessions, or auth tokens.")
                .font(.body)
                .foregroundStyle(.secondary)

            statusCard

            Spacer(minLength: 0)
        }
        .onAppear {
            state.existingInstallStatus = setup.detectExistingInstall()
        }
    }

    @ViewBuilder
    private var statusCard: some View {
        GroupBox {
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
                    body: reason + ". The install step will repair this."
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
