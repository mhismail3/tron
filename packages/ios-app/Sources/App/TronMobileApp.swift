import Network
import SwiftUI

@MainActor
private final class GatewayPathDiagnosticsObserver {
    private let monitor = NWPathMonitor()
    private let delivery = GatewayPathDiagnosticCoalescer()
    private let record: @MainActor @Sendable (String) -> Void
    private let pathHint: @MainActor @Sendable (Bool) -> Void

    init(model: AppModel) {
        record = { [weak model] in model?.lifecycleRecordDiagnostic(event: "path.changed", message: $0) }
        pathHint = { [weak model] satisfied in model?.lifecycleNotePathHint(satisfied: satisfied) }
        monitor.pathUpdateHandler = { [delivery, record, pathHint] path in
            Task { @MainActor in pathHint(path.status == .satisfied) }
            Self.offer(Self.facts(path), delivery: delivery, record: record)
        }
        monitor.start(queue: DispatchQueue(label: "tron.gateway.path-monitor"))
    }

    func setSceneActive(_ active: Bool) {
        delivery.setActive(active)
        if active {
            pathHint(monitor.currentPath.status == .satisfied)
            Self.offer(Self.facts(monitor.currentPath), delivery: delivery, record: record)
        }
    }

    private nonisolated static func offer(
        _ facts: String, delivery: GatewayPathDiagnosticCoalescer,
        record: @escaping @MainActor @Sendable (String) -> Void
    ) {
        guard delivery.offer(facts) else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            if let message = delivery.take(), !Task.isCancelled { record(message) }
        }
    }

    private nonisolated static func facts(_ path: NWPath) -> String {
        let status: String
        switch path.status {
        case .satisfied: status = "satisfied"
        case .unsatisfied: status = "unsatisfied"
        case .requiresConnection: status = "requires-connection"
        @unknown default: status = "unknown"
        }
        let interfaces: [(NWInterface.InterfaceType, String)] = [
            (.wifi, "wifi"), (.cellular, "cellular"), (.wiredEthernet, "wired"), (.loopback, "loopback"), (.other, "other")
        ]
        let used = interfaces.filter { path.usesInterfaceType($0.0) }.map(\.1).joined(separator: ",")
        return "status=\(status) interfaces=\(used.isEmpty ? "unknown" : used) expensive=\(path.isExpensive) constrained=\(path.isConstrained)"
    }

    deinit {
        delivery.setActive(false)
        monitor.cancel()
    }
}

@main
struct TronMobileApp: App {
    #if HOSTED_TEST
    @State private var hostedModel: AppModel

    init() {
        _hostedModel = State(initialValue: AppModel())
    }

    var body: some Scene {
        WindowGroup {
            if ProcessInfo.processInfo.arguments.contains("-tron-ask-user-fixture") {
                HostedAskUserFixtureView()
            } else if ProcessInfo.processInfo.arguments.contains("-tron-dashboard-menu-fixture") {
                HostedDashboardMenuFixtureView()
            } else if ProcessInfo.processInfo.arguments.contains("-tron-extension-widgets-fixture") {
                HostedExtensionWidgetsFixtureView()
            } else {
                SceneRootView(model: hostedModel, colorScheme: nil)
                    .environment(hostedModel)
                    .tronPresentation()
                    .task { await hostedModel.start(sceneIsActive: true) }
            }
        }
    }
    #else
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    // Incident retention is explicitly composed by the production app owner;
    // tests and scripted clients remain memory-only unless they inject a sink.
    @State private var model: AppModel
    @State private var pathDiagnostics: GatewayPathDiagnosticsObserver
    @State private var appearance = AppearanceSettings.shared
    @State private var backgroundCheckpoints = AppBackgroundCheckpointCoordinator()
    @State private var pushNotifications = PushNotificationCoordinator()
    @Environment(\.scenePhase) private var scenePhase
    private let pendingShares = UserDefaultsPendingShareStore()

    init() {
        let store = IOSClientDiagnosticStore(defaults: .standard)
        let model = AppModel(client: GatewayClient(diagnosticStore: store), diagnosticStore: store,
                             notificationInbox: NotificationInboxCoordinator(defaults: .standard))
        _model = State(initialValue: model)
        _pathDiagnostics = State(initialValue: GatewayPathDiagnosticsObserver(model: model))
    }

    var body: some Scene {
        WindowGroup {
            SceneRootView(
                model: model,
                colorScheme: appearance.mode.colorScheme
            )
                .environment(model)
                .environment(pushNotifications)
                .tronPresentation()
                .preferredColorScheme(appearance.mode.colorScheme)
                .task {
                    pathDiagnostics.setSceneActive(scenePhase == .active)
                    configurePushNotifications()
                    await RetiredNotificationBadge.clear()
                    await model.start(sceneIsActive: scenePhase == .active)
                    await reconcilePushNotifications()
                }
                .onChange(of: model.connectionState) { _, _ in
                    Task { await reconcilePushNotifications() }
                }
                .onChange(of: model.profileRevision) { _, _ in
                    Task { await reconcilePushNotifications() }
                }
                .onChange(of: pushNotifications.readiness) { _, readiness in
                    model.pushNotificationReadiness = readiness
                    model.pushRegistrationDiagnostic = pushNotifications.diagnostic
                }
                .onChange(of: pushNotifications.diagnostic) { _, diagnostic in
                    model.pushRegistrationDiagnostic = diagnostic
                }
                .onOpenURL { url in
                    if let invitation = PairingInvitationParser.parse(url) {
                        Task {
                            do { try await model.pair(invitation) }
                            catch is CancellationError { return }
                            catch { model.presentError(error) }
                        }
                    } else if url.host == "share",
                              let shared = pendingShares.load()?.buildSharePrompt(),
                              let target = model.mountedPresentationTarget {
                        Task {
                            do {
                                try await model.sendSharedContent(shared.prompt, target: target)
                                pendingShares.clear()
                            } catch is CancellationError {
                                return
                            } catch {
                                model.presentError(error)
                            }
                        }
                    }
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        pathDiagnostics.setSceneActive(true)
                        Task {
                            await RetiredNotificationBadge.clear()
                            await reconcilePushNotifications()
                        }
                        model.becameActive()
                    } else if phase == .inactive {
                        pathDiagnostics.setSceneActive(false)
                        model.becameInactive()
                    } else if phase == .background {
                        pathDiagnostics.setSceneActive(false)
                        backgroundCheckpoints.retain(model.enteredBackground())
                    }
                }
        }
    }

    @MainActor
    private func configurePushNotifications() {
        appDelegate.onDeviceToken = { token in
            pushNotifications.receiveDeviceToken(token)
        }
        appDelegate.onRegistrationFailure = {
            pushNotifications.receiveRegistrationFailure()
        }
        appDelegate.installNotificationTapHandler { tap in
            model.requestPushNavigation(tap)
        }
    }

    @MainActor
    private func reconcilePushNotifications() async {
        await pushNotifications.reconcile(
            profile: model.profiles.selected,
            connected: model.connectionState == .connected,
            client: model.client
        )
        model.pushNotificationReadiness = pushNotifications.readiness
        model.pushRegistrationDiagnostic = pushNotifications.diagnostic
    }
    #endif
}

private struct SceneRootView: View {
    let model: AppModel
    let colorScheme: ColorScheme?
    @State private var presentationActivity = PresentationActivityCoordinator()

    var body: some View {
        RootView()
            .background {
                InAppNoticeWindowInstaller(
                    model: model,
                    colorScheme: colorScheme,
                    presentationActivity: presentationActivity
                )
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
            }
            .environment(\.tronPresentationActivityCoordinator, presentationActivity)
    }
}

private struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var onboardingDetent: PresentationDetent = .medium
    @State private var showOnboarding = false

    var body: some View {
        SessionShellView()
        .tronManagedSheet(
            isPresented: $showOnboarding,
            identity: "app.onboarding"
        ) {
            OnboardingView(selectedDetent: $onboardingDetent) {
                showOnboarding = false
            }
                .presentationDetents([.medium, .large], selection: $onboardingDetent)
                .presentationDragIndicator(.hidden)
                .presentationContentInteraction(.resizes)
                .interactiveDismissDisabled()
        }
        .background(Color.tronBackground.ignoresSafeArea())
        .onAppear { syncOnboardingPresentation() }
        .onChange(of: model.connectionState) { _, _ in syncOnboardingPresentation() }
        .onChange(of: model.hasResolvedLaunchState) { _, _ in syncOnboardingPresentation() }
    }

    private func syncOnboardingPresentation() {
        showOnboarding = OnboardingPresentationPolicy.shouldPresent(
            hasResolvedLaunchState: model.hasResolvedLaunchState,
            connectionState: model.connectionState,
            setupComplete: model.setupComplete,
            suppressSetup: model.isAddingServer
        )
    }
}

enum OnboardingPresentationPolicy {
    static func shouldPresent(
        hasResolvedLaunchState: Bool,
        connectionState: AppModel.ConnectionState,
        setupComplete: Bool,
        suppressSetup: Bool = false
    ) -> Bool {
        guard hasResolvedLaunchState, !suppressSetup else { return false }
        return connectionState == .unpaired
            || connectionState == .unauthorized
            || !setupComplete
    }
}
