import SwiftUI

struct WelcomeStep: View {
    @Bindable var state: WizardState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Title row — Tron logo + heading at top-left, matching
            // the rest of the wizard step pattern.
            HStack(spacing: 12) {
                Image("TronLogo")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 28, height: 28)
                    // Logo + title share the brand emerald so the top
                    // of every wizard step reads as "Tron" at a glance.
                    .foregroundStyle(Color.tronEmerald)
                Text("Welcome to Tron")
                    .font(.system(.title2, design: .rounded).weight(.semibold))
                    .foregroundStyle(Color.tronEmerald)
            }

            Text("Tron is a coding agent that lives on this Mac. You talk to it from your phone over Tailscale.")
                .font(.system(.body, design: .rounded))
                .foregroundStyle(.secondary)
                .lineSpacing(2)
                .padding(.top, 12)
                .fixedSize(horizontal: false, vertical: true)

            if case .installed(let version) = state.existingInstallStatus {
                existingInstallBanner(version: version)
                    .padding(.top, 16)
            }

            Spacer(minLength: 12)

            VStack(spacing: 8) {
                Button {
                    state.advance()
                } label: {
                    Text("Get started")
                }
                .buttonStyle(.wizardPrimary)
                .keyboardShortcut(.defaultAction)

                Button {
                    state.skipToPairing()
                } label: {
                    Text("I already have Tron running")
                }
                .buttonStyle(.wizardLink)
            }
            .padding(.bottom, 4)
        }
    }

    @ViewBuilder
    private func existingInstallBanner(version: String?) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(Color.tronSuccess)
                .font(.callout)
            VStack(alignment: .leading, spacing: 2) {
                Text("Existing Tron install detected")
                    .font(.system(.subheadline, design: .rounded).weight(.medium))
                    .foregroundStyle(Color.tronEmerald)
                if let version {
                    Text("Version \(version) — onboarding will skip the install step.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.tronEmerald.opacity(0.25), lineWidth: 0.5)
                )
        )
    }
}
