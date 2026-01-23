import SwiftUI
import UserNotifications

@main
struct TronMobileApp: App {
    // App delegate for push notification handling
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    @StateObject private var appState = AppState()
    @StateObject private var eventDatabase = EventDatabase()
    @StateObject private var pushNotificationService = PushNotificationService()
    @StateObject private var deepLinkRouter = DeepLinkRouter()
    @Environment(\.scenePhase) private var scenePhase

    // EventStoreManager is created lazily since it needs appState.rpcClient
    @State private var eventStoreManager: EventStoreManager?

    // Deep link navigation state
    @State private var deepLinkSessionId: String?
    @State private var deepLinkScrollTarget: ScrollTarget?

    init() {
        TronFontLoader.registerFonts()
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if #available(iOS 26.0, *) {
                    if let manager = eventStoreManager {
                        ContentView(
                            deepLinkSessionId: $deepLinkSessionId,
                            deepLinkScrollTarget: $deepLinkScrollTarget
                        )
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
                // Handle deep link from push notification via DeepLinkRouter
                guard let userInfo = notification.userInfo else { return }
                deepLinkRouter.handle(notificationPayload: userInfo)
            }
            .onOpenURL { url in
                // Handle URL scheme deep links
                _ = deepLinkRouter.handle(url: url)
            }
            .onChange(of: deepLinkRouter.pendingIntent) { _, _ in
                // Process pending deep link intent
                guard let intent = deepLinkRouter.consumeIntent() else { return }
                switch intent {
                case .session(let sessionId, let scrollTo):
                    deepLinkSessionId = sessionId
                    deepLinkScrollTarget = scrollTo
                    TronLogger.shared.info("Deep linking to session: \(sessionId), scrollTo: \(String(describing: scrollTo))", category: .notification)
                case .settings:
                    // TODO: Navigate to settings
                    TronLogger.shared.info("Deep link to settings", category: .notification)
                case .voiceNotes:
                    // TODO: Navigate to voice notes
                    TronLogger.shared.info("Deep link to voice notes", category: .notification)
                }
            }
            .onChange(of: scenePhase) { oldPhase, newPhase in
                let isBackground = newPhase != .active
                appState.rpcClient.setBackgroundState(isBackground)
                eventStoreManager?.setBackgroundState(isBackground)
                TronLogger.shared.info("Scene phase changed: \(oldPhase) -> \(newPhase), background=\(isBackground)", category: .session)

                // When returning to foreground, handle reconnection based on current state
                if newPhase == .active && oldPhase != .active {
                    Task {
                        // Clear badge count
                        do {
                            try await UNUserNotificationCenter.current().setBadgeCount(0)
                        } catch {
                            TronLogger.shared.debug("Failed to clear badge: \(error)", category: .notification)
                        }

                        // Handle reconnection based on current connection state
                        switch appState.rpcClient.connectionState {
                        case .connected:
                            // Verify connection is still alive
                            let isAlive = await appState.rpcClient.verifyConnection()
                            if !isAlive {
                                TronLogger.shared.info("Connection dead on foreground return - reconnecting", category: .rpc)
                                await appState.rpcClient.forceReconnect()
                            }
                        case .disconnected, .failed:
                            // Trigger reconnection for disconnected/failed states
                            TronLogger.shared.info("Triggering reconnection on foreground return (state: \(appState.rpcClient.connectionState))", category: .rpc)
                            await appState.rpcClient.manualRetry()
                        case .connecting, .reconnecting:
                            // Already in progress, let it continue
                            TronLogger.shared.debug("Reconnection already in progress on foreground return", category: .rpc)
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
