import UIKit
@preconcurrency import UserNotifications

/// The Approve or Decline action a settings-approval push carries (decision 35).
enum SettingsApprovalPushDecision: String, Equatable, Sendable {
    case approve, decline
}

/// The relay maps the Gateway's allowlisted category to `aps.category`; the
/// identifiers here must match that allowlist.
enum SettingsApprovalNotification {
    static let categoryIdentifier = "settings-approval"
    static let approveActionIdentifier = "settings-approval.approve"
    static let declineActionIdentifier = "settings-approval.decline"

    static var category: UNNotificationCategory {
        UNNotificationCategory(
            identifier: categoryIdentifier,
            actions: [
                UNNotificationAction(
                    identifier: approveActionIdentifier,
                    title: "Approve",
                    options: [.foreground, .authenticationRequired]
                ),
                UNNotificationAction(
                    identifier: declineActionIdentifier,
                    title: "Decline",
                    options: [.foreground, .authenticationRequired, .destructive]
                ),
            ],
            intentIdentifiers: [],
            options: []
        )
    }
}

struct PushNotificationTap: Equatable, Sendable {
    let sessionID: String?
    let machineID: String?
    let requestID: String?
    /// Set only for an admitted settings-approval push whose Approve or Decline action was chosen.
    let settingsDecision: SettingsApprovalPushDecision?

    init(
        sessionID: String?,
        machineID: String?,
        requestID: String? = nil,
        settingsDecision: SettingsApprovalPushDecision? = nil
    ) {
        self.sessionID = sessionID
        self.machineID = machineID
        self.requestID = requestID
        self.settingsDecision = settingsDecision
    }

    var route: (sessionID: String, machineID: String)? {
        guard let sessionID, let machineID else { return nil }
        return (sessionID, machineID)
    }

    static func admit(
        _ userInfo: [AnyHashable: Any],
        categoryIdentifier: String = "",
        actionIdentifier: String = ""
    ) -> PushNotificationTap {
        let requestID = admitRequestID((userInfo["tron"] as? [AnyHashable: Any])?["requestId"])
        guard let sessionID = admitSessionID(userInfo["sessionId"]),
              let machineID = admitMachineID(userInfo["machineId"]) else {
            return PushNotificationTap(sessionID: nil, machineID: nil, requestID: requestID)
        }
        let settingsDecision = categoryIdentifier == SettingsApprovalNotification.categoryIdentifier
            ? admitSettingsDecision(actionIdentifier)
            : nil
        return PushNotificationTap(
            sessionID: sessionID,
            machineID: machineID,
            requestID: requestID,
            settingsDecision: settingsDecision
        )
    }

    private static func admitSettingsDecision(_ actionIdentifier: String) -> SettingsApprovalPushDecision? {
        switch actionIdentifier {
        case SettingsApprovalNotification.approveActionIdentifier: .approve
        case SettingsApprovalNotification.declineActionIdentifier: .decline
        default: nil
        }
    }

    private static func admitSessionID(_ value: Any?) -> String? {
        guard let candidate = value as? String,
              !candidate.isEmpty,
              candidate.utf8.count <= 160,
              candidate.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.contains($0) || "-_:".unicodeScalars.contains($0)
              }) else { return nil }
        return candidate
    }

    private static func admitRequestID(_ value: Any?) -> String? {
        guard let candidate = value as? String,
              (8...160).contains(candidate.utf8.count),
              candidate.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.contains($0) || "-_".unicodeScalars.contains($0)
              }) else { return nil }
        return candidate
    }

    private static func admitMachineID(_ value: Any?) -> String? {
        guard let candidate = value as? String,
              !candidate.isEmpty,
              candidate.utf8.count <= 256,
              candidate.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return candidate
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, @preconcurrency UNUserNotificationCenterDelegate {
    nonisolated(unsafe) var onDeviceToken: (@MainActor @Sendable (Data) -> Void)?
    nonisolated(unsafe) var onRegistrationFailure: (@MainActor @Sendable () -> Void)?
    private nonisolated(unsafe) var onNotificationTap: (@MainActor @Sendable (PushNotificationTap) -> Void)?
    private nonisolated(unsafe) var pendingNotificationTap: PushNotificationTap?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().setNotificationCategories([SettingsApprovalNotification.category])
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let callback = onDeviceToken
        Task { @MainActor in callback?(deviceToken) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        let callback = onRegistrationFailure
        Task { @MainActor in callback?() }
    }

    @MainActor
    func installNotificationTapHandler(_ handler: @escaping @MainActor @Sendable (PushNotificationTap) -> Void) {
        onNotificationTap = handler
        guard let pendingNotificationTap else { return }
        self.pendingNotificationTap = nil
        handler(pendingNotificationTap)
    }

    @MainActor
    func deliverNotificationTap(_ tap: PushNotificationTap) {
        guard let onNotificationTap else {
            pendingNotificationTap = tap
            return
        }
        onNotificationTap(tap)
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let content = response.notification.request.content
        let tap = PushNotificationTap.admit(
            content.userInfo,
            categoryIdentifier: content.categoryIdentifier,
            actionIdentifier: response.actionIdentifier
        )
        await deliverNotificationTap(tap)
    }
}
