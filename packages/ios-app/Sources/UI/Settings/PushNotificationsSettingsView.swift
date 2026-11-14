import SwiftUI
import TronMobileCore

struct PushNotificationsSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(PushNotificationCoordinator.self) private var pushNotifications

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
        ScrollView(.vertical, showsIndicators: true) {
            TronSettingsSections(alignment: .leading, spacing: 18, hidesLoneHeading: true) {
                TronSettingsGroup("Push Notifications", detail: "Private agent alerts for this iPhone.") {
                    TronSettingsRow(icon: pushStatus.icon, title: pushStatus.title,
                                    subtitle: "\(pushStatus.detail)\nRegistration stage: \(model.pushRegistrationDiagnostic.rawValue)",
                                    subtitleLineLimit: nil, subtitleColor: .tronTextSecondary)
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
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("push-registration-summary")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
        }
        .tronScrollEdgeChrome()
        .tronNavigationTitle("Push Notifications")
    }
}
