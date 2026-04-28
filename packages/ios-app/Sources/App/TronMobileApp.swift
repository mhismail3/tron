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

    // Onboarding state — owned per-launch; survives across the sheet
    // because @State preserves its initial value for the lifetime of
    // the App. Once `onboardingComplete` flips to true the sheet is
    // dismissed and the dashboard remains mounted.
    @State private var onboardingState = OnboardingState()
    @State private var isOnboardingSheetPresented = false
    @State private var onboardingDetent: PresentationDetent = .medium
    @State private var onboardingAllowsDismiss = false
    @State private var onboardingSuppressed = false

    /// First-run pairing flag. Driven by `OnboardingState.completionStorageKey`
    /// (the literal key `"onboardingComplete"`). When false, the app still
    /// mounts the dashboard and presents `OnboardingFlowView` as a medium
    /// sheet.
    @AppStorage("onboardingComplete") private var onboardingComplete: Bool = false

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
                    rootContent()
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
                guard !handlePairingURL(url) else { return }
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

                // Flush any pending debounced draft save before backgrounding
                if isBackground {
                    Task { await container.draftStore.flushPending() }
                }

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
                        // Sync badge with server unread count
                        await container.notificationStore.refresh()
                        if container.notificationStore.unreadCount == 0 {
                            await container.notificationStore.clearBadge()
                        } else {
                            do {
                                try await UNUserNotificationCenter.current().setBadgeCount(container.notificationStore.unreadCount)
                            } catch {
                                TronLogger.shared.debug("Failed to update badge: \(error)", category: .notification)
                            }
                        }

                        // Handle reconnection based on current connection state.
                        // Session-list refresh is requested unconditionally — the central
                        // SessionRefreshService coalesces and defers to reconnect if offline.
                        container.eventStoreManager.requestSessionRefresh(reason: .foreground)

                        switch container.rpcClient.connectionState {
                        case .connected:
                            // Verify the connection is still alive — force-reconnect if dead.
                            let isAlive = await container.verifyConnection()
                            if !isAlive {
                                TronLogger.shared.info("Connection dead on foreground return - reconnecting", category: .rpc)
                                await container.forceReconnect()
                            }
                        case .deployRestarting:
                            // Server restart flow owns its own reconnect budget — don't interfere.
                            TronLogger.shared.debug("Deploy-restart reconnect in progress on foreground return", category: .rpc)
                        case .disconnected, .failed, .connecting, .reconnecting:
                            // Any non-connected/non-deploy state on foreground return is
                            // treated as "kick a fresh retry". This covers the case where
                            // the reconnect Task was paused during backgrounding and the
                            // state is stale; manualRetry() resets the attempt counter and
                            // cancels any lingering task before spawning a new one.
                            TronLogger.shared.info("Triggering manualRetry on foreground return (state: \(container.rpcClient.connectionState))", category: .rpc)
                            await container.manualRetry()
                        case .unauthorized:
                            // .unauthorized is a parked state — auto-retrying on
                            // foreground would just re-trigger 401. The user must
                            // tap the pill (or open the re-pair sheet) to provide
                            // a fresh token first; only then does manualRetry fire.
                            TronLogger.shared.info("Skipping foreground auto-retry while unauthorized — awaiting user re-pair", category: .rpc)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Content builder

    @available(iOS 26.0, *)
    @ViewBuilder
    private func rootContent() -> some View {
        switch initializer.state {
        case .ready:
            readyContent()
        case .loading:
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: .tronEmerald))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .tronScreenBackground()
        case .failed(let message):
            InitializationErrorView(message: message) {
                Task { await initializeApp() }
            }
            .tronScreenBackground()
        }
    }

    @available(iOS 26.0, *)
    @ViewBuilder
    private func readyContent() -> some View {
        dashboardContent
            .sheet(isPresented: $isOnboardingSheetPresented) {
                OnboardingFlowView(
                    state: onboardingState,
                    dependencies: container,
                    allowsDismiss: onboardingAllowsDismiss,
                    onDismiss: dismissOnboardingFromSettings,
                    onComplete: {
                        onboardingComplete = true
                        onboardingAllowsDismiss = false
                        onboardingSuppressed = false
                        isOnboardingSheetPresented = false
                    }
                )
                .environment(\.dependencies, container)
                .environment(\.interactionPolicy, container.interactionPolicy)
                .presentationDetents([.medium, .large], selection: $onboardingDetent)
                .presentationSizing(.largeForm)
                .presentationBackground(.clear)
                .presentationDragIndicator(.hidden)
                .interactiveDismissDisabled(!onboardingComplete && !onboardingAllowsDismiss)
            }
            .onAppear(perform: syncOnboardingSheetPresentation)
            .onChange(of: onboardingComplete) { _, isComplete in
                syncOnboardingSheetPresentation()
                guard isComplete else { return }
                Task { await registerPushIfAuthorized() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .startServerOnboarding)) { notification in
                launchServerOnboarding(notification: notification)
            }
    }

    @available(iOS 26.0, *)
    private var dashboardContent: some View {
        ContentView(
            deepLinkSessionId: $deepLinkSessionId,
            deepLinkScrollTarget: $deepLinkScrollTarget,
            deepLinkNotificationToolCallId: $deepLinkNotificationToolCallId
        )
        .environment(\.dependencies, container)
        .environment(\.interactionPolicy, container.interactionPolicy)
        .withErrorHandler()
        .withToastBanner()
        .task {
            guard onboardingComplete else { return }
            await registerPushIfAuthorized()
        }
    }

    private func syncOnboardingSheetPresentation() {
        let shouldPresent = !onboardingComplete && !onboardingSuppressed
        if shouldPresent && !isOnboardingSheetPresented {
            onboardingDetent = .medium
            onboardingAllowsDismiss = false
        }
        isOnboardingSheetPresented = shouldPresent
    }

    private func dismissOnboardingFromSettings() {
        onboardingSuppressed = !onboardingComplete
        onboardingAllowsDismiss = false
        isOnboardingSheetPresented = false
    }

    private func launchServerOnboarding(notification: Notification) {
        let serverId = notification.userInfo?["serverId"] as? String
        let server = serverId.flatMap { id in
            container.pairedServerStore.servers.first { $0.id == id }
        }

        onboardingState.prepareServerOnboarding(prefill: server)

        onboardingSuppressed = false
        onboardingAllowsDismiss = true
        onboardingDetent = .large
        isOnboardingSheetPresented = true
    }

    @discardableResult
    private func handlePairingURL(_ url: URL) -> Bool {
        guard case .success(let payload) = PairingURLParser.parse(url.absoluteString) else {
            return false
        }
        onboardingState.acceptPairingPayload(payload)
        onboardingDetent = .large
        isOnboardingSheetPresented = true
        onboardingAllowsDismiss = false
        onboardingSuppressed = false
        onboardingComplete = false
        return true
    }

    // MARK: - Initialization

    private func initializeApp() async {
        await initializer.initialize {
            try await container.initialize()
        }
        // Push-notification permission setup intentionally NOT triggered
        // here. Users can enable notifications from Settings; startup only
        // registers an already-authorized token after pairing completes.
    }

    // MARK: - Push Notifications

    /// Register device token with the server (global registration — the
    /// server fans out every NotifyApp to all active tokens regardless of
    /// which session the notification originates from).
    private func registerDeviceToken(_ token: String) async {
        guard container.rpcClient.isConnected else {
            TronLogger.shared.debug("Not connected, will register token when connected", category: .notification)
            return
        }

        do {
            try await container.rpcClient.misc.registerDeviceToken(token)
            TronLogger.shared.info("Device token registered with server", category: .notification)
        } catch {
            TronLogger.shared.error("Failed to register device token: \(error.localizedDescription)", category: .notification)
        }
    }

    private func registerPushIfAuthorized() async {
        // Re-check authorization + register any pending device token. This
        // never prompts; the actual permission request lives in Settings.
        await container.pushNotificationService.checkAuthorizationStatus()
        container.pushNotificationService.registerIfAuthorized()
        if let token = container.pushNotificationService.deviceToken {
            await registerDeviceToken(token)
        }
    }
}
