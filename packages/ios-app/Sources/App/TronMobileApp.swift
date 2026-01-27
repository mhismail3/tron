import SwiftUI
import UserNotifications

@main
struct TronMobileApp: App {
    // App delegate for push notification handling
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    // Central dependency container - manages all services
    @State private var container = DependencyContainer()

    // Whether container is ready (database initialized, etc.)
    @State private var isReady = false

    @Environment(\.scenePhase) private var scenePhase

    // Deep link navigation state
    @State private var deepLinkSessionId: String?
    @State private var deepLinkScrollTarget: ScrollTarget?

    init() {
        TronFontLoader.registerFonts()

        // Register all event plugins for the new event system
        EventRegistry.shared.registerAll()
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if #available(iOS 26.0, *) {
                    if isReady {
                        ContentView(
                            deepLinkSessionId: $deepLinkSessionId,
                            deepLinkScrollTarget: $deepLinkScrollTarget
                        )
                        .environment(\.dependencies, container)
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
                // Initialize container on app launch
                do {
                    try await container.initialize()
                    isReady = true

                    // Request push notification authorization
                    await setupPushNotifications()
                } catch {
                    TronLogger.shared.error("Failed to initialize container: \(error)", category: .session)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .deviceTokenDidUpdate)) { notification in
                // When device token updates, register with server immediately
                guard let token = notification.userInfo?["token"] as? String else { return }
                Task {
                    await registerDeviceToken(token)
                }
            }
            .onReceive(container.rpcClient.$connectionState) { state in
                // When connection is established, register pending device token
                guard state.isConnected else { return }
                guard let token = container.pushNotificationService.deviceToken else { return }
                Task {
                    await registerDeviceToken(token)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .navigateToSession)) { notification in
                // Handle deep link from push notification via DeepLinkRouter
                guard let userInfo = notification.userInfo else { return }
                container.deepLinkRouter.handle(notificationPayload: userInfo)
            }
            .onOpenURL { url in
                // Handle URL scheme deep links
                _ = container.deepLinkRouter.handle(url: url)
            }
            .onChange(of: container.deepLinkRouter.pendingIntent) { _, _ in
                // Process pending deep link intent
                guard let intent = container.deepLinkRouter.consumeIntent() else { return }
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
                container.setBackgroundState(isBackground)
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
                        switch container.rpcClient.connectionState {
                        case .connected:
                            // Verify connection is still alive
                            let isAlive = await container.verifyConnection()
                            if !isAlive {
                                TronLogger.shared.info("Connection dead on foreground return - reconnecting", category: .rpc)
                                await container.forceReconnect()
                            }
                        case .disconnected, .failed:
                            // Trigger reconnection for disconnected/failed states
                            TronLogger.shared.info("Triggering reconnection on foreground return (state: \(container.rpcClient.connectionState))", category: .rpc)
                            await container.manualRetry()
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
        let authorized = await container.pushNotificationService.requestAuthorization()

        if authorized {
            TronLogger.shared.info("Push notifications authorized", category: .notification)

            // If we already have a token and are connected, register it
            if let token = container.pushNotificationService.deviceToken {
                await registerDeviceToken(token)
            }
        } else {
            TronLogger.shared.info("Push notifications not authorized", category: .notification)
        }
    }

    /// Register device token with the server (global registration, no session required)
    private func registerDeviceToken(_ token: String) async {
        guard container.rpcClient.isConnected else {
            TronLogger.shared.debug("Not connected, will register token when connected", category: .notification)
            return
        }

        do {
            // Register globally - any agent/session can send notifications
            try await container.rpcClient.misc.registerDeviceToken(token)
            TronLogger.shared.info("Device token registered with server", category: .notification)
        } catch {
            TronLogger.shared.error("Failed to register device token: \(error.localizedDescription)", category: .notification)
        }
    }
}
