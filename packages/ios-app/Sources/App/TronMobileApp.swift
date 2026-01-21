import SwiftUI
import UserNotifications

@main
struct TronMobileApp: App {
    // App delegate for push notification handling
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    @StateObject private var appState = AppState()
    @StateObject private var eventDatabase = EventDatabase()
    @StateObject private var pushNotificationService = PushNotificationService()
    @Environment(\.scenePhase) private var scenePhase

    // EventStoreManager is created lazily since it needs appState.rpcClient
    @State private var eventStoreManager: EventStoreManager?

    init() {
        TronFontLoader.registerFonts()
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if #available(iOS 26.0, *) {
                    if let manager = eventStoreManager {
                        ContentView()
                            .environmentObject(appState)
                            .environmentObject(manager)
                            .environmentObject(eventDatabase)
                            .environmentObject(pushNotificationService)
                    } else {
                        // Loading state while initializing
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .tronEmerald))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else {
                    // Fallback for older iOS versions
                    Text("This app requires iOS 26 or later")
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .preferredColorScheme(.dark)
            .task {
                // Initialize event database and store manager on app launch
                do {
                    try await eventDatabase.initialize()

                    // Create EventStoreManager with dependencies
                    let manager = EventStoreManager(
                        eventDB: eventDatabase,
                        rpcClient: appState.rpcClient
                    )
                    manager.initialize()

                    // Subscribe to server settings changes for live reconnection
                    manager.subscribeToServerChanges(appState.serverSettingsChanged, appState: appState)

                    // Repair any duplicate events from previous sessions
                    // This fixes the race condition between local caching and server sync
                    manager.repairDuplicates()

                    await MainActor.run {
                        eventStoreManager = manager
                    }

                    TronLogger.shared.info("Event store initialized with \(manager.sessions.count) sessions", category: .session)

                    // Request push notification authorization
                    await setupPushNotifications()
                } catch {
                    TronLogger.shared.error("Failed to initialize event store: \(error)", category: .session)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .deviceTokenDidUpdate)) { notification in
                // When device token updates, register with server immediately
                guard let token = notification.userInfo?["token"] as? String else { return }
                Task {
                    await registerDeviceToken(token)
                }
            }
            .onReceive(appState.rpcClient.$connectionState) { state in
                // When connection is established, register pending device token
                guard state.isConnected else { return }
                guard let token = pushNotificationService.deviceToken else { return }
                Task {
                    await registerDeviceToken(token)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .navigateToSession)) { notification in
                // Handle deep link from push notification
                guard let sessionId = notification.userInfo?["sessionId"] as? String else { return }
                TronLogger.shared.info("Deep linking to session: \(sessionId)", category: .notification)
                // TODO: Navigate to session (requires passing sessionId to ContentView)
            }
            .onChange(of: scenePhase) { oldPhase, newPhase in
                let isBackground = newPhase != .active
                appState.rpcClient.setBackgroundState(isBackground)
                eventStoreManager?.setBackgroundState(isBackground)
                TronLogger.shared.info("Scene phase changed: \(oldPhase) -> \(newPhase), background=\(isBackground)", category: .session)

                // Clear badge count when app becomes active
                if newPhase == .active {
                    Task {
                        do {
                            try await UNUserNotificationCenter.current().setBadgeCount(0)
                        } catch {
                            TronLogger.shared.debug("Failed to clear badge: \(error)", category: .notification)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Push Notifications

    /// Request push notification authorization and register if authorized
    private func setupPushNotifications() async {
        // Request authorization
        let authorized = await pushNotificationService.requestAuthorization()

        if authorized {
            TronLogger.shared.info("Push notifications authorized", category: .notification)

            // If we already have a token and are connected, register it
            if let token = pushNotificationService.deviceToken {
                await registerDeviceToken(token)
            }
        } else {
            TronLogger.shared.info("Push notifications not authorized", category: .notification)
        }
    }

    /// Register device token with the server (global registration, no session required)
    private func registerDeviceToken(_ token: String) async {
        guard appState.rpcClient.isConnected else {
            TronLogger.shared.debug("Not connected, will register token when connected", category: .notification)
            return
        }

        do {
            // Register globally - any agent/session can send notifications
            try await appState.rpcClient.registerDeviceToken(token)
            TronLogger.shared.info("Device token registered with server", category: .notification)
        } catch {
            TronLogger.shared.error("Failed to register device token: \(error.localizedDescription)", category: .notification)
        }
    }
}
