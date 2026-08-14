import AppKit
import SwiftUI

struct TailscaleStep: View {
    @Bindable var state: GatewayOnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Tron uses Tailscale so your iPhone can reach this Mac without exposing the Gateway to the public internet.")
                .font(TronTypography.wizardBody)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            WizardInfoCard(verticalPadding: 16) {
                WizardIconTextRow {
                    Image(systemName: iconName)
                        .font(.title)
                        .foregroundStyle(iconColor)
                        .accessibilityHidden(true)
                } content: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(headline).font(TronTypography.wizardHeadline)
                        Text(detail)
                            .font(TronTypography.wizardBodySmall)
                            .foregroundStyle(.secondary)
                    }
                } trailing: {
                    if state.isRefreshing { ProgressView().controlSize(.small) }
                }
            }
            .accessibilityElement(children: .combine)

            HStack(spacing: 16) {
                if state.tailscaleStatus?.isReady != true {
                    Button {
                        NSWorkspace.shared.open(URL(string: "https://tailscale.com/download/mac")!)
                    } label: {
                        Label("Open Tailscale download", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.wizardLink)
                }
                Button {
                    state.verifyTailscaleAndContinue()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.wizardLink)
                .disabled(state.isRefreshing)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 86)
    }

    private var iconName: String {
        switch state.tailscaleStatus {
        case .signedIn: "checkmark.seal.fill"
        case .installedNotSignedIn: "exclamationmark.triangle.fill"
        case .notInstalled, .none: "xmark.octagon.fill"
        }
    }

    private var iconColor: Color {
        switch state.tailscaleStatus {
        case .signedIn: .green
        case .installedNotSignedIn: .orange
        case .notInstalled, .none: .red
        }
    }

    private var headline: String {
        switch state.tailscaleStatus {
        case .signedIn: "Tailscale is connected"
        case .installedNotSignedIn: "Tailscale needs attention"
        case .notInstalled, .none: "Tailscale is not connected"
        }
    }

    private var detail: String {
        switch state.tailscaleStatus {
        case .signedIn(let ip): "This Mac is reachable at \(ip)."
        case .installedNotSignedIn: "Open Tailscale and sign in, then refresh."
        case .notInstalled, .none: "Install Tailscale, sign in, then refresh."
        }
    }
}
