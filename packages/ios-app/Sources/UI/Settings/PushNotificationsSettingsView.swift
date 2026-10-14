import SwiftUI
import TronMobileCore

/// Push Notifications: this iPhone's agent-alert readiness and the alert policy
/// it registers with the paired Mac. Its own Settings row (#939); the rows and
/// toggles take the opening group's accent from the settings theme.
struct PushNotificationsSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(PushNotificationCoordinator.self) private var pushNotifications

    private func notificationPolicyBinding(_ keyPath: WritableKeyPath<PushNotificationPolicy, Bool>) -> Binding<Bool> {
        Binding(
            get: { pushNotifications.notificationPolicy[keyPath: keyPath] },
            set: { value in
                var next = pushNotifications.notificationPolicy
                next[keyPath: keyPath] = value
                Task { @MainActor in
                    do { try await pushNotifications.updateNotificationPolicy(next) }
                    catch { model.presentError(error) }
                }
            }
        )
    }

    private var pushStatus: (icon: String, title: String, detail: String) {
        switch model.pushNotificationReadiness {
        case .ready:
            return ("bell.badge.fill", "Ready", "Agent alerts can reach this iPhone.")
        case .permissionRequired:
            return ("bell", "Permission required", "Allow notifications to receive agent alerts.")
        case .denied:
            return ("bell.slash.fill", "Disabled", "Enable notifications in iOS Settings to receive alerts.")
        case .registering:
            return ("bell.and.waves.left.and.right", "Registering", "Securing this iPhone for agent alerts.")
        case .pending:
            return ("clock.arrow.circlepath", "Pending", "Registration will retry without interrupting chat.")
        case .unavailable:
            return ("bell.slash", "Unavailable", "Pair a Mac with a push-enabled Tron build.")
        }
    }

    var body: some View {
        let policyEditable = model.connectionState == .connected && pushNotifications.readiness == .ready
            && !pushNotifications.isUpdatingNotificationPolicy
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 18) {
                TronSettingsGroup("Push Notifications", detail: "Private agent alerts for this iPhone.") {
                    VStack(spacing: 0) {
                        TronValueRow(icon: pushStatus.icon, title: pushStatus.title, detail: pushStatus.detail)
                        TronSettingsDivider()
                        TronToggleRow(icon: "questionmark.bubble.fill", title: "Input needed",
                                      detail: "Time Sensitive alerts when Tron needs a response",
                                      isEnabled: policyEditable, isOn: notificationPolicyBinding(\.inputNeeded))
                        TronSettingsDivider()
                        TronToggleRow(icon: "stop.circle.fill", title: "Finished",
                                      detail: "Alert when the session has no pending background work",
                                      isEnabled: policyEditable, isOn: notificationPolicyBinding(\.finished))
                        TronSettingsDivider()
                        TronToggleRow(icon: "hourglass", title: "Waiting on background work",
                                      detail: "Alert once while delegated work is still running",
                                      isEnabled: policyEditable, isOn: notificationPolicyBinding(\.waiting))
                        TronSettingsDivider()
                        TronValueRow(icon: "stethoscope", title: "Registration stage",
                                     detail: model.pushRegistrationDiagnostic.rawValue)
                        if pushNotifications.canRetryRejectedRegistration {
                            TronSettingsDivider()
                            Button {
                                do { try pushNotifications.retryRejectedRegistration() }
                                catch { model.presentError(error) }
                            } label: {
                                TronValueRow(icon: "arrow.clockwise", title: "Retry Registration",
                                             detail: "Generate one fresh App Attest key after correcting the relay.")
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("Preserves the APNs token, pairings, grants, and other Keychain data")
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
        }
        .tronScrollEdgeChrome()
        .tronNavigationTitle("Push Notifications")
    }
}
