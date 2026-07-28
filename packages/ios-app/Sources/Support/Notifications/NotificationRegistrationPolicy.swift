import Foundation

enum NativeNotificationPermissionPolicy {
    static func shouldRequest(
        hasAuthenticatedConnection: Bool,
        attemptedThisLaunch: Bool,
        status: NotificationAuthorizationState
    ) -> Bool {
        hasAuthenticatedConnection && !attemptedThisLaunch && status == .notDetermined
    }

    static func permitsRemoteRegistration(_ status: NotificationAuthorizationState) -> Bool {
        [.authorized, .provisional, .ephemeral].contains(status)
    }
}
