import SwiftUI
import UserNotifications

@main
struct TronMobileApp: App {
    // App delegate for push notification handling
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    // Central dependency container - manages all services
    @State private var container = DependencyContainer()

    // Appearance mode (Light / Dark / Auto)
    @State private var appearanceSettings = AppearanceSettings.shared

    @State private var initializer = AppInitializer()

    @Environment(\.scenePhase) private var scenePhase

    // Deep link navigation state
    @State private var deepLinkSessionId: String?
    @State private var deepLinkScrollTarget: ScrollTarget?
    @State private var deepLinkNotificationToolCallId: String?

    init() {
        TronFontLoader.registerFonts()

        // Register all event plugins for the new event system
        EventRegistry.shared.registerAll()
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if #available(iOS 26.0, *) {
                    switch initializer.state {
                    case .ready:
                        ContentView(
                            deepLinkSessionId: $deepLinkSessionId,
                            deepLinkScrollTarget: $deepLinkScrollTarget,
                            deepLinkNotificationToolCallId: $deepLinkNotificationToolCallId
                        )
                        .environment(\.dependencies, container)
                    case .loading:
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .tronEmerald))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color.tronBackground)
                    case .failed(let message):
                        InitializationErrorView(message: message) {
                            Task { await initializeApp() }
                        }
                        .background(Color.tronBackground)
                    }
                } else {
                    Text("This app requires iOS 26 or later")
                        .foregroundStyle(.tronTextPrimary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .preferredColorScheme(appearanceSettings.mode.colorScheme)
            .task {
                await initializeApp()
            }
            .onReceive(NotificationCenter.default.publisher(for: .deviceTokenDidUpdate)) { notification in
                // When device token updates, register with server immediately
                guard let token = notification.userInfo?["token"] as? String else { return }
                Task {
                    await registerDeviceToken(token)
                }
            }
            .onChange(of: container.rpcClient.connectionState) { oldState, newState in
                // When connection is established, register pending device token
                guard newState.isConnected && !oldState.isConnected else { return }
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
                    NotificationCenter.default.post(name: .showSettingsAction, object: nil)
                    TronLogger.shared.info("Deep link to settings", category: .notification)
                case .voiceNotes:
                    NotificationCenter.default.post(name: .navigationModeAction, object: NavigationMode.voiceNotes)
                    TronLogger.shared.info("Deep link to voice notes", category: .notification)
                case .notification(let toolCallId):
                    deepLinkNotificationToolCallId = toolCallId
                    TronLogger.shared.info("Deep link to notification inbox: toolCallId=\(toolCallId)", category: .notification)
                case .share:
                    NotificationCenter.default.post(name: .pendingShareContent, object: nil)
                    TronLogger.shared.info("Deep link to share", category: .notification)
                }
            }
            .onChange(of: scenePhase) { oldPhase, newPhase in
                let isBackground = newPhase != .active
                container.setBackgroundState(isBackground)
                TronLogger.shared.info("Scene phase changed: \(oldPhase) -> \(newPhase), background=\(isBackground)", category: .session)

                // When returning to foreground, check for pending share content
                if newPhase == .active && oldPhase != .active {
                    if PendingShareService.load() != nil {
                        container.deepLinkRouter.pendingIntent = .share
                    }
                }

                // When returning to foreground, handle reconnection and refresh session list
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
                            } else {
                                // Connection alive — refresh session list to pick up server-side changes
                                await container.eventStoreManager.refreshSessionList()
                            }
                        case .disconnected, .failed:
                            // Trigger reconnection for disconnected/failed states
                            // Session list will refresh via ContentView's onChange(of: connectionState)
                            TronLogger.shared.info("Triggering reconnection on foreground return (state: \(container.rpcClient.connectionState))", category: .rpc)
                            await container.manualRetry()
                        case .connecting, .reconnecting, .deployRestarting:
                            // Already in progress, let it continue
                            TronLogger.shared.debug("Reconnection already in progress on foreground return", category: .rpc)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Initialization

    private func initializeApp() async {
        await initializer.initialize {
            try await container.initialize()
        }
        if initializer.isReady {
            await setupPushNotifications()
            await resumeEnabledIntegrations()
        }
    }

    /// Resume integrations that were previously enabled (e.g. location monitoring).
    /// Fetches server-authoritative settings and starts services accordingly.
    private func resumeEnabledIntegrations() async {
        do {
            let settings = try await container.rpcClient.settings.get()
            if settings.integrations.location.enabled {
                LocationService.shared.startMonitoring()
            }
        } catch {
            TronLogger.shared.warning("Failed to load settings for integration resume: \(error)", category: .general)
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
