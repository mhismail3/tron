import Network
import SwiftUI
import TronMobileCore

/// The app's network path observer. `ProductionSceneOwner` creates it lazily, so
/// a composition that never renders the production scene starts no path monitor.
@MainActor
final class GatewayPathDiagnosticsObserver {
    private let monitor = NWPathMonitor()
    private let delivery = GatewayPathDiagnosticCoalescer()
    private let lanPermission = GatewayLanPermissionRecord()
    private let record: @MainActor @Sendable (String) -> Void
    private let pathHint: @MainActor @Sendable (Bool, String?) -> Void

    init(model: AppModel) {
        record = { [weak model] in model?.lifecycleRecordDiagnostic(event: "path.changed", message: $0) }
        pathHint = { [weak model] satisfied, signature in
            model?.lifecycleNotePathHint(satisfied: satisfied, signature: signature)
        }
        let lanPermission = self.lanPermission
        monitor.pathUpdateHandler = { [delivery, record, pathHint, lanPermission] path in
            GatewayNetworkPathSnapshot.shared.update(interfaces: Self.interfaces(path))
            lanPermission.update(systemDenied: Self.localNetworkDenied(path))
            Task { @MainActor in pathHint(path.status == .satisfied, Self.routeSignature(path)) }
            Self.offer(Self.facts(path), delivery: delivery, record: record)
        }
        monitor.start(queue: DispatchQueue(label: "tron.gateway.path-monitor"))
    }

    func setSceneActive(_ active: Bool) {
        delivery.setActive(active)
        if active {
            // The scene activation re-reads the same path: it forwards that
            // reading's signature so it cannot pass as a route change (C-3).
            let path = monitor.currentPath
            lanPermission.update(systemDenied: Self.localNetworkDenied(path))
            pathHint(path.status == .satisfied, Self.routeSignature(path))
            Self.offer(Self.facts(path), delivery: delivery, record: record)
        }
    }

    /// The system's own report that this install may not reach the local
    /// network (E-3c). The LAN lane reads it; nothing else in the app treats a
    /// denied permission as an outage.
    private nonisolated static func localNetworkDenied(_ path: NWPath) -> Bool {
        path.unsatisfiedReason == .localNetworkDenied
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
        return "status=\(status) interfaces=\(interfaces(path)) expensive=\(path.isExpensive) constrained=\(path.isConstrained)"
    }

    private nonisolated static func interfaces(_ path: NWPath) -> String {
        let interfaces: [(NWInterface.InterfaceType, String)] = [
            (.wifi, "wifi"), (.cellular, "cellular"), (.wiredEthernet, "wired"), (.loopback, "loopback"), (.other, "other")
        ]
        let used = interfaces.filter { path.usesInterfaceType($0.0) }.map(\.1).joined(separator: ",")
        return used.isEmpty ? "unknown" : used
    }

    /// What the lifecycle reads as a route's identity: the interfaces this path
    /// uses. A status, flag or cost-only update — and a scene activation
    /// re-reading the same path — keeps this the same, so it cannot read as a
    /// path change and restart a grown backoff (C-3).
    private nonisolated static func routeSignature(_ path: NWPath) -> String {
        interfaces(path)
    }

    deinit {
        delivery.setActive(false)
        monitor.cancel()
    }
}

/// The one owner of the production scene's lifecycle composition.
///
/// The shipping app and the hosted test app's no-fixture arm both build this
/// owner and render `ProductionSceneRoot`, so the scene a real-UI journey drives
/// is the scene the user runs: scene-phase transitions, pairing invitations and
/// shared links, path diagnostics, background checkpoints, connection-state
/// logging and push reconciliation. The hosted fixture arms keep their own
/// views and never build this owner.
///
/// The model is injected, so each arm keeps the construction its configuration
/// owns: the shipping app composes incident retention (the persisted client
/// diagnostic store and the notification inbox) and the hosted test app stays
/// memory-only, as it is composed today.
/// `ObservableObject` is what lets `@StateObject` create this owner exactly once
/// for the hosted no-fixture arm; nothing here publishes a change.
@MainActor
final class ProductionSceneOwner: ObservableObject {
    let model: AppModel
    let appearance = AppearanceSettings.shared
    let backgroundCheckpoints = AppBackgroundCheckpointCoordinator()
    let pushNotifications = PushNotificationCoordinator()
    let pendingShares = UserDefaultsPendingShareStore()
    /// Created with the owner, before the scene's first `.task`, as the shipping
    /// app created it in its own `init`: the monitor's first update lands before
    /// `setSceneActive` reads the current path.
    let pathDiagnostics: GatewayPathDiagnosticsObserver

    init(model: AppModel) {
        self.model = model
        pathDiagnostics = GatewayPathDiagnosticsObserver(model: model)
    }
}

/// The production scene: the shipping app's window content and the lifecycle
/// modifiers that drive it.
///
/// `pushDelegate` is the composition's one injected dependency: push
/// registration is driven by the app's `UIApplicationDelegateAdaptor`
/// (`AppDelegate`), and the shipping app passes its own. The adaptor is declared
/// on the `App`, so installing it for the hosted app would install it for every
/// hosted arm - the fixture arms included, which stay inert; they pass `nil` and
/// still run every other production modifier.
struct ProductionSceneRoot: View {
    let owner: ProductionSceneOwner
    let pushDelegate: AppDelegate?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        SceneRootView(
            model: owner.model,
            colorScheme: owner.appearance.mode.colorScheme
        )
            .environment(owner.model)
            .environment(owner.pushNotifications)
            .tronPresentation()
            .preferredColorScheme(owner.appearance.mode.colorScheme)
            .task {
                owner.pathDiagnostics.setSceneActive(scenePhase == .active)
                configurePushNotifications()
                await RetiredNotificationBadge.clear()
                await owner.model.start(scenePhase: appScenePhase(scenePhase))
                await reconcilePushNotifications()
            }
            .onChange(of: owner.model.connectionState) { old, new in
                Task {
                    await owner.model.appLog.recordCausal(
                        name: "connection.state-changed", outcome: String(describing: new),
                        connectionID: owner.model.diagnosticConnectionID,
                        details: "old=\(old) new=\(new) gatewayEpoch=\(owner.model.gatewayInfo?.runtimeEpoch ?? "unknown")"
                    )
                    await reconcilePushNotifications()
                }
            }
            .onChange(of: owner.model.profileRevision) { _, _ in
                Task { await reconcilePushNotifications() }
            }
            .onChange(of: owner.pushNotifications.readiness) { _, readiness in
                owner.model.pushNotificationReadiness = readiness
                owner.model.pushRegistrationDiagnostic = owner.pushNotifications.diagnostic
            }
            .onChange(of: owner.pushNotifications.diagnostic) { _, diagnostic in
                owner.model.pushRegistrationDiagnostic = diagnostic
            }
            .onOpenURL { url in
                if let invitation = PairingInvitationParser.parse(url) {
                    Task {
                        do { try await owner.model.pair(invitation) }
                        catch is CancellationError { return }
                        catch { owner.model.presentError(error) }
                    }
                } else if url.host == "share",
                          let shared = owner.pendingShares.load()?.buildSharePrompt(),
                          let target = owner.model.mountedPresentationTarget {
                    Task {
                        do {
                            try await owner.model.sendSharedContent(shared.prompt, target: target)
                            owner.pendingShares.clear()
                        } catch is CancellationError {
                            return
                        } catch {
                            owner.model.presentError(error)
                        }
                    }
                }
            }
            .onChange(of: scenePhase) { _, phase in
                switch appScenePhase(phase) {
                case .active:
                    owner.pathDiagnostics.setSceneActive(true)
                    Task {
                        await RetiredNotificationBadge.clear()
                        await reconcilePushNotifications()
                    }
                    owner.model.becameActive()
                case .inactive:
                    owner.pathDiagnostics.setSceneActive(false)
                    owner.model.becameInactive()
                case .background:
                    owner.pathDiagnostics.setSceneActive(false)
                    owner.backgroundCheckpoints.retain(owner.model.enteredBackground())
                }
            }
    }

    @MainActor
    private func configurePushNotifications() {
        guard let pushDelegate else { return }
        pushDelegate.onDeviceToken = { [pushNotifications = owner.pushNotifications] token in
            pushNotifications.receiveDeviceToken(token)
        }
        pushDelegate.onRegistrationFailure = { [pushNotifications = owner.pushNotifications] in
            pushNotifications.receiveRegistrationFailure()
        }
        pushDelegate.installNotificationTapHandler { [model = owner.model] tap in
            model.requestPushNavigation(tap)
        }
    }

    @MainActor
    private func appScenePhase(_ phase: ScenePhase) -> AppModel.AppScenePhase {
        switch phase {
        case .active: .active
        case .inactive: .inactive
        case .background: .background
        @unknown default: .inactive
        }
    }

    @MainActor
    private func reconcilePushNotifications() async {
        await owner.pushNotifications.reconcile(
            profile: owner.model.profiles.selected,
            connected: owner.model.connectionState == .connected,
            gatewayRuntimeEpoch: owner.model.gatewayInfo?.runtimeEpoch,
            pushRegistrationRevision: owner.model.gatewayInfo?.pushRegistrationRevision,
            client: owner.model.client
        )
        owner.model.pushNotificationReadiness = owner.pushNotifications.readiness
        owner.model.pushRegistrationDiagnostic = owner.pushNotifications.diagnostic
    }
}
