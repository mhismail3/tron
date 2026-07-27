import Foundation
import Observation
import UIKit
import UserNotifications

enum NativeNotificationPermissionPolicy {
    static func shouldRequest(
        hasAuthenticatedConnection: Bool,
        attemptedThisLaunch: Bool,
        status: NotificationAuthorizationState
    ) -> Bool {
        hasAuthenticatedConnection && !attemptedThisLaunch && status == .notDetermined
    }

    static func permitsRemoteRegistration(_ status: NotificationAuthorizationState) -> Bool {
        [.authorized, .provisional, .ephemeral].contains(status)
    }
}

struct NotificationServerReadiness: Codable, Equatable, Identifiable, Sendable {
    let serverId: String
    var ready: Bool
    var deviceReady: Bool?
    var transportMode: NotificationTransportMode?
    var transportConfigured: Bool?
    var transportProblem: String?
    var authorizationStatus: NotificationAuthorizationState
    var registeredAt: String?
    var problem: String?

    var id: String { serverId }
}

struct NotificationInboxItem: Codable, Equatable, Identifiable, Sendable {
    let serverId: String
    var delivery: NotificationDeliveryDTO

    var id: String { "\(serverId):\(delivery.deliveryId)" }
}

struct NotificationMutation: Codable, Equatable, Identifiable, Sendable {
    let mutationId: String
    let serverId: String
    let deliveryId: String
    let acknowledgement: NotificationAcknowledgement
    let occurredAt: String

    var id: String { mutationId }
}

/// App-private durable cache and mutation outbox. APNs tokens are deliberately
/// absent: Apple owns token persistence and the coordinator keeps only the
/// current process token in memory.
struct NotificationLocalStore {
    private enum Key {
        static let installationId = "nativeNotifications.installationId"
        static let inbox = "nativeNotifications.inbox.v1"
        static let outbox = "nativeNotifications.outbox.v1"
        static let readiness = "nativeNotifications.readiness.v1"
    }

    let defaults: UserDefaults

    var installationId: String {
        if let existing = defaults.string(forKey: Key.installationId), !existing.isEmpty {
            return existing
        }
        let created = UUID().uuidString.lowercased()
        defaults.set(created, forKey: Key.installationId)
        return created
    }

    func loadInbox() -> [NotificationInboxItem] {
        decode([NotificationInboxItem].self, key: Key.inbox) ?? []
    }

    func saveInbox(_ value: [NotificationInboxItem]) {
        encode(value, key: Key.inbox)
    }

    func loadOutbox() -> [NotificationMutation] {
        decode([NotificationMutation].self, key: Key.outbox) ?? []
    }

    func saveOutbox(_ value: [NotificationMutation]) {
        encode(value, key: Key.outbox)
    }

    func loadReadiness() -> [NotificationServerReadiness] {
        decode([NotificationServerReadiness].self, key: Key.readiness) ?? []
    }

    func saveReadiness(_ value: [NotificationServerReadiness]) {
        encode(value, key: Key.readiness)
    }

    private func decode<T: Decodable>(_ type: T.Type, key: String) -> T? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }

    private func encode<T: Encodable>(_ value: T, key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }
}

@Observable
@MainActor
final class NativeNotificationCoordinator {
    nonisolated static let quietRefreshWaitBudget: Duration = .seconds(8)
    typealias ServersProvider = @MainActor () -> [PairedServer]
    typealias ActiveServerProvider = @MainActor () -> PairedServer?
    typealias ActiveClientProvider = @MainActor () -> EngineClient
    typealias TokenProvider = @MainActor (String) -> String?

    private let runtimeMode: AppRuntimeMode
    private let localStore: NotificationLocalStore
    private let serversProvider: ServersProvider
    private let activeServerProvider: ActiveServerProvider
    private let activeClientProvider: ActiveClientProvider
    private let tokenProvider: TokenProvider
    private let notificationCenter: UNUserNotificationCenter
    private var currentDeviceToken: String?
    private var outbox: [NotificationMutation]
    private var startedForCurrentLaunch = false
    private var authenticatedThisLaunch = false
    private var permissionRequestAttempted = false
    private var registrationTask: Task<Void, Never>?
    private var syncTask: Task<Void, Never>?
    private var registrationRequested = false
    private var pendingSyncServerIds: Set<String> = []
    private var badgeTask: Task<Void, Never>?

    private(set) var authorizationStatus: NotificationAuthorizationState = .notDetermined
    private(set) var inbox: [NotificationInboxItem]
    private(set) var readiness: [NotificationServerReadiness]
    private(set) var remoteRegistrationProblem: String?

    init(
        defaults: UserDefaults,
        runtimeMode: AppRuntimeMode = .current,
        notificationCenter: UNUserNotificationCenter = .current(),
        servers: @escaping ServersProvider,
        activeServer: @escaping ActiveServerProvider,
        activeClient: @escaping ActiveClientProvider,
        token: @escaping TokenProvider
    ) {
        self.runtimeMode = runtimeMode
        localStore = NotificationLocalStore(defaults: defaults)
        serversProvider = servers
        activeServerProvider = activeServer
        activeClientProvider = activeClient
        tokenProvider = token
        self.notificationCenter = notificationCenter
        inbox = localStore.loadInbox()
        outbox = localStore.loadOutbox()
        readiness = localStore.loadReadiness()
    }

    var installationId: String { localStore.installationId }
    var aggregateUnreadCount: Int { inbox.reduce(into: 0) { $0 += $1.delivery.isUnread ? 1 : 0 } }

    func attachLifecycle() {
        guard runtimeMode.runsApplicationLifecycle else { return }
        NotificationLifecycleBridge.shared.attach(self)
    }

    /// Begin notification ownership without using engine connectivity as a
    /// gate. Existing authorization registers with Apple immediately; the
    /// first permission prompt remains gated by authenticated pairing.
    func launch() {
        guard runtimeMode.runsApplicationLifecycle, !startedForCurrentLaunch else { return }
        startedForCurrentLaunch = true
        attachLifecycle()
        Task {
            await refreshAuthorizationStatus()
            if NativeNotificationPermissionPolicy.permitsRemoteRegistration(authorizationStatus) {
                UIApplication.shared.registerForRemoteNotifications()
            }
            scheduleRegistration()
            scheduleSync()
        }
    }

    /// Called only after an authenticated engine connection succeeds. This is
    /// the one permission-request boundary for a launch.
    func connectionDidAuthenticate() {
        guard runtimeMode.runsApplicationLifecycle else { return }
        launch()
        authenticatedThisLaunch = true
        Task { await establishSystemAuthorization() }
    }

    func pairedServersDidChange() {
        guard startedForCurrentLaunch else { return }
        scheduleRegistration()
        scheduleSync()
    }

    func foregrounded() {
        guard startedForCurrentLaunch else { return }
        Task {
            await refreshAuthorizationStatus()
            if NativeNotificationPermissionPolicy.permitsRemoteRegistration(authorizationStatus) {
                UIApplication.shared.registerForRemoteNotifications()
            }
            scheduleRegistration()
            scheduleSync()
        }
    }

    func didReceiveDeviceToken(_ data: Data) {
        currentDeviceToken = data.map { String(format: "%02x", $0) }.joined()
        remoteRegistrationProblem = nil
        scheduleRegistration()
    }

    func didFailRemoteRegistration(_ error: Error) {
        remoteRegistrationProblem = error.localizedDescription
    }

    func handleNotificationResponse(
        serverId: String,
        deliveryId: String,
        acknowledgement: NotificationAcknowledgement
    ) {
        enqueue(
            acknowledgement,
            serverId: serverId,
            deliveryId: deliveryId
        )
        if acknowledgement == .opened {
            routeToNotification(serverId: serverId, deliveryId: deliveryId)
        }
    }

    func handleQuietRefresh(_ payload: [AnyHashable: Any]) async -> Bool {
        guard let serverId = Self.serverId(from: payload) else { return false }
        let previous = inbox
        scheduleSync(serverIds: [serverId])
        let deadline = ContinuousClock.now + Self.quietRefreshWaitBudget
        while syncTask != nil, ContinuousClock.now < deadline {
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                break
            }
        }
        return previous != inbox
    }

    func acknowledge(
        _ acknowledgement: NotificationAcknowledgement,
        item: NotificationInboxItem
    ) {
        enqueue(
            acknowledgement,
            serverId: item.serverId,
            deliveryId: item.delivery.deliveryId
        )
    }

    func clearAllUnread() {
        let now = ISO8601DateFormatter().string(from: Date())
        let mutations = inbox.compactMap { item -> NotificationMutation? in
            guard item.delivery.isUnread else { return nil }
            return NotificationMutation(
                mutationId: UUID().uuidString.lowercased(),
                serverId: item.serverId,
                deliveryId: item.delivery.deliveryId,
                acknowledgement: .clearUnread,
                occurredAt: now
            )
        }
        enqueue(mutations)
    }

    func synchronizeNow() {
        scheduleSync()
    }

    private func establishSystemAuthorization() async {
        await refreshAuthorizationStatus()
        if NativeNotificationPermissionPolicy.shouldRequest(
            hasAuthenticatedConnection: authenticatedThisLaunch,
            attemptedThisLaunch: permissionRequestAttempted,
            status: authorizationStatus
        ) {
            permissionRequestAttempted = true
            do {
                _ = try await notificationCenter.requestAuthorization(options: [.alert, .badge, .sound])
            } catch {
                remoteRegistrationProblem = error.localizedDescription
            }
            await refreshAuthorizationStatus()
        }
        if NativeNotificationPermissionPolicy.permitsRemoteRegistration(authorizationStatus) {
            UIApplication.shared.registerForRemoteNotifications()
        }
        scheduleRegistration()
        scheduleSync()
    }

    private func refreshAuthorizationStatus() async {
        let settings = await notificationCenter.notificationSettings()
        authorizationStatus = Self.authorizationState(settings.authorizationStatus)
    }

    private func scheduleRegistration() {
        registrationRequested = true
        guard registrationTask == nil else { return }
        registrationTask = Task { @MainActor [weak self] in
            await self?.drainRegistrationRequests()
        }
    }

    private func drainRegistrationRequests() async {
        while registrationRequested, !Task.isCancelled {
            registrationRequested = false
            await registerWithAllPairedServers()
        }
        registrationTask = nil
        if registrationRequested {
            scheduleRegistration()
        }
    }

    private func scheduleSync(serverIds: [String]? = nil) {
        pendingSyncServerIds.formUnion(serverIds ?? serversProvider().map(\.id))
        guard syncTask == nil else { return }
        syncTask = Task { @MainActor [weak self] in
            await self?.drainSyncRequests()
        }
    }

    private func drainSyncRequests() async {
        while !pendingSyncServerIds.isEmpty, !Task.isCancelled {
            let serverIds = pendingSyncServerIds
            pendingSyncServerIds.removeAll()
            await synchronizeServers(serverIds: serverIds)
        }
        syncTask = nil
        if !pendingSyncServerIds.isEmpty {
            scheduleSync(serverIds: Array(pendingSyncServerIds))
        }
    }

    private func registerWithAllPairedServers() async {
        let servers = serversProvider()
        let topic = Bundle.main.bundleIdentifier ?? ""
        guard !topic.isEmpty else {
            remoteRegistrationProblem = "The application push topic is unavailable."
            return
        }
        for server in servers {
            guard !Task.isCancelled else { return }
            let token = NativeNotificationPermissionPolicy.permitsRemoteRegistration(authorizationStatus)
                ? currentDeviceToken
                : nil
            do {
                let registration = try await withClient(for: server) { client in
                    try await client.notifications.upsertDevice(
                        NotificationDeviceUpsertDTO(
                            installationId: installationId,
                            clientServerId: server.id,
                            topic: topic,
                            environment: Self.apnsEnvironment,
                            authorizationStatus: authorizationStatus,
                            token: token
                        ),
                        idempotencyKey: .userAction(
                            "notification.device.upsert.\(server.id)"
                        )
                    )
                }
                setReadiness(
                    NotificationServerReadiness(
                        serverId: server.id,
                        ready: registration.ready && registration.transport.configured,
                        deviceReady: registration.ready,
                        transportMode: registration.transport.mode,
                        transportConfigured: registration.transport.configured,
                        transportProblem: registration.transport.problemCode,
                        authorizationStatus: registration.authorizationStatus,
                        registeredAt: registration.registeredAt,
                        problem: nil
                    )
                )
            } catch {
                setReadiness(
                    NotificationServerReadiness(
                        serverId: server.id,
                        ready: false,
                        deviceReady: nil,
                        transportMode: nil,
                        transportConfigured: nil,
                        transportProblem: nil,
                        authorizationStatus: authorizationStatus,
                        registeredAt: readiness.first { $0.serverId == server.id }?.registeredAt,
                        problem: error.localizedDescription
                    )
                )
            }
        }
    }

    private func enqueue(
        _ acknowledgement: NotificationAcknowledgement,
        serverId: String,
        deliveryId: String
    ) {
        let now = ISO8601DateFormatter().string(from: Date())
        let mutation = NotificationMutation(
            mutationId: UUID().uuidString.lowercased(),
            serverId: serverId,
            deliveryId: deliveryId,
            acknowledgement: acknowledgement,
            occurredAt: now
        )
        enqueue([mutation])
    }

    private func enqueue(_ mutations: [NotificationMutation]) {
        guard !mutations.isEmpty else { return }
        outbox.append(contentsOf: mutations)
        localStore.saveOutbox(outbox)
        for mutation in mutations {
            optimisticallyApply(mutation)
        }
        persistInboxAndBadge()
        scheduleSync()
    }

    private func optimisticallyApply(_ mutation: NotificationMutation) {
        guard let index = inbox.firstIndex(where: {
            $0.serverId == mutation.serverId && $0.delivery.deliveryId == mutation.deliveryId
        }) else { return }
        inbox[index].delivery.readAt = inbox[index].delivery.readAt ?? mutation.occurredAt
        if mutation.acknowledgement != .clearUnread {
            inbox[index].delivery.terminalResponse = mutation.acknowledgement.rawValue
            inbox[index].delivery.terminalRespondedAt = mutation.occurredAt
        }
    }

    /// Flush each server's durable mutation batch and read its authoritative
    /// inbox over one client lifetime. Inactive paired servers therefore open
    /// at most one short-lived socket per coalesced synchronization pass.
    private func synchronizeServers(serverIds: Set<String>) async {
        let pendingOutbox = outbox
        let targetIds = serverIds.union(pendingOutbox.map(\.serverId))
        var acknowledgedMutationIds = Set<String>()
        var synchronizedDeliveries: [String: [NotificationDeliveryDTO]] = [:]

        for server in serversProvider() where targetIds.contains(server.id) {
            guard !Task.isCancelled else { return }
            let mutations = pendingOutbox.filter { $0.serverId == server.id }
            do {
                try await withClient(for: server) { client in
                    for mutation in mutations {
                        guard !Task.isCancelled else { throw CancellationError() }
                        do {
                            _ = try await client.notifications.acknowledge(
                                NotificationAcknowledgeDTO(
                                    deliveryId: mutation.deliveryId,
                                    installationId: installationId,
                                    clientMutationId: mutation.mutationId,
                                    acknowledgement: mutation.acknowledgement,
                                    occurredAt: mutation.occurredAt
                                ),
                                idempotencyKey: EngineIdempotencyKey(
                                    rawValue: mutation.mutationId
                                )
                            )
                            acknowledgedMutationIds.insert(mutation.mutationId)
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            // Keep this mutation in the durable outbox while
                            // allowing later idempotent mutations to proceed.
                        }
                    }
                    if serverIds.contains(server.id) {
                        let page = try await client.notifications.deliveries(limit: 200)
                        synchronizedDeliveries[server.id] = page.deliveries
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                // Durable mutations and the previous inbox remain intact.
            }
        }

        if !acknowledgedMutationIds.isEmpty {
            outbox.removeAll { acknowledgedMutationIds.contains($0.mutationId) }
            localStore.saveOutbox(outbox)
        }

        for (serverId, deliveries) in synchronizedDeliveries {
            inbox.removeAll { $0.serverId == serverId }
            inbox.append(contentsOf: deliveries.map {
                NotificationInboxItem(serverId: serverId, delivery: $0)
            })
        }
        if !synchronizedDeliveries.isEmpty {
            inbox.sort { lhs, rhs in lhs.delivery.createdAt > rhs.delivery.createdAt }
            persistInboxAndBadge()
        }
    }

    private func withClient<T>(
        for server: PairedServer,
        operation: (EngineClient) async throws -> T
    ) async throws -> T {
        if activeServerProvider()?.id == server.id {
            let client = activeClientProvider()
            guard client.connectionState.isConnected else {
                throw EngineClientError.connectionNotEstablished
            }
            return try await operation(client)
        }
        guard let bearerToken = tokenProvider(server.id),
              let url = URL(string: "ws://\(server.host):\(server.port)/engine")
        else {
            throw EngineClientError.connectionNotEstablished
        }
        let client = EngineClient(
            serverURL: url,
            bearerTokenProvider: { bearerToken }
        )
        await client.connect()
        guard client.connectionState.isConnected else {
            client.disconnect()
            throw EngineClientError.connectionNotEstablished
        }
        defer { client.disconnect() }
        return try await operation(client)
    }

    private func setReadiness(_ value: NotificationServerReadiness) {
        readiness.removeAll { $0.serverId == value.serverId }
        readiness.append(value)
        readiness.sort { $0.serverId < $1.serverId }
        localStore.saveReadiness(readiness)
    }

    private func persistInboxAndBadge() {
        localStore.saveInbox(inbox)
        guard runtimeMode.runsApplicationLifecycle else { return }
        let unreadCount = aggregateUnreadCount
        badgeTask?.cancel()
        badgeTask = Task {
            try? await UNUserNotificationCenter.current().setBadgeCount(unreadCount)
        }
    }

    private func routeToNotification(serverId: String, deliveryId: String) {
        NotificationCenter.default.post(
            name: .openNotificationDelivery,
            object: nil,
            userInfo: ["serverId": serverId, "deliveryId": deliveryId]
        )
    }

    private static var apnsEnvironment: NotificationAPNSEnvironment {
        apnsEnvironment(
            configuredValue: Bundle.main.object(
                forInfoDictionaryKey: "TRONAPNSEnvironment"
            ) as? String
        )
    }

    nonisolated static func apnsEnvironment(
        configuredValue: String?
    ) -> NotificationAPNSEnvironment {
        switch configuredValue {
        case NotificationAPNSEnvironment.sandbox.rawValue:
            return .sandbox
        case NotificationAPNSEnvironment.production.rawValue:
            return .production
        default:
#if BETA
            return .sandbox
#else
            return .production
#endif
        }
    }

    private static func authorizationState(
        _ status: UNAuthorizationStatus
    ) -> NotificationAuthorizationState {
        switch status {
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .authorized: .authorized
        case .provisional: .provisional
        case .ephemeral: .ephemeral
        @unknown default: .denied
        }
    }

    private static func serverId(from payload: [AnyHashable: Any]) -> String? {
        (payload["tron"] as? [String: Any])?["serverId"] as? String
    }
}

extension Notification.Name {
    static let openNotificationDelivery = Notification.Name("tron.openNotificationDelivery")
}
