import Foundation
import UserNotifications
import UIKit

/// Service for managing push notification authorization and device tokens.
@Observable
@MainActor
final class PushNotificationService {
    /// Whether push notifications are authorized
    private(set) var isAuthorized: Bool = false

    /// Current authorization status
    private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined

    /// Current APNs device token as a hex string. APNs token bytes are
    /// variable-length opaque data, so this must not assume a fixed size.
    private(set) var deviceToken: String?

    /// Last error message during registration
    private(set) var lastErrorMessage: String?

    init() {
        setupObservers()
        TronLogger.shared.debug("PushNotificationService initialized; checking authorization status", category: .notification)
        Task {
            await checkAuthorizationStatus()
        }
    }

    // MARK: - Authorization

    /// Request push notification authorization
    @discardableResult
    func requestAuthorization() async -> Bool {
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])

            await checkAuthorizationStatus()

            if granted {
                TronLogger.shared.info("Push notification authorization granted; registering for remote notifications", category: .notification)
                UIApplication.shared.registerForRemoteNotifications()
            } else {
                TronLogger.shared.info("Push notification authorization denied", category: .notification)
            }

            return granted
        } catch {
            TronLogger.shared.error("Failed to request push authorization: \(error.localizedDescription)", category: .notification)
            lastErrorMessage = error.localizedDescription
            return false
        }
    }

    /// Check current authorization status
    func checkAuthorizationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        authorizationStatus = settings.authorizationStatus

        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            isAuthorized = true
        case .denied, .notDetermined:
            isAuthorized = false
        @unknown default:
            isAuthorized = false
        }
        TronLogger.shared.debug(
            "Push notification authorization status=\(settings.authorizationStatus) authorized=\(isAuthorized)",
            category: .notification
        )
    }

    /// Register for remote notifications if authorized
    func registerIfAuthorized() {
        if isAuthorized {
            TronLogger.shared.info("Registering for remote notifications with APNs", category: .notification)
            UIApplication.shared.registerForRemoteNotifications()
        } else {
            TronLogger.shared.debug(
                "Skipping APNs registration because notification authorization status=\(authorizationStatus)",
                category: .notification
            )
        }
    }

    // MARK: - Token Management

    /// Called when device token is received
    func handleTokenUpdate(_ token: String) {
        deviceToken = token
        lastErrorMessage = nil
        TronLogger.shared.info(
            "APNs device token updated: prefix=\(token.prefix(8))… length=\(token.count)",
            category: .notification
        )
    }

    /// Called when registration fails
    func handleRegistrationError(_ message: String) {
        lastErrorMessage = message
        TronLogger.shared.error("APNs device token registration failed: \(message)", category: .notification)
    }

    // MARK: - Private

    private func setupObservers() {
        // Observe device token updates - closure runs on main queue
        NotificationCenter.default.addObserver(
            forName: .deviceTokenDidUpdate,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let token = notification.userInfo?["token"] as? String else { return }
            // We're on main queue, use MainActor.assumeIsolated
            MainActor.assumeIsolated {
                self?.handleTokenUpdate(token)
            }
        }

        // Observe registration failures - closure runs on main queue
        NotificationCenter.default.addObserver(
            forName: .deviceTokenRegistrationFailed,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let message = (notification.userInfo?["error"] as? Error)?.localizedDescription ?? "Unknown error"
            // We're on main queue, use MainActor.assumeIsolated
            MainActor.assumeIsolated {
                self?.handleRegistrationError(message)
            }
        }
    }
}
