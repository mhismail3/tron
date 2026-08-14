import AppKit
import SwiftUI

struct InstallStep: View {
    @Bindable var state: GatewayOnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Install Tron Gateway as a Login Item. macOS will keep it running when the menu-bar app is closed.")
                .font(TronTypography.wizardBody)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            WizardInfoCard(verticalPadding: 18) {
                WizardIconTextRow {
                    statusIcon
                } content: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(statusTitle).font(TronTypography.wizardHeadline)
                        Text(statusDetail)
                            .font(TronTypography.wizardBodySmall)
                            .foregroundStyle(statusFailure == nil ? Color.secondary : Color.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } trailing: {
                    if state.isMutating { ProgressView().controlSize(.small) }
                }
            }
            .accessibilityElement(children: .combine)

            if statusFailure == .approvalRequired {
                Button {
                    LoginItemsSettingsOpener.open()
                } label: {
                    Label("Open Login Items", systemImage: "gearshape.fill")
                }
                .buttonStyle(.wizardLink)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        if state.installIsReady {
            Image(systemName: "checkmark.seal.fill").font(.title2).foregroundStyle(.green)
        } else if statusFailure != nil {
            Image(systemName: "exclamationmark.triangle.fill").font(.title2).foregroundStyle(.red)
        } else {
            Image(systemName: "power.circle.fill").font(.title2).foregroundStyle(Color.tronEmerald)
        }
    }

    private var statusFailure: GatewayLifecycleFailure? {
        if case .failed(let failure) = state.installOutcome { return failure }
        return nil
    }

    private var statusTitle: String {
        if state.installIsReady { return "Tron Gateway is ready" }
        if state.isMutating { return "Preparing Tron Gateway" }
        if statusFailure != nil { return "Setup needs attention" }
        return "Ready to install"
    }

    private var statusDetail: String {
        if state.installIsReady {
            return "Running on Tailscale port \(state.dependencies.configuration.gatewayPort)."
        }
        if state.isMutating {
            return "Validating the bundle, registering the Login Item, and checking authenticated health."
        }
        if let statusFailure { return statusFailure.userMessage }
        return "Installation starts only when you press Install."
    }
}

enum LoginItemsSettingsOpener {
    static func open() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }
}
