import SwiftUI

private enum ProductionAppStorageKeys {
    static let onboardingComplete = "onboardingComplete"
}

/// The real application graph. `TronMobileApp` constructs this view only for
/// application and UI-test processes; hosted unit-test processes never
/// evaluate its state, dependencies, persistence, or lifecycle modifiers.
struct ProductionAppRoot: View {

    // Central dependency container - manages all services
    @State private var container: DependencyContainer

    // Appearance mode (Light / Dark / Auto)
    @State private var appearanceSettings = AppearanceSettings.shared

    @State private var initializer = AppInitializer()
    @State private var connectionBannerKind: ConnectionToastPolicy.Kind?
    @State private var isRegisteringPush = false

    // Onboarding state — owned per-launch; survives across the sheet
    // because @State preserves its initial value for the lifetime of
    // the App. Once `onboardingComplete` flips to true the sheet is
    // dismissed and the session list remains mounted.
    @State private var onboardingState = OnboardingState()
    @State private var isOnboardingSheetPresented = false
    @State private var onboardingDetent: PresentationDetent = OnboardingSheetPresentation.initialDetent
    @State private var onboardingAllowsDismiss = false
    @State private var onboardingSuppressed = false

    /// Device-local first-run completion truth. This root owns persistence
    /// because it also owns sheet presentation, dismissibility, and push startup.
    @AppStorage(ProductionAppStorageKeys.onboardingComplete) private var onboardingComplete: Bool = false

    @Environment(\.scenePhase) private var scenePhase

    // Deep link navigation state
    @State private var deepLinkSessionId: String?
    @State private var deepLinkScrollTarget: ScrollTarget?

    init(container: DependencyContainer = DependencyContainer()) {
        _container = State(initialValue: container)
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--tron-ui-test-onboarding-complete") {
            UserDefaults.standard.set(true, forKey: ProductionAppStorageKeys.onboardingComplete)
        } else if ProcessInfo.processInfo.arguments.contains("--tron-ui-test-onboarding-incomplete") {
            UserDefaults.standard.set(false, forKey: ProductionAppStorageKeys.onboardingComplete)
        }
#endif
        TronFontLoader.registerFonts()

        // Register all event plugins for the new event system
        EventRegistry.shared.registerAll()
    }

    var body: some View {
        rootContent()
            .preferredColorScheme(appearanceSettings.mode.colorScheme)
            .scrollEdgeEffectStyle(.soft, for: .all)
            .task {
                await initializeApp()
            }
            .onChange(of: container.pushNotificationService.deviceToken, initial: true) { _, token in
                guard let token else { return }
                Task { await registerDeviceToken(token) }
            }
            .onChange(of: container.engineClient.connectionState) { oldState, newState in
                handleConnectionBannerTransition(to: newState)
                container.clientLogIngestionService.handleConnectionChange(from: oldState, to: newState)
                if newState.isConnected && !oldState.isConnected && onboardingComplete {
                    Task { await registerPushIfAuthorized() }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .navigateToSession)) { notification in
                container.deepLinkRouter.handle(notificationPayload: notification.userInfo ?? [:])
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
                case .share:
                    NotificationCenter.default.post(name: .pendingShareContent, object: nil)
                    TronLogger.shared.info("Deep link to share", category: .notification)
                }
            }
            .onChange(of: scenePhase) { oldPhase, newPhase in
                let isBackground = newPhase != .active
                container.setBackgroundState(isBackground)
                container.clientLogIngestionService.handleScenePhaseChange(isActive: newPhase == .active)

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
                        await recoverForegroundConnection()
                        if container.engineClient.connectionState.isConnected && onboardingComplete {
                            await registerPushIfAuthorized()
                        }

                        // Handle reconnection based on current connection state.
                        // Session-list refresh is requested unconditionally — the central
                        // SessionRefreshService coalesces and defers to reconnect if offline.
                        container.eventStoreManager.requestSessionRefresh(reason: .foreground)
                    }
                }
            }
    }

    // MARK: - Content builder

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

    @ViewBuilder
    private func readyContent() -> some View {
        sessionListContent
            .sheet(isPresented: $isOnboardingSheetPresented) {
                OnboardingFlowView(
                    state: onboardingState,
                    dependencies: container,
                    selectedDetent: $onboardingDetent,
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
                .adaptivePresentationDetents(OnboardingSheetPresentation.detents, selection: $onboardingDetent, ipadSizing: .compactForm, phoneBackground: .clear)
                .presentationContentInteraction(.resizes)
                .interactiveDismissDisabled(!onboardingComplete && !onboardingAllowsDismiss)
            }
            .onAppear(perform: syncOnboardingSheetPresentation)
            .onChange(of: onboardingComplete) { _, isComplete in
                syncOnboardingSheetPresentation()
            }
            .onReceive(NotificationCenter.default.publisher(for: .startServerOnboarding)) { notification in
                launchServerOnboarding(notification: notification)
            }
    }

    private var sessionListContent: some View {
        ContentView(
            deepLinkSessionId: $deepLinkSessionId,
            deepLinkScrollTarget: $deepLinkScrollTarget
        )
        .environment(\.dependencies, container)
        .environment(\.interactionPolicy, container.interactionPolicy)
        .withErrorHandler()
        .withToastBanner()
    }

    private func syncOnboardingSheetPresentation() {
        let shouldPresent = OnboardingSheetPresentation.shouldAutoPresent(
            onboardingComplete: onboardingComplete,
            onboardingSuppressed: onboardingSuppressed
        )
        if shouldPresent && !isOnboardingSheetPresented {
            presentOnboarding(.firstRun) {
                onboardingState.prepareFirstRunOnboarding()
            }
            return
        }
        if !shouldPresent {
            isOnboardingSheetPresented = false
            return
        }
    }

    private func dismissOnboardingFromSettings() {
        onboardingSuppressed = !onboardingComplete
        onboardingAllowsDismiss = false
        isOnboardingSheetPresented = false
    }

    private func presentOnboarding(
        _ source: OnboardingLaunchSource,
        prepare: () -> Void
    ) {
        prepare()
        onboardingSuppressed = false
        onboardingAllowsDismiss = source.allowsDismiss(onboardingComplete: onboardingComplete)
        onboardingDetent = OnboardingSheetPresentation.initialDetent
        isOnboardingSheetPresented = true
    }

    private func launchServerOnboarding(notification: Notification) {
        let serverId = notification.userInfo?[ServerOnboardingLauncher.serverIdUserInfoKey] as? String
        let server = serverId.flatMap { id in
            container.pairedServerStore.servers.first { $0.id == id }
        }

        presentOnboarding(.serverSettings) {
            onboardingState.prepareServerOnboarding(prefill: server)
        }
    }

    @discardableResult
    private func handlePairingURL(_ url: URL) -> Bool {
        guard case .success(let payload) = PairingURLParser.parse(url.absoluteString) else {
            return false
        }
        presentOnboarding(.pairingURL) {
            onboardingState.acceptPairingPayload(payload)
        }
        return true
    }

    // MARK: - Initialization

    private func initializeApp() async {
        await initializer.initialize {
            try await container.initialize()
        }
        if container.engineClient.connectionState.isConnected && onboardingComplete {
            await registerPushIfAuthorized()
        }
    }

    private func registerPushIfAuthorized() async {
        guard !isRegisteringPush else { return }
        isRegisteringPush = true
        defer { isRegisteringPush = false }
        await container.pushNotificationService.registerAfterPairing()
        if let token = container.pushNotificationService.deviceToken {
            await registerDeviceToken(token)
        }
    }

    private func registerDeviceToken(_ token: String) async {
        guard container.engineClient.connectionState.isConnected else { return }
        do {
            let result = try await container.engineClient.system.registerDeviceToken(token)
            TronLogger.shared.info(
                "Device registration completed: status=\(result.status) transport=\(result.liveApnsEnabled)",
                category: .notification
            )
        } catch {
            TronLogger.shared.error(
                "Device registration failed: \(error.localizedDescription)",
                category: .notification
            )
        }
    }

    private func handleConnectionBannerTransition(to state: ConnectionState) {
        let hasActiveServer = container.pairedServerStore.activeServer != nil
        if ConnectionToastPolicy.shouldDismiss(for: state, hasActiveServer: hasActiveServer) {
            connectionBannerKind = nil
            ToastCenter.shared.dismiss(dedupKey: ConnectionToastPolicy.dedupKey)
            return
        }

        guard let presentation = ConnectionToastPolicy.presentation(
            for: state,
            hasActiveServer: hasActiveServer
        ) else {
            connectionBannerKind = nil
            ToastCenter.shared.dismiss(dedupKey: ConnectionToastPolicy.dedupKey)
            return
        }

        guard connectionBannerKind != presentation.kind else { return }
        connectionBannerKind = presentation.kind

        let retryHandler: (@MainActor () async -> Void)?
        if presentation.includesRetry {
            let container = container
            retryHandler = {
                await container.manualRetry()
            }
        } else {
            retryHandler = nil
        }

        ToastCenter.shared.push(
            presentation.message,
            severity: presentation.severity,
            dedupKey: ConnectionToastPolicy.dedupKey,
            duplicatePolicy: .replace,
            autoDismiss: presentation.autoDismiss,
            retryHandler: retryHandler
        )
    }

    private func recoverForegroundConnection() async {
        switch container.engineClient.connectionState {
        case .connected:
            // Verify the connection before any foreground engine protocol refresh. A Mac
            // sleep can leave URLSession's WebSocket half-open; without this,
            // notification/session refreshes wait on stale server timeouts
            // before the UI sees the disconnected state.
            let isAlive = await container.verifyConnection()
            if !isAlive {
                TronLogger.shared.info("Connection dead on foreground return - retrying", category: .engine)
                await container.manualRetry()
            }
        case .deployRestarting:
            // Server restart flow owns its own reconnect budget — don't interfere.
            TronLogger.shared.debug("Deploy-restart reconnect in progress on foreground return", category: .engine)
        case .disconnected, .failed, .connecting, .reconnecting:
            // Any non-connected/non-deploy state on foreground return is
            // treated as "kick a fresh retry". This covers the case where
            // the reconnect Task was paused during backgrounding and the
            // state is stale; manualRetry() resets the attempt counter and
            // cancels any lingering task before spawning a new one.
            TronLogger.shared.info("Triggering manualRetry on foreground return (state: \(container.engineClient.connectionState))", category: .engine)
            await container.manualRetry()
        case .unauthorized:
            // .unauthorized is a parked state — auto-retrying on foreground
            // would just re-trigger 401. The user must tap the pill (or open
            // the re-pair sheet) to provide a fresh token first; only then
            // does manualRetry fire.
            TronLogger.shared.info("Skipping foreground auto-retry while unauthorized — awaiting user re-pair", category: .engine)
        }
    }
}
