import SwiftUI

struct WelcomeStep: View {
    @Bindable var state: WizardState

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "macbook")
                .font(.system(size: 72))
                .foregroundStyle(.tint)
                .padding(.top, 24)

            VStack(spacing: 8) {
                Text("Welcome to Tron")
                    .font(.largeTitle.bold())
                Text("Tron is a coding agent that lives on this Mac and talks to your iPhone over Tailscale.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            if case .installed(let version) = state.existingInstallStatus {
                GroupBox {
                    HStack {
                        Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("An existing Tron install was detected.")
                                .font(.headline)
                            if let version {
                                Text("Version \(version) — onboarding will skip the install step.")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                    }
                    .padding(.vertical, 8)
                }
            }

            Spacer(minLength: 16)

            VStack(spacing: 12) {
                Button {
                    state.advance()
                } label: {
                    Text("Get started")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)

                Button {
                    state.skipToPairing()
                } label: {
                    Text("I already have Tron running")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderless)
                .controlSize(.large)
            }
        }
    }
}
