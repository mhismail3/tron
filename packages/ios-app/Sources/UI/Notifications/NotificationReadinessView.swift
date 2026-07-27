import SwiftUI

struct NotificationReadinessView: View {
    let coordinator: NativeNotificationCoordinator
    let servers: [PairedServer]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsSectionHeader(title: "Delivery")
            SettingsCard {
                VStack(alignment: .leading, spacing: 8) {
                    Text(permissionDescription)
                        .font(TronTypography.sans(size: TronTypography.sizeBody3))
                    if coordinator.authorizationStatus == .denied {
                        Button("Open System Settings") {
                            guard let url = URL(string: UIApplication.openSettingsURLString) else {
                                return
                            }
                            UIApplication.shared.open(url)
                        }
                        .buttonStyle(.bordered)
                    }
                    if let problem = coordinator.remoteRegistrationProblem {
                        Text(problem)
                            .font(TronTypography.sans(size: TronTypography.sizeCaption))
                            .foregroundStyle(.tronWarning)
                    }
                }
                .padding(12)
            }
            ForEach(servers) { server in
                let state = coordinator.readiness.first { $0.serverId == server.id }
                SettingsCard(accent: state?.ready == true ? .tronEmerald : .tronWarning) {
                    VStack(alignment: .leading, spacing: 9) {
                        SettingsRow(
                            icon: state?.ready == true ? "bell.badge.fill" : "bell.slash",
                            label: server.label,
                            accentColor: state?.ready == true ? .tronEmerald : .tronWarning
                        ) {
                            Text(state?.ready == true ? "Ready" : "Needs attention")
                                .font(TronTypography.sans(size: TronTypography.sizeCaption))
                                .foregroundStyle(.tronTextMuted)
                        }
                        readinessLine(
                            label: "Device",
                            value: state?.deviceReady == true
                                ? "Registered"
                                : (state?.problem ?? "Waiting for registration")
                        )
                        readinessLine(label: "Provider", value: providerDescription(state))
                    }
                }
            }
        }
    }

    private var permissionDescription: String {
        switch coordinator.authorizationStatus {
        case .notDetermined: "Notification permission has not been requested."
        case .denied: "Notifications are disabled in System Settings."
        case .authorized: "Notifications are authorized."
        case .provisional: "Notifications are provisionally authorized."
        case .ephemeral: "Notifications are temporarily authorized."
        }
    }

    private func readinessLine(label: String, value: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(TronTypography.sans(size: TronTypography.sizeCaption, weight: .medium))
                .foregroundStyle(.tronTextSecondary)
            Spacer()
            Text(value)
                .font(TronTypography.sans(size: TronTypography.sizeCaption))
                .foregroundStyle(.tronTextMuted)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
    }

    private func providerDescription(_ state: NotificationServerReadiness?) -> String {
        guard let state else { return "Waiting for engine" }
        if let problem = state.transportProblem {
            return problem.replacingOccurrences(of: "_", with: " ")
        }
        guard let mode = state.transportMode else { return "Waiting for status" }
        let label = mode == .relay ? "Relay" : "Direct APNs"
        return "\(label) \(state.transportConfigured == true ? "ready" : "not configured")"
    }
}
