import Foundation
import UserNotifications
import UIKit

/// Service for managing push notification authorization and device tokens.
@MainActor
class PushNotificationService: ObservableObject {
    /// Whether push notifications are authorized
    @Published private(set) var isAuthorized: Bool = false

    /// Current authorization status
    @Published private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined

    /// Current device token (hex string, 64 chars)
    @Published private(set) var deviceToken: String?

    /// Last error message during registration
    @Published private(set) var lastErrorMessage: String?

    init() {
        setupObservers()
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
                UIApplication.shared.registerForRemoteNotifications()
                TronLogger.shared.info("Push notification authorization granted", category: .notification)
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
    }

    /// Register for remote notifications if authorized
    func registerIfAuthorized() {
        if isAuthorized {
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    // MARK: - Token Management

    /// Called when device token is received
    func handleTokenUpdate(_ token: String) {
        deviceToken = token
        lastErrorMessage = nil
    }

    /// Called when registration fails
    func handleRegistrationError(_ message: String) {
        lastErrorMessage = message
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
