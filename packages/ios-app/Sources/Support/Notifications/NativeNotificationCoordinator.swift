import Foundation
import Observation
import UIKit
import UserNotifications

@Observable
@MainActor
final class NativeNotificationCoordinator {
    nonisolated static let quietRefreshWaitBudget: Duration = .seconds(8)
    nonisolated static let serverWorkBudget: Duration = .seconds(20)
    nonisolated static let maximumMutationsPerServerPass = 32
    typealias ServersProvider = @MainActor () -> [PairedServer]
    typealias NotificationSessionOperation =
        @MainActor (any NotificationRepository) async throws -> Void
    typealias NotificationSessionProvider =
        @MainActor (PairedServer, NotificationSessionOperation) async throws -> Void

    private let runtimeMode: AppRuntimeMode
    private let localStore: NotificationLocalStore
    private let serversProvider: ServersProvider
    private let notificationSessionProvider: NotificationSessionProvider
    private let notificationCenter: UNUserNotificationCenter
    private var currentDeviceToken: String?
    private var outbox: [NotificationMutation]
    private var startedForCurrentLaunch = false
    private var authenticatedThisLaunch = false
    private var permissionRequestAttempted = false
    private var localStateLoaded = false
    private var localLoadTask: Task<NotificationLocalState, Never>?
    private var pendingMutationPersistence: [NotificationMutation] = []
    private var mutationPersistenceTask: Task<Void, Never>?
    private var mutationPersistenceGeneration: UInt64 = 0
    private var pendingServerWork: [String: NotificationServerWork] = [:]
    private var serverLaneTasks: [String: Task<Void, Never>] = [:]
    private var serverLaneGenerations: [String: UInt64] = [:]
    private var systemLifecycleTask: Task<Void, Never>?
    private var systemRefreshRequested = false
    private var systemPermissionEstablishmentRequested = false
    private var badgeTask: Task<Void, Never>?
    private var pendingBadgeCount: Int?
    private var shutdownTask: Task<Void, Never>?
    private var isShuttingDown = false

    private(set) var authorizationStatus: NotificationAuthorizationState = .notDetermined
    private(set) var inbox: [NotificationInboxItem]
    private(set) var readiness: [NotificationServerReadiness]
    private(set) var remoteRegistrationProblem: String?

    init(
        defaults: UserDefaults,
        storeURL: URL? = nil,
        runtimeMode: AppRuntimeMode = .current,
        notificationCenter: UNUserNotificationCenter = .current(),
        servers: @escaping ServersProvider,
        notificationSession:
            @escaping NotificationSessionProvider
    ) {
        self.runtimeMode = runtimeMode
        localStore = NotificationLocalStore(
            defaults: NotificationDefaultsHandle(value: defaults),
            fileURL: storeURL ?? Self.defaultStoreURL
        )
        serversProvider = servers
        notificationSessionProvider = notificationSession
        self.notificationCenter = notificationCenter
        inbox = []
        outbox = []
        readiness = []
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
        guard runtimeMode.runsApplicationLifecycle,
              !startedForCurrentLaunch,
              !isShuttingDown else { return }
        startedForCurrentLaunch = true
        attachLifecycle()
        scheduleSystemLifecycleRefresh(establishPermission: false)
    }

    /// Called only after an authenticated engine connection succeeds. This is
    /// the one permission-request boundary for a launch.
    func connectionDidAuthenticate() {
        guard runtimeMode.runsApplicationLifecycle else { return }
        launch()
        authenticatedThisLaunch = true
        scheduleSystemLifecycleRefresh(establishPermission: true)
    }

    func pairedServersDidChange() {
        guard startedForCurrentLaunch, !isShuttingDown else { return }
        retireRemovedServerLanes()
        scheduleRegistration()
        scheduleSync()
    }

    func foregrounded() {
        guard startedForCurrentLaunch, !isShuttingDown else { return }
        scheduleSystemLifecycleRefresh(establishPermission: false)
    }

    func didReceiveDeviceToken(_ data: Data) {
        guard !isShuttingDown else { return }
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
        await ensureLocalStateLoaded()
        let previous = inbox
        scheduleSync(serverIds: [serverId])
        let deadline = ContinuousClock.now + Self.quietRefreshWaitBudget
        while hasPendingServerWork(serverId: serverId),
              ContinuousClock.now < deadline {
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
        guard !isShuttingDown else { return }
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

    private func scheduleSystemLifecycleRefresh(
        establishPermission: Bool
    ) {
        guard !isShuttingDown else { return }
        systemRefreshRequested = true
        systemPermissionEstablishmentRequested =
            systemPermissionEstablishmentRequested || establishPermission
        guard systemLifecycleTask == nil else { return }
        systemLifecycleTask = Task { @MainActor [weak self] in
            await self?.drainSystemLifecycleRequests()
        }
    }

    private func drainSystemLifecycleRequests() async {
        await ensureLocalStateLoaded()
        while systemRefreshRequested, !Task.isCancelled {
            let establishPermission = systemPermissionEstablishmentRequested
            systemRefreshRequested = false
            systemPermissionEstablishmentRequested = false
            if establishPermission {
                await establishSystemAuthorization()
            } else {
                await refreshAuthorizationStatus()
                if NativeNotificationPermissionPolicy.permitsRemoteRegistration(
                    authorizationStatus
                ) {
                    UIApplication.shared.registerForRemoteNotifications()
                }
                scheduleRegistration()
                scheduleSync()
            }
        }
        systemLifecycleTask = nil
        if systemRefreshRequested, !isShuttingDown {
            scheduleSystemLifecycleRefresh(
                establishPermission: systemPermissionEstablishmentRequested
            )
        }
    }

    private func scheduleRegistration() {
        requestServerWork(
            serverIds: serversProvider().map(\.id),
            work: NotificationServerWork(registration: true)
        )
    }

    private func scheduleSync(serverIds: [String]? = nil) {
        requestServerWork(
            serverIds: serverIds ?? serversProvider().map(\.id),
            work: NotificationServerWork(synchronization: true)
        )
    }

    private func requestServerWork(
        serverIds: [String],
        work: NotificationServerWork
    ) {
        guard !isShuttingDown else { return }
        for serverId in Set(serverIds) {
            var pending = pendingServerWork[serverId] ?? NotificationServerWork()
            pending.formUnion(work)
            pendingServerWork[serverId] = pending
            startServerLaneIfNeeded(serverId: serverId)
        }
    }

    private func startServerLaneIfNeeded(serverId: String) {
        guard serverLaneTasks[serverId] == nil,
              pendingServerWork[serverId] != nil,
              !isShuttingDown else { return }
        let generation = (serverLaneGenerations[serverId] ?? 0) &+ 1
        serverLaneGenerations[serverId] = generation
        serverLaneTasks[serverId] = Task { @MainActor [weak self] in
            await self?.drainServerLane(
                serverId: serverId,
                generation: generation
            )
        }
    }

    private func drainServerLane(
        serverId: String,
        generation: UInt64
    ) async {
        await ensureLocalStateLoaded()
        while !Task.isCancelled,
              let work = pendingServerWork.removeValue(forKey: serverId) {
            guard let server = serversProvider().first(where: {
                $0.id == serverId
            }) else {
                continue
            }
            await flushPendingMutationPersistence()
            guard !pendingMutationPersistence.contains(where: {
                $0.serverId == serverId
            }) else {
                // Never transmit an action that has not reached durable local
                // ownership. A later foreground or user action retries it.
                continue
            }
            await performServerWork(work, server: server)
        }
        guard serverLaneGenerations[serverId] == generation else { return }
        serverLaneTasks[serverId] = nil
        if pendingServerWork[serverId] != nil, !isShuttingDown {
            startServerLaneIfNeeded(serverId: serverId)
        }
    }

    private func performServerWork(
        _ work: NotificationServerWork,
        server: PairedServer
    ) async {
        let topic = Bundle.main.bundleIdentifier ?? ""
        if work.registration, topic.isEmpty {
            remoteRegistrationProblem = "The application push topic is unavailable."
        }

        let token = NativeNotificationPermissionPolicy.permitsRemoteRegistration(
            authorizationStatus
        ) ? currentDeviceToken : nil
        let pendingForServer = outbox.filter { $0.serverId == server.id }
        let mutationBatch = Array(
            pendingForServer.prefix(Self.maximumMutationsPerServerPass)
        )
        var registrationResult: Result<
            NotificationDeviceRegistrationDTO,
            Error
        >?
        var acknowledgedMutationIds = Set<String>()
        var synchronizedDeliveries: [String: [NotificationDeliveryDTO]] = [:]
        var deferredMutations = pendingForServer.count > mutationBatch.count
        var madeMutationProgress = false
        var registrationMadeProgress = false
        let deadline = ContinuousClock.now + Self.serverWorkBudget

        do {
            try await notificationSessionProvider(server) { repository in
                if work.registration, !topic.isEmpty {
                    do {
                        let registration = try await repository.upsertDevice(
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
                        registrationResult = .success(registration)
                        registrationMadeProgress = true
                    } catch {
                        registrationResult = .failure(error)
                    }
                }

                if work.synchronization {
                    for mutation in mutationBatch {
                        guard !Task.isCancelled else {
                            throw CancellationError()
                        }
                        guard ContinuousClock.now < deadline else {
                            deferredMutations = true
                            break
                        }
                        do {
                            _ = try await repository.acknowledge(
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
                            acknowledgedMutationIds.insert(
                                mutation.mutationId
                            )
                            madeMutationProgress = true
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            // Keep this response durable while allowing later
                            // idempotent mutations in the same bounded batch.
                        }
                    }
                    if ContinuousClock.now < deadline {
                        do {
                            let page = try await repository.deliveries(
                                cursor: nil,
                                limit: 200,
                                unreadOnly: false
                            )
                            synchronizedDeliveries[server.id] = page.deliveries
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            // Preserve the previous local inbox.
                        }
                    }
                }
            }
        } catch is CancellationError {
            return
        } catch {
            if work.registration {
                registrationResult = .failure(error)
            }
        }

        if !acknowledgedMutationIds.isEmpty
            || !synchronizedDeliveries.isEmpty {
            do {
                let state = try await localStore.commitSynchronization(
                    acknowledgedMutationIds: acknowledgedMutationIds,
                    deliveriesByServer: synchronizedDeliveries
                )
                applyInboxAndOutbox(state)
            } catch {
                logger.warning(
                    "Failed to persist notification synchronization: \(error.localizedDescription)",
                    category: .notification
                )
            }
        }

        if let registrationResult {
            switch registrationResult {
            case .success(let registration):
                await setReadiness(
                    NotificationServerReadiness(
                        serverId: server.id,
                        ready: registration.ready
                            && registration.transport.configured,
                        deviceReady: registration.ready,
                        transportMode: registration.transport.mode,
                        transportConfigured:
                            registration.transport.configured,
                        transportProblem:
                            registration.transport.problemCode,
                        authorizationStatus:
                            registration.authorizationStatus,
                        registeredAt: registration.registeredAt,
                        problem: nil
                    )
                )
            case .failure(let error):
                await setReadiness(
                    NotificationServerReadiness(
                        serverId: server.id,
                        ready: false,
                        deviceReady: nil,
                        transportMode: nil,
                        transportConfigured: nil,
                        transportProblem: nil,
                        authorizationStatus: authorizationStatus,
                        registeredAt: readiness.first {
                            $0.serverId == server.id
                        }?.registeredAt,
                        problem: error.localizedDescription
                    )
                )
            }
        }

        if deferredMutations,
           madeMutationProgress || registrationMadeProgress {
            scheduleSync(serverIds: [server.id])
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
        guard !mutations.isEmpty, !isShuttingDown else { return }
        outbox.append(contentsOf: mutations)
        pendingMutationPersistence.append(contentsOf: mutations)
        for mutation in mutations {
            optimisticallyApply(mutation)
        }
        updateBadge()
        scheduleMutationPersistence()
        scheduleSync(serverIds: Array(Set(mutations.map(\.serverId))))
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

    private func ensureLocalStateLoaded() async {
        guard !localStateLoaded else { return }
        let task: Task<NotificationLocalState, Never>
        if let localLoadTask {
            task = localLoadTask
        } else {
            let store = localStore
            let created = Task {
                do {
                    return try await store.load()
                } catch {
                    logger.warning(
                        "Failed to restore notification state: \(error.localizedDescription)",
                        category: .notification
                    )
                    return NotificationLocalState()
                }
            }
            localLoadTask = created
            task = created
        }
        let state = await task.value
        guard !localStateLoaded else { return }
        localStateLoaded = true
        localLoadTask = nil
        applyLocalState(state)
    }

    private func scheduleMutationPersistence() {
        guard !pendingMutationPersistence.isEmpty,
              mutationPersistenceTask == nil else { return }
        mutationPersistenceGeneration &+= 1
        let generation = mutationPersistenceGeneration
        mutationPersistenceTask = Task { @MainActor [weak self] in
            await self?.drainMutationPersistence(generation: generation)
        }
    }

    private func drainMutationPersistence(generation: UInt64) async {
        await ensureLocalStateLoaded()
        var persistenceFailed = false
        while !pendingMutationPersistence.isEmpty, !Task.isCancelled {
            let batch = pendingMutationPersistence
            let batchIds = Set(batch.map(\.mutationId))
            do {
                let state = try await localStore.appendMutations(batch)
                pendingMutationPersistence.removeAll {
                    batchIds.contains($0.mutationId)
                }
                applyInboxAndOutbox(state)
            } catch {
                persistenceFailed = true
                logger.warning(
                    "Failed to persist notification response outbox: \(error.localizedDescription)",
                    category: .notification
                )
                break
            }
        }
        guard mutationPersistenceGeneration == generation else { return }
        mutationPersistenceTask = nil
        if !pendingMutationPersistence.isEmpty,
           !persistenceFailed,
           !isShuttingDown {
            scheduleMutationPersistence()
        }
    }

    private func flushPendingMutationPersistence() async {
        guard !pendingMutationPersistence.isEmpty else { return }
        scheduleMutationPersistence()
        await mutationPersistenceTask?.value
    }

    private func applyLocalState(_ state: NotificationLocalState) {
        applyInboxAndOutbox(state)
        readiness = state.readiness
    }

    private func applyInboxAndOutbox(_ state: NotificationLocalState) {
        let durableIds = Set(state.outbox.map(\.mutationId))
        let notYetDurable = pendingMutationPersistence.filter {
            !durableIds.contains($0.mutationId)
        }
        inbox = state.inbox
        outbox = state.outbox + notYetDurable
        for mutation in outbox {
            optimisticallyApply(mutation)
        }
        updateBadge()
    }

    private func retireRemovedServerLanes() {
        let pairedIds = Set(serversProvider().map(\.id))
        for serverId in serverLaneTasks.keys where !pairedIds.contains(serverId) {
            serverLaneGenerations[serverId, default: 0] &+= 1
            serverLaneTasks.removeValue(forKey: serverId)?.cancel()
            pendingServerWork.removeValue(forKey: serverId)
        }
    }

    private func hasPendingServerWork(serverId: String) -> Bool {
        pendingServerWork[serverId] != nil
            || serverLaneTasks[serverId] != nil
    }

    /// Cancel transport work and await every accepted local response write.
    /// The production coordinator is process-lived; tests and replacement
    /// composition roots call this explicit boundary before releasing state.
    func shutdown() async {
        if let shutdownTask {
            await shutdownTask.value
            return
        }
        let task = Task { @MainActor [self] in
            await performShutdown()
        }
        shutdownTask = task
        await task.value
    }

    private func performShutdown() async {
        isShuttingDown = true
        systemRefreshRequested = false
        systemPermissionEstablishmentRequested = false
        systemLifecycleTask?.cancel()
        let systemTask = systemLifecycleTask
        systemLifecycleTask = nil

        let laneTasks = Array(serverLaneTasks.values)
        serverLaneTasks.values.forEach { $0.cancel() }
        serverLaneTasks.removeAll()
        pendingServerWork.removeAll()
        badgeTask?.cancel()

        await systemTask?.value
        for task in laneTasks {
            await task.value
        }
        await badgeTask?.value
        badgeTask = nil

        await ensureLocalStateLoaded()
        await mutationPersistenceTask?.value
        if !pendingMutationPersistence.isEmpty {
            let batch = pendingMutationPersistence
            let batchIds = Set(batch.map(\.mutationId))
            do {
                let state = try await localStore.appendMutations(batch)
                pendingMutationPersistence.removeAll {
                    batchIds.contains($0.mutationId)
                }
                applyInboxAndOutbox(state)
            } catch {
                logger.warning(
                    "Notification shutdown could not drain response outbox: \(error.localizedDescription)",
                    category: .notification
                )
            }
        }
    }

    nonisolated deinit {
        MainActor.assumeIsolated {
            shutdownTask?.cancel()
            systemLifecycleTask?.cancel()
            serverLaneTasks.values.forEach { $0.cancel() }
            badgeTask?.cancel()
        }
    }

    private func setReadiness(
        _ value: NotificationServerReadiness
    ) async {
        readiness.removeAll { $0.serverId == value.serverId }
        readiness.append(value)
        readiness.sort { $0.serverId < $1.serverId }
        do {
            let state = try await localStore.replaceReadiness(readiness)
            readiness = state.readiness
        } catch {
            logger.warning(
                "Failed to persist notification readiness: \(error.localizedDescription)",
                category: .notification
            )
        }
    }

    private func updateBadge() {
        guard runtimeMode.runsApplicationLifecycle else { return }
        pendingBadgeCount = aggregateUnreadCount
        guard badgeTask == nil else { return }
        badgeTask = Task { @MainActor [weak self] in
            await self?.drainBadgeUpdates()
        }
    }

    private func drainBadgeUpdates() async {
        while let count = pendingBadgeCount, !Task.isCancelled {
            pendingBadgeCount = nil
            try? await notificationCenter.setBadgeCount(count)
        }
        badgeTask = nil
        if pendingBadgeCount != nil, !isShuttingDown {
            updateBadge()
        }
    }

    private static var defaultStoreURL: URL {
        guard let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            preconditionFailure(
                "Application Support unavailable for notification state"
            )
        }
        return applicationSupport
            .appendingPathComponent("Tron", isDirectory: true)
            .appendingPathComponent("Notifications", isDirectory: true)
            .appendingPathComponent("state-v2.json")
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
