import SwiftUI

/// Tailscale prerequisite step. The shell owns the icon, title,
/// progress pill, and the bottom action bar (Back / "I have Tailscale"
/// or Continue). This view contributes the explanatory copy, the live
/// status card driven by `setup.probeTailscale()`, and — only when
/// Tailscale isn't yet ready — an inline link to the macOS download
/// page.
struct TailscaleStep: View {
    @Bindable var state: WizardState
    @Environment(\.environmentSetup) private var setup

    @State private var probing = false
    @State private var pollTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 16) {
                Text("Tron uses Tailscale as a private mesh network so your iPhone can reach this Mac without exposing it to the public internet.")
                    .font(TronTypography.wizardBody)
                    .foregroundStyle(.secondary)

                statusCard

                // Tertiary action: only relevant before Tailscale is up.
                // Inlined here (rather than living in the shell's bottom
                // bar) so it slides with the rest of the body content
                // and disappears cleanly once the user signs in.
                if !(state.tailscaleStatus?.isReady ?? false) {
                    Button {
                        NSWorkspace.shared.open(URL(string: "https://tailscale.com/download/mac")!)
                    } label: {
                        Label("Open Tailscale download", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.wizardLink)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)
        }
        .onAppear { startProbe() }
        .onDisappear { pollTask?.cancel() }
    }

    @ViewBuilder
    private var statusCard: some View {
        WizardInfoCard {
            WizardIconTextRow {
                Image(systemName: iconName)
                    .font(.title)
                    .foregroundStyle(iconColor)
            } content: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(headline)
                        .font(TronTypography.wizardHeadline)
                    Text(subheadline)
                        .font(TronTypography.wizardBodySmall)
                        .foregroundStyle(.secondary)
                }
            } trailing: {
                if probing {
                    ProgressView().controlSize(.small)
                }
            }
        }
    }

    private var iconName: String {
        switch state.tailscaleStatus {
        case .signedIn: return "checkmark.seal.fill"
        case .installedNotSignedIn: return "exclamationmark.triangle.fill"
        case .notInstalled, .none: return "xmark.octagon.fill"
        }
    }

    private var iconColor: Color {
        switch state.tailscaleStatus {
        case .signedIn: return .green
        case .installedNotSignedIn: return .orange
        case .notInstalled, .none: return .red
        }
    }

    private var headline: String {
        switch state.tailscaleStatus {
        case .signedIn: return "Tailscale is connected"
        case .installedNotSignedIn: return "Tailscale is installed but not signed in"
        case .notInstalled, .none: return "Tailscale is not installed"
        }
    }

    private var subheadline: String {
        switch state.tailscaleStatus {
        case .signedIn(let ip):
            return "This Mac is reachable at \(ip) on your tailnet."
        case .installedNotSignedIn:
            return "Open Tailscale and sign in, then come back to this window."
        case .notInstalled, .none:
            return "Download and install Tailscale, then return here."
        }
    }

    private func startProbe() {
        pollTask?.cancel()
        pollTask = Task { @MainActor in
            // Probe once immediately, then every 1 s while the wizard
            // is on this step. We stop on `.signedIn` to avoid burning
            // CPU when the user has already finished setup.
            while !Task.isCancelled {
                probing = true
                let status = await setup.probeTailscale()
                probing = false
                state.tailscaleStatus = status
                if status.isReady { return }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }
}
