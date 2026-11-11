import Foundation
import TronMobileCore

enum DashboardCatalogRetryPolicy {
    static let unavailableNoticeAfterFailures = 3

    nonisolated static func shouldRetry(isRetryableFailure: Bool, isCurrent: Bool) -> Bool {
        isRetryableFailure && isCurrent
    }

    nonisolated static func isRetryableFailure(_ error: Error) -> Bool {
        let failure = (error as? GatewayFailure)
            ?? (error as? GatewayDefinitelyNotSentError)?.failure
            ?? (error as? GatewayPossiblySentError)?.failure
        guard let failure else { return true }
        return failure.retryable && !GatewayRecoveryFailurePolicy.isNonRetryable(failure)
    }
}

@MainActor
protocol DashboardGatewayConnectionPoolDelegate: AnyObject {
    func dashboardPoolDidUpdate(
        profileID: String,
        sessions: [CatalogSession],
        state: DashboardServerConnectionState,
        stopReason: String?
    )
    func dashboardPoolNotificationInboxChanged(profileID: String, change: NotificationInboxChanged?)
    func dashboardPoolAutomationChanged(profileID: String)
    func dashboardPoolDevicesChanged(profileID: String)
    func dashboardPoolDidUpdateArchivedCount(profileID: String, count: Int?)
    func dashboardPoolDidPublishAuthoritativeCatalog(profileID: String)
}

extension DashboardGatewayConnectionPoolDelegate {
    func dashboardPoolAutomationChanged(profileID: String) {}
    func dashboardPoolDevicesChanged(profileID: String) {}
}

private struct DashboardPoolProfileIdentity: Equatable {
    let host: String
    let port: Int
    let label: String
    let machineId: String
    let machineGroupID: String
    let deviceId: String?
    let isEnabled: Bool

    init(_ profile: GatewayProfile) {
        host = profile.host
        port = profile.port
        label = profile.label
        machineId = profile.machineId
        machineGroupID = profile.machineGroupID
        deviceId = profile.deviceId
        isEnabled = profile.isEnabled
    }
}

@MainActor
final class DashboardGatewayConnectionPool {
    static let POOL_UNREACHABLE_AFTER = 3
    static let POOL_MAX_RETRY: Duration = .seconds(300)
    private final class RecoveryState {
        let identity: DashboardPoolProfileIdentity
        let token: String
        var failedAttempts = 0
        var lastConnectedAt: Date?
        var stopReason: String?

        init(profile: GatewayProfile, token: String) {
            identity = DashboardPoolProfileIdentity(profile)
            self.token = token
        }
    }

    private struct Entry {
        let profile: GatewayProfile
        let token: String
        let client: GatewayClient
        let recorder: GatewayConnectionEpisodeRecorder
        var connectionID: Int?
        var gatewayInfo: GatewayInfo?
        var state: DashboardServerConnectionState
        var catalog: SessionCatalogCoordinator
        var task: Task<Void, Never>?
        var refreshTask: Task<Void, Never>?
        var reconnectTask: Task<Void, Never>?
        var eventTask: Task<Void, Never>?
        let reconnectSchedule: GatewayReconnectSchedule
        var reconnectWaiting: Bool
        var networkPathSatisfied: Bool
        var generation: Int
        var refreshInvalidationGeneration: Int
        var refreshSatisfiedGeneration: Int
        var refreshRequestGeneration: Int
        var refreshRetryAttempt: Int
        var refreshFailedAttempts: Int
        let recovery: RecoveryState
        var reconnectLoopID: String?
        var attemptInFlightLoopID: String?
    }

    weak var delegate: (any DashboardGatewayConnectionPoolDelegate)?
    private let clientFactory: @MainActor () -> GatewayClient
    private let clock: MonotonicClock
    private let reconnectDelayPolicy: ReconnectDelayPolicy
    private let appLog: AppLog
    private var entries: [String: Entry] = [:]
    private var generation = 0
    private var retirementTasks: [String: (generation: Int, task: Task<Void, Never>)] = [:]
    private var recoveryStates: [String: RecoveryState] = [:]
    private var nonRetryableProfiles = Set<String>()

    init(
        clientFactory: @escaping @MainActor () -> GatewayClient = { GatewayClient() },
        clock: MonotonicClock = .continuous,
        reconnectDelayPolicy: ReconnectDelayPolicy = .standard,
        appLog: AppLog = .shared
    ) {
        self.clientFactory = clientFactory
        self.clock = clock
        self.reconnectDelayPolicy = reconnectDelayPolicy
        self.appLog = appLog
    }

    func reconcile(
        profiles: [GatewayProfile],
        selectedProfileID: String?,
        token: @escaping (GatewayProfile) -> String?
    ) {
        generation &+= 1
        let profileIDs = Set(profiles.map(\.id))
        let selectedProfile = profiles.first(where: { $0.id == selectedProfileID })
        let admittedIDs = Self.admittedProfileIDs(
            profiles,
            selectedProfileID: selectedProfileID,
            selectedMachineGroupID: selectedProfile?.machineGroupID,
            selectedProfileIsProvisional: selectedProfile.map { $0.machineGroupID == $0.machineId } == true,
            tokenAvailable: { token($0) != nil }
        )
        let desired = profiles.filter { admittedIDs.contains($0.id) && token($0) != nil }
        let desiredIDs = Set(desired.map(\.id))
        for (profileID, recovery) in Array(recoveryStates) {
            guard let profile = profiles.first(where: { $0.id == profileID }),
                  desiredIDs.contains(profileID), profile.isEnabled, token(profile) != nil,
                  recovery.identity == DashboardPoolProfileIdentity(profile),
                  recovery.token == token(profile) else {
                recoveryStates[profileID] = nil
                nonRetryableProfiles.remove(profileID)
                continue
            }
        }
        for profileID in Array(entries.keys) {
            guard let profile = desired.first(where: { $0.id == profileID }),
                  let current = entries[profileID],
                  let currentToken = token(profile) else {
                if !desiredIDs.contains(profileID) {
                    recoveryStates[profileID] = nil
                    nonRetryableProfiles.remove(profileID)
                    stop(profileID: profileID)
                }
                continue
            }
            if DashboardPoolProfileIdentity(current.profile) != DashboardPoolProfileIdentity(profile)
                || current.token != currentToken {
                recoveryStates[profileID] = nil
                nonRetryableProfiles.remove(profileID)
                stop(profileID: profileID)
            }
        }
        for profile in desired where entries[profile.id] == nil {
            start(profile: profile, token: token(profile), generation: generation)
        }
    }

    func retire(endedBy: GatewayEpisodeEnd = .background) {
        generation &+= 1
        for profileID in Array(entries.keys) { stop(profileID: profileID, endedBy: endedBy) }
    }

    func waitForRetirement() async {
        for retirement in Array(retirementTasks.values) { await retirement.task.value }
    }

    func state(for profileID: String) -> DashboardServerConnectionState? {
        entries[profileID]?.state
    }

    func stopReason(for profileID: String) -> String? {
        entries[profileID]?.recovery.stopReason
    }

    func lastConnectedAt(for profileID: String) -> Date? {
        recoveryStates[profileID]?.lastConnectedAt
    }

    func infoSnapshot(for profileID: String) -> GatewayInfo? {
        entries[profileID]?.gatewayInfo
    }

    func connectionID(for profileID: String) async -> Int? {
        guard let entry = entries[profileID] else { return nil }
        return await entry.client.activeConnectionID()
    }

    func connectionIDSnapshot(for profileID: String) -> Int? {
        entries[profileID]?.connectionID
    }

    func requestIdentity(for profileID: String) -> String? {
        guard let entry = entries[profileID], let connectionID = entry.connectionID else { return nil }
        return "\(entry.client.diagnosticOwnerID):\(entry.generation):\(connectionID)"
    }

    func requestAdmission(for profileID: String) -> GatewayConnectionAdmission? {
        guard let connectionID = entries[profileID]?.connectionID else { return nil }
        return GatewayConnectionAdmission(connectionID: connectionID)
    }

    func request(
        profileID: String,
        method: String,
        params: JSONValue
    ) async throws -> JSONValue {
        guard let admission = requestAdmission(for: profileID) else {
            throw GatewayFailure(code: "disconnected", message: "The Mac gateway is offline.", retryable: true, details: nil)
        }
        return try await request(profileID: profileID, method: method, params: params, expectedConnection: admission)
    }

    func request(
        profileID: String,
        method: String,
        params: JSONValue,
        expectedConnection: GatewayConnectionAdmission
    ) async throws -> JSONValue {
        guard let client = entries[profileID]?.client else {
            throw GatewayFailure(code: "disconnected", message: "The Mac gateway is offline.", retryable: true, details: nil)
        }
        return try await client.requestValue(method, params, expectedConnection: expectedConnection)
    }

    func info(for profileID: String) async -> GatewayInfo? {
        guard let client = entries[profileID]?.client else { return nil }
        return await client.info
    }

    func diagnostics(for profileID: String) -> GatewayDiagnosticsService? {
        guard let client = entries[profileID]?.client else { return nil }
        return GatewayDiagnosticsService(client: client)
    }

    func notificationInbox(
        for profileID: String,
        filter: NotificationInboxFilter,
        cursor: String? = nil,
        connectionID: Int? = nil
    ) async throws -> NotificationInboxGatewayClient.Snapshot {
        guard let client = entries[profileID]?.client else {
            throw GatewayFailure(code: "disconnected", message: "The Mac gateway is offline.", retryable: true, details: nil)
        }
        return try await NotificationInboxGatewayClient.list(
            client: client,
            filter: filter,
            cursor: cursor,
            expectedConnectionID: connectionID
        )
    }

    func markNotificationRead(profileID: String, id: String, commandID: String) async throws {
        guard let client = entries[profileID]?.client else {
            throw GatewayFailure(code: "disconnected", message: "The Mac gateway is offline.", retryable: true, details: nil)
        }
        try await NotificationInboxGatewayClient.markRead(id: id, client: client, commandID: commandID)
    }

    func markNotificationRead(profileID: String, requestID: String, commandID: String) async throws {
        guard let client = entries[profileID]?.client else {
            throw GatewayFailure(code: "disconnected", message: "The Mac gateway is offline.", retryable: true, details: nil)
        }
        try await NotificationInboxGatewayClient.markRead(requestID: requestID, client: client, commandID: commandID)
    }

    func markAllNotificationsRead(profileID: String, through: String, commandID: String) async throws {
        guard let client = entries[profileID]?.client else {
            throw GatewayFailure(code: "disconnected", message: "The Mac gateway is offline.", retryable: true, details: nil)
        }
        try await NotificationInboxGatewayClient.markAllRead(client: client, commandID: commandID, through: through)
    }

    func devices(for profileID: String) async throws -> [PairedDevice] {
        guard let client = entries[profileID]?.client else {
            throw GatewayFailure(
                code: "disconnected",
                message: "The Mac gateway is offline.",
                retryable: true,
                details: nil
            )
        }
        struct Response: Decodable { let devices: [PairedDevice] }
        let response: Response = try await client.request("device.list", EmptyParams())
        return try PairedDeviceCatalogPolicy.admit(response.devices)
    }

    nonisolated static func admitsIdentity(_ info: GatewayInfo, for profile: GatewayProfile) -> Bool {
        info.machineId == profile.machineId && info.machineGroupID == profile.machineGroupID
    }

    nonisolated static func shouldAdmit(
        _ profile: GatewayProfile,
        selectedProfileID: String?,
        selectedMachineGroupID: String?,
        selectedProfileIsProvisional: Bool = false
    ) -> Bool {
        !selectedProfileIsProvisional
            && profile.id != selectedProfileID
            && profile.isEnabled
            && profile.machineGroupID != profile.machineId
            && profile.machineGroupID != selectedMachineGroupID
    }

    nonisolated static func admittedProfileIDs(
        _ profiles: [GatewayProfile],
        selectedProfileID: String?,
        selectedMachineGroupID: String?,
        selectedProfileIsProvisional: Bool = false,
        tokenAvailable: ((GatewayProfile) -> Bool)? = nil
    ) -> Set<String> {
        var groups = Set<String>()
        return Set(profiles.compactMap { profile in
            guard shouldAdmit(
                profile,
                selectedProfileID: selectedProfileID,
                selectedMachineGroupID: selectedMachineGroupID,
                selectedProfileIsProvisional: selectedProfileIsProvisional
            ),
            tokenAvailable?(profile) ?? true,
            groups.insert(profile.machineGroupID).inserted else { return nil }
            return profile.id
        })
    }

    private func start(profile: GatewayProfile, token: String?, generation: Int) {
        guard let token else { return }
        let client = clientFactory()
        let retirementBarrier = retirementTasks[profile.id]?.task
        let recorder = GatewayConnectionEpisodeRecorder(
            clock: clock, appLog: appLog, mainStallPing: {}
        )
        recorder.stallGuard = { [weak self] in
            guard let self else { return nil }
            return self.stallGuard(profileID: profile.id)
        }
        let recovery = recoveryStates[profile.id] ?? RecoveryState(profile: profile, token: token)
        recoveryStates[profile.id] = recovery
        entries[profile.id] = Entry(
            profile: profile,
            token: token,
            client: client,
            recorder: recorder,
            connectionID: nil,
            gatewayInfo: nil,
            state: nonRetryableProfiles.contains(profile.id) || recovery.failedAttempts >= Self.POOL_UNREACHABLE_AFTER
                ? .offline : (recovery.failedAttempts > 0 ? .reconnecting : .connecting),
            catalog: SessionCatalogCoordinator(),
            task: nil,
            refreshTask: nil,
            reconnectTask: nil,
            eventTask: nil,
            reconnectSchedule: GatewayReconnectSchedule(
                clock: clock
            ),
            reconnectWaiting: false,
            networkPathSatisfied: true,
            generation: generation,
            refreshInvalidationGeneration: 0,
            refreshSatisfiedGeneration: 0,
            refreshRequestGeneration: 0,
            refreshRetryAttempt: 0,
            refreshFailedAttempts: 0,
            recovery: recovery,
            reconnectLoopID: nil,
            attemptInFlightLoopID: nil
        )
        publish(profileID: profile.id)
        guard !nonRetryableProfiles.contains(profile.id) else { return }
        let task = Task { @MainActor [weak self] in
            await retirementBarrier?.value
            guard let self,
                  !Task.isCancelled,
                  self.isCurrent(profileID: profile.id, client: client, generation: generation) else { return }
            if recovery.failedAttempts > 0 {
                self.scheduleReconnect(profileID: profile.id, generation: generation)
                return
            }
            let diagnosticSequence = await client.latestDiagnosticSequence()
            guard self.isCurrent(profileID: profile.id, client: client, generation: generation) else { return }
            let startedAt = self.clock.now()
            do {
                let identity = try await client.connectForLifecycle(profile: profile, token: token)
                try await client.activateEvents(connectionID: identity.id)
                guard Self.admitsIdentity(identity.info, for: profile) else {
                    throw GatewayFailure(
                        code: "identity_mismatch",
                        message: "The paired server identity no longer matches this endpoint.",
                        retryable: false,
                        details: nil
                    )
                }
                let connectionID = await client.activeConnectionID()
                guard !Task.isCancelled,
                      self.isCurrent(profileID: profile.id, client: client, generation: generation) else { return }
                guard connectionID == identity.id else {
                    throw GatewayFailure(
                        code: "replaced",
                        message: "The connection ended before its handshake completed.",
                        retryable: true,
                        details: nil
                    )
                }
                self.entries[profile.id]?.reconnectSchedule.reset()
                recovery.failedAttempts = 0
                recovery.lastConnectedAt = Date()
                recovery.stopReason = nil
                self.entries[profile.id]?.connectionID = connectionID
                self.entries[profile.id]?.gatewayInfo = identity.info
                self.entries[profile.id]?.state = .connecting
                self.recordAttempt(
                    profileID: profile.id,
                    generation: generation,
                    attemptID: "initial",
                    retry: 0,
                    startedAt: startedAt,
                    delayBeforeMs: 0,
                    diagnostic: nil,
                    reason: nil,
                    succeeded: true,
                    connectionID: connectionID,
                    gatewayConnectionID: identity.gatewayConnectionID
                )
                self.publish(profileID: profile.id)
                self.scheduleRefresh(
                    profileID: profile.id,
                    generation: generation,
                    delay: .zero
                )
                self.startEventConsumption(
                    profileID: profile.id,
                    generation: generation,
                    client: client,
                    connectionID: identity.id
                )
            } catch is CancellationError {
                return
            } catch let failure as GatewayFailure where GatewayRecoveryFailurePolicy.isNonRetryable(failure) {
                let diagnostic = await client.latestHandshakeDiagnostic(after: diagnosticSequence)
                await client.close()
                guard self.isCurrent(profileID: profile.id, client: client, generation: generation) else { return }
                self.nonRetryableProfiles.insert(profile.id)
                self.entries[profile.id]?.gatewayInfo = nil
                recovery.stopReason = failure.message
                self.entries[profile.id]?.state = failure.code == "identity_mismatch" ? .identityMismatch : .offline
                self.recordAttempt(
                    profileID: profile.id,
                    generation: generation,
                    attemptID: "initial",
                    retry: 0,
                    startedAt: startedAt,
                    delayBeforeMs: 0,
                    diagnostic: diagnostic,
                    reason: GatewayDiagnosticFailure.answerCode(failure),
                    succeeded: false,
                    connectionID: nil
                )
                self.entries[profile.id]?.recorder.endEpisode(
                    .stopped, profileID: profile.id, lifecycleGeneration: generation
                )
                self.publish(profileID: profile.id)
            } catch {
                guard !Task.isCancelled,
                      self.isCurrent(profileID: profile.id, client: client, generation: generation) else { return }
                let diagnostic = await client.latestHandshakeDiagnostic(after: diagnosticSequence)
                guard self.isCurrent(profileID: profile.id, client: client, generation: generation) else { return }
                recovery.failedAttempts += 1
                let failedState = self.failedConnectionState(profileID: profile.id)
                self.recordAttempt(
                    profileID: profile.id,
                    generation: generation,
                    attemptID: "initial",
                    retry: 0,
                    startedAt: startedAt,
                    delayBeforeMs: 0,
                    diagnostic: diagnostic,
                    reason: GatewayDiagnosticFailure.code(error),
                    succeeded: false,
                    connectionID: nil
                )
                self.retireConnectionEpoch(
                    profileID: profile.id,
                    generation: generation,
                    state: failedState
                )
                self.scheduleReconnect(profileID: profile.id, generation: generation)
            }
        }
        entries[profile.id]?.task = task
    }

    private func stop(
        profileID: String,
        close: Bool = true,
        endedBy: GatewayEpisodeEnd = .stopped
    ) {
        guard let entry = entries.removeValue(forKey: profileID) else { return }
        if endedBy != .background { recoveryStates[profileID] = nil }
        entry.task?.cancel()
        entry.refreshTask?.cancel()
        entry.reconnectTask?.cancel()
        entry.eventTask?.cancel()
        entry.reconnectSchedule.cancel()
        entry.recorder.endEpisode(
            endedBy, profileID: profileID, lifecycleGeneration: entry.generation
        )
        delegate?.dashboardPoolDidUpdate(
            profileID: profileID,
            sessions: entry.catalog.sessions,
            state: .offline,
            stopReason: nil
        )
        if close {
            let previous = retirementTasks[profileID]?.task
            let task = Task { @MainActor [weak self] in
                await previous?.value
                await entry.client.close()
                guard let self else { return }
                if self.retirementTasks[profileID]?.generation == entry.generation {
                    self.retirementTasks[profileID] = nil
                }
            }
            retirementTasks[profileID] = (entry.generation, task)
        }
    }

    private func isCurrent(profileID: String, client: GatewayClient, generation: Int) -> Bool {
        guard let entry = entries[profileID] else { return false }
        return entry.client === client && entry.generation == generation
    }

    private func startEventConsumption(
        profileID: String,
        generation: Int,
        client: GatewayClient,
        connectionID: Int
    ) {
        guard let entry = entries[profileID],
              entry.generation == generation,
              entry.client === client,
              entry.connectionID == connectionID else { return }
        guard entries[profileID]?.eventTask == nil else { return }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            for await delivery in client.events {
                guard !Task.isCancelled,
                      self.isCurrent(profileID: profileID, client: client, generation: generation) else { return }
                await self.handle(delivery, profileID: profileID, generation: generation)
            }
            guard !Task.isCancelled,
                  self.isCurrent(profileID: profileID, client: client, generation: generation) else { return }
            self.entries[profileID]?.recorder.noteDisconnected(
                profileID: profileID, lifecycleGeneration: generation, foreground: true
            )
            self.retireConnectionEpoch(
                profileID: profileID,
                generation: generation,
                state: .reconnecting
            )
            self.scheduleReconnect(profileID: profileID, generation: generation)
        }
        entries[profileID]?.eventTask = task
    }

    private func handle(
        _ delivery: GatewayEventDelivery,
        profileID: String,
        generation: Int
    ) async {
        guard let entry = entries[profileID],
              entry.connectionID == delivery.connectionID,
              isCurrent(profileID: profileID, client: entry.client, generation: generation) else { return }
        let event = delivery.event
        switch event.topic {
        case "session.summary":
            guard case .sessionSummary(let update) = event.preparation else {
                scheduleRefresh(profileID: profileID, generation: generation)
                return
            }
            guard var current = entries[profileID] else { return }
            switch current.catalog.apply(update) {
            case .stale:
                return
            case .unknownSession:
                entries[profileID] = current
                scheduleRefresh(profileID: profileID, generation: generation)
            case .updated:
                entries[profileID] = current
                publish(profileID: profileID)
            }
        case "session.listChanged":
            scheduleRefresh(profileID: profileID, generation: generation)
        case "notification.inbox.changed":
            delegate?.dashboardPoolNotificationInboxChanged(
                profileID: profileID,
                change: event.preparedNotificationInboxChanged
            )
        case "devices.changed":
            delegate?.dashboardPoolDevicesChanged(profileID: profileID)
        case "automation.changed":
            guard case .automationChanged = event.preparation else { return }
            delegate?.dashboardPoolAutomationChanged(profileID: profileID)
        case "transport.disconnected":
            guard isCurrent(profileID: profileID, client: entry.client, generation: generation),
                  entries[profileID]?.connectionID == delivery.connectionID else { return }
            entries[profileID]?.recorder.noteDisconnected(
                profileID: profileID, lifecycleGeneration: generation,
                foreground: true, cause: "transport"
            )
            retireConnectionEpoch(profileID: profileID, generation: generation, state: .reconnecting)
            scheduleReconnect(profileID: profileID, generation: generation)
        case "system.stopping":
            entries[profileID]?.recorder.noteDisconnected(
                profileID: profileID, lifecycleGeneration: generation,
                foreground: true, cause: "restart"
            )
            retireConnectionEpoch(profileID: profileID, generation: generation, state: .restarting)
            scheduleReconnect(profileID: profileID, generation: generation, immediate: true)
        default:
            break
        }
    }

    func notePathHint(profileID: String, satisfied: Bool) {
        guard var entry = entries[profileID] else { return }
        let pathChanged = entry.networkPathSatisfied != satisfied
        entry.networkPathSatisfied = satisfied
        entries[profileID] = entry
        guard !nonRetryableProfiles.contains(profileID), entry.connectionID == nil,
              entry.state != .connecting else { return }
        guard satisfied else {
            if entry.reconnectWaiting {
                entry.reconnectSchedule.cancel()
                entry.reconnectTask?.cancel()
                entries[profileID]?.reconnectTask = nil
                entries[profileID]?.reconnectWaiting = false
            }
            return
        }
        if entry.reconnectTask != nil, entry.reconnectWaiting {
            if pathChanged { entry.reconnectSchedule.accelerate() }
            return
        }
        scheduleReconnect(profileID: profileID, generation: entry.generation, immediate: true)
    }

    func retry(profileID: String) {
        guard let entry = entries[profileID], entry.refreshTask == nil,
              (entry.reconnectTask == nil || entry.reconnectWaiting),
              !(entry.state == .connecting && entry.connectionID == nil) else { return }
        if entry.reconnectWaiting {
            entry.reconnectTask?.cancel()
            entries[profileID]?.reconnectTask = nil
            entries[profileID]?.reconnectWaiting = false
        }
        let profile = entry.profile
        let token = entry.token
        let generation = entry.generation
        nonRetryableProfiles.remove(profileID)
        let recovery = entry.recovery
        stop(profileID: profileID)
        recovery.failedAttempts = 0
        recovery.stopReason = nil
        recoveryStates[profileID] = recovery
        start(profile: profile, token: token, generation: generation)
    }

    private func scheduleReconnect(profileID: String, generation: Int, immediate: Bool = false) {
        guard let entry = entries[profileID], entry.generation == generation,
              entry.networkPathSatisfied, !nonRetryableProfiles.contains(profileID) else { return }
        if immediate, entry.reconnectTask != nil {
            guard entry.reconnectWaiting else { return }
            entry.reconnectSchedule.accelerate()
            return
        }
        guard entries[profileID]?.reconnectTask == nil else { return }
        entries[profileID]?.reconnectWaiting = false
        let loopID = UUID().uuidString
        let clock = self.clock
        entries[profileID]?.reconnectLoopID = loopID
        let task = Task { @MainActor [weak self, clock] in
            defer {
                if let self, self.entries[profileID]?.reconnectLoopID == loopID {
                    self.entries[profileID]?.reconnectLoopID = nil
                    self.entries[profileID]?.attemptInFlightLoopID = nil
                    self.entries[profileID]?.reconnectTask = nil
                    self.entries[profileID]?.reconnectWaiting = false
                }
            }
            var shouldWait = !immediate
            var retry = 0
            var delayStartedAt = clock.now()
            while !Task.isCancelled {
                guard let self, let waitingEntry = self.entries[profileID], waitingEntry.generation == generation else { return }
                if shouldWait {
                    self.entries[profileID]?.reconnectWaiting = true
                    delayStartedAt = clock.now()
                    let delayCompleted = await waitingEntry.reconnectSchedule.afterFailure(
                        delay: Self.retryDelay(failedAttempts: waitingEntry.recovery.failedAttempts)
                    )
                    guard !Task.isCancelled else { return }
                    guard delayCompleted || self.entries[profileID]?.networkPathSatisfied == true else { return }
                }
                guard !Task.isCancelled, self.isCurrent(profileID: profileID, client: waitingEntry.client, generation: generation),
                      self.entries[profileID]?.networkPathSatisfied == true else { return }
                self.entries[profileID]?.reconnectWaiting = false
                guard !Task.isCancelled,
                      let entry = self.entries[profileID],
                      entry.generation == generation else { return }
                retry += 1
                let startedAt = clock.now()
                self.entries[profileID]?.attemptInFlightLoopID = loopID
                let diagnosticSequence = await entry.client.latestDiagnosticSequence()
                guard self.isCurrent(profileID: profileID, client: entry.client, generation: generation) else { return }
                do {
                    let identity = try await entry.client.reconnectForLifecycle(
                        profile: entry.profile, token: entry.token,
                        activateEvents: true,
                        attemptID: loopID
                    )
                    try Task.checkCancellation()
                    guard self.isCurrent(profileID: profileID, client: entry.client, generation: generation) else { return }
                    let info = identity.info
                    guard Self.admitsIdentity(info, for: entry.profile) else {
                        await entry.client.closeIfCurrent(connectionID: identity.id)
                        throw GatewayFailure(
                            code: "identity_mismatch",
                            message: "The paired server identity no longer matches this endpoint.",
                            retryable: false,
                            details: nil
                        )
                    }
                    guard self.isCurrent(profileID: profileID, client: entry.client, generation: generation) else { return }
                    self.entries[profileID]?.gatewayInfo = info
                    entry.reconnectSchedule.reset()
                    entry.recovery.failedAttempts = 0
                    entry.recovery.lastConnectedAt = Date()
                    entry.recovery.stopReason = nil
                    self.entries[profileID]?.state = .connecting
                    self.publish(profileID: profileID)
                    let connectionID = identity.id
                    guard self.isCurrent(profileID: profileID, client: entry.client, generation: generation) else { return }
                    self.entries[profileID]?.connectionID = connectionID
                    self.recordAttempt(
                        profileID: profileID,
                        generation: generation,
                        attemptID: loopID,
                        retry: retry,
                        startedAt: startedAt,
                        delayBeforeMs: diagnosticMilliseconds(delayStartedAt.duration(to: startedAt)),
                        diagnostic: nil,
                        reason: nil,
                        succeeded: true,
                        connectionID: connectionID,
                        gatewayConnectionID: identity.gatewayConnectionID
                    )
                    self.entries[profileID]?.reconnectTask = nil
                    self.scheduleRefresh(profileID: profileID, generation: generation, delay: .zero)
                    self.startEventConsumption(
                        profileID: profileID,
                        generation: generation,
                        client: entry.client,
                        connectionID: connectionID
                    )
                    return
                } catch is CancellationError {
                    return
                } catch let failure as GatewayFailure where GatewayRecoveryFailurePolicy.isNonRetryable(failure) {
                    guard !Task.isCancelled,
                          self.isCurrent(profileID: profileID, client: entry.client, generation: generation) else { return }
                    let diagnostic = await entry.client.latestHandshakeDiagnostic(after: diagnosticSequence)
                    guard self.isCurrent(profileID: profileID, client: entry.client, generation: generation) else { return }
                    self.nonRetryableProfiles.insert(profileID)
                    self.entries[profileID]?.gatewayInfo = nil
                    entry.recovery.stopReason = failure.message
                    self.entries[profileID]?.state = failure.code == "identity_mismatch" ? .identityMismatch : .offline
                    self.recordAttempt(
                        profileID: profileID,
                        generation: generation,
                        attemptID: loopID,
                        retry: retry,
                        startedAt: startedAt,
                        delayBeforeMs: diagnosticMilliseconds(delayStartedAt.duration(to: startedAt)),
                        diagnostic: diagnostic,
                        reason: GatewayDiagnosticFailure.answerCode(failure),
                        succeeded: false,
                        connectionID: nil
                    )
                    self.entries[profileID]?.recorder.endEpisode(
                        .stopped, profileID: profileID, lifecycleGeneration: generation
                    )
                    self.entries[profileID]?.reconnectTask = nil
                    self.publish(profileID: profileID)
                    return
                } catch {
                    guard !Task.isCancelled,
                          self.isCurrent(profileID: profileID, client: entry.client, generation: generation) else { return }
                    guard self.isCurrent(profileID: profileID, client: entry.client, generation: generation) else { return }
                    let diagnostic = await entry.client.latestHandshakeDiagnostic(after: diagnosticSequence)
                    guard self.isCurrent(profileID: profileID, client: entry.client, generation: generation) else { return }
                    let failureCode = GatewayDiagnosticFailure.code(error)
                    entry.recovery.failedAttempts += 1
                    let failedState = self.failedConnectionState(profileID: profileID)
                    self.recordAttempt(
                        profileID: profileID,
                        generation: generation,
                        attemptID: loopID,
                        retry: retry,
                        startedAt: startedAt,
                        delayBeforeMs: diagnosticMilliseconds(delayStartedAt.duration(to: startedAt)),
                        diagnostic: diagnostic,
                        reason: failureCode,
                        succeeded: false,
                        connectionID: nil
                    )
                    self.entries[profileID]?.state = failedState
                    self.publish(profileID: profileID)
                    shouldWait = true
                }
            }
        }
        entries[profileID]?.reconnectTask = task
    }

    private func failedConnectionState(profileID: String) -> DashboardServerConnectionState {
        guard let recovery = entries[profileID]?.recovery else { return .reconnecting }
        return recovery.failedAttempts >= Self.POOL_UNREACHABLE_AFTER ? .offline : .reconnecting
    }

    private static func retryDelay(failedAttempts: Int) -> Duration {
        let standardSteps = min(2, max(0, failedAttempts - 1))
        let escalatedSteps = min(3, max(0, failedAttempts - POOL_UNREACHABLE_AFTER))
        let seconds = ReconnectDelayPolicy.standard.initialSeconds
            * pow(ReconnectDelayPolicy.standard.multiplier, Double(standardSteps))
            * pow(4, Double(escalatedSteps))
        return .seconds(min(Double(POOL_MAX_RETRY.components.seconds), seconds))
    }

    private func stallGuard(profileID: String) -> GatewayReconnectStallGuard? {
        guard let entry = entries[profileID] else { return .other }
        if entry.reconnectLoopID != nil, entry.attemptInFlightLoopID == entry.reconnectLoopID { return nil }
        if entry.reconnectLoopID != nil, entry.reconnectTask != nil, entry.reconnectWaiting { return nil }
        if !entry.networkPathSatisfied { return .pathUnsatisfied }
        if nonRetryableProfiles.contains(profileID) { return .nonRetryable }
        if entry.reconnectTask != nil { return .reconnectTaskBusy }
        return .other
    }

    private func recordAttempt(
        profileID: String,
        generation: Int,
        attemptID: String,
        retry: Int,
        startedAt: ContinuousClock.Instant,
        delayBeforeMs: Int,
        diagnostic: GatewayConnectionDiagnostic?,
        reason: String?,
        succeeded: Bool,
        connectionID: Int?,
        gatewayConnectionID: String? = nil
    ) {
        guard let entry = entries[profileID], entry.generation == generation else { return }
        entry.recorder.recordAttempt(GatewayConnectionAttempt(
            owner: .pool,
            profileID: profileID,
            lifecycleGeneration: generation,
            connectionID: connectionID,
            attemptID: attemptID,
            retry: retry,
            stageReached: succeeded
                ? "connected"
                : diagnostic?.stage.rawValue ?? GatewayConnectionDiagnosticStage.transportOpen.rawValue,
            reason: reason,
            interfaces: diagnostic?.handshake?.networkInterfaces,
            pathSatisfied: entry.networkPathSatisfied,
            foreground: true,
            delayBeforeMs: delayBeforeMs,
            startedAt: startedAt,
            gatewayConnectionID: gatewayConnectionID,
            succeeded: succeeded
        ))
    }

    private enum RefreshOutcome {
        case published
        case retained
        case retryRead
        case transportFailure
    }

    private struct RefreshLeaseResult {
        let outcome: RefreshOutcome
        let needsImmediateFollowUp: Bool
    }

    private static let refreshCoalescingDelay: Duration = .milliseconds(250)

    private func scheduleRefresh(
        profileID: String,
        generation: Int,
        delay: Duration = DashboardGatewayConnectionPool.refreshCoalescingDelay
    ) {
        guard var entry = entries[profileID], entry.generation == generation else { return }
        entry.refreshInvalidationGeneration &+= 1
        entry.refreshRetryAttempt = 0
        entries[profileID] = entry
        startRefreshLease(profileID: profileID, generation: generation, delay: delay)
    }

    private func startRefreshLease(
        profileID: String,
        generation: Int,
        delay: Duration
    ) {
        guard var entry = entries[profileID],
              entry.generation == generation,
              let connectionID = entry.connectionID,
              entry.refreshTask == nil else { return }
        entry.refreshRequestGeneration &+= 1
        let requestGeneration = entry.refreshRequestGeneration
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do { try await self.clock.sleep(delay) } catch { return }
            guard !Task.isCancelled else { return }
            let result = await self.runRefreshLease(
                profileID: profileID,
                generation: generation,
                connectionID: connectionID,
                requestGeneration: requestGeneration
            )
            guard var current = self.entries[profileID],
                  current.generation == generation,
                  current.connectionID == connectionID,
                  current.refreshRequestGeneration == requestGeneration else { return }
            current.refreshTask = nil
            self.entries[profileID] = current
            if result.needsImmediateFollowUp
                && (result.outcome == .published || result.outcome == .retained) {
                self.startRefreshLease(profileID: profileID, generation: generation, delay: .zero)
            } else {
                if result.outcome == .published {
                    current.refreshFailedAttempts = 0
                } else {
                    current.refreshFailedAttempts = min(
                        DashboardCatalogRetryPolicy.unavailableNoticeAfterFailures,
                        current.refreshFailedAttempts + 1
                    )
                }
                if current.refreshFailedAttempts == DashboardCatalogRetryPolicy.unavailableNoticeAfterFailures {
                    current.catalog.markLoadUnavailable()
                    current.state = .stale
                }
                guard DashboardCatalogRetryPolicy.shouldRetry(
                    isRetryableFailure: result.outcome == .retryRead,
                    isCurrent: current.connectionID == connectionID
                ) else {
                    self.entries[profileID] = current
                    self.publish(profileID: profileID)
                    return
                }
                current.refreshRetryAttempt += 1
                self.entries[profileID] = current
                self.startRefreshLease(
                    profileID: profileID, generation: generation,
                    delay: reconnectDelayPolicy.delay(forFailureAttempt: current.refreshRetryAttempt)
                )
            }
        }
        entry.refreshTask = task
        entries[profileID] = entry
    }

    private func runRefreshLease(
        profileID: String,
        generation: Int,
        connectionID: Int,
        requestGeneration: Int
    ) async -> RefreshLeaseResult {
        var outcome: RefreshOutcome = .retained
        for traversal in 0..<2 {
            guard let entry = entries[profileID] else {
                return RefreshLeaseResult(outcome: .retained, needsImmediateFollowUp: false)
            }
            let observedInvalidation = entry.refreshInvalidationGeneration
            outcome = await performCatalogTraversal(
                profileID: profileID,
                generation: generation,
                connectionID: connectionID,
                requestGeneration: requestGeneration
            )
            guard admitsRefresh(
                profileID: profileID,
                generation: generation,
                connectionID: connectionID,
                requestGeneration: requestGeneration
            ) else {
                return RefreshLeaseResult(outcome: .retained, needsImmediateFollowUp: false)
            }
            if outcome == .published, var satisfied = entries[profileID] {
                satisfied.refreshSatisfiedGeneration = max(
                    satisfied.refreshSatisfiedGeneration,
                    observedInvalidation
                )
                entries[profileID] = satisfied
            }
            if outcome == .transportFailure || outcome == .retryRead {
                return RefreshLeaseResult(outcome: outcome, needsImmediateFollowUp: false)
            }
            guard let current = entries[profileID],
                  current.refreshInvalidationGeneration > observedInvalidation else {
                return RefreshLeaseResult(outcome: outcome, needsImmediateFollowUp: false)
            }
            if traversal == 1 {
                return RefreshLeaseResult(outcome: outcome, needsImmediateFollowUp: true)
            }
        }
        return RefreshLeaseResult(outcome: outcome, needsImmediateFollowUp: false)
    }

    private func performCatalogTraversal(
        profileID: String,
        generation: Int,
        connectionID: Int,
        requestGeneration: Int
    ) async -> RefreshOutcome {
        guard let seed = entries[profileID] else { return .retained }
        let key = SessionCatalogLoadKey(
            profileID: profileID,
            lifecycleGeneration: generation,
            connectionID: connectionID
        )
        guard var current = entries[profileID] else { return .retained }
        let admission = current.catalog.beginLoad(key: key)
        entries[profileID] = current
        do {
            let loaded = try await SessionCatalogLoader.load(
                client: seed.client,
                sinceToken: current.catalog.projectionToken
            ) {
                self.admitsRefresh(
                    profileID: profileID,
                    generation: generation,
                    connectionID: connectionID,
                    requestGeneration: requestGeneration
                ) && self.entries[profileID]?.catalog.admits(admission, key: key) == true
            }
            guard admitsRefresh(
                profileID: profileID,
                generation: generation,
                connectionID: connectionID,
                requestGeneration: requestGeneration
            ), var admitted = entries[profileID], admitted.catalog.admits(admission, key: key) else {
                return .retained
            }
            switch loaded {
            case let .loaded(rows, _, _, projectionToken, archivedCount):
                let sourced = rows.map { $0.withGatewaySource(id: profileID, label: seed.profile.label) }
                guard admitted.catalog.publishAuthoritative(
                    sourced,
                    admission: admission,
                    projectionToken: projectionToken,
                    archivedCount: archivedCount
                ) else { return .retained }
                admitted.state = .connected
                admitted.refreshRetryAttempt = 0
                admitted.refreshFailedAttempts = 0
                entries[profileID] = admitted
                publish(profileID: profileID)
                publishAuthoritativeCatalog(profileID: profileID)
                return .published
            case .unchanged:
                let wasLive = admitted.catalog.freshness == .live
                guard admitted.catalog.confirmUnchanged(admission: admission) else { return .retained }
                admitted.state = .connected
                admitted.refreshRetryAttempt = 0
                admitted.refreshFailedAttempts = 0
                entries[profileID] = admitted
                if !wasLive {
                    publish(profileID: profileID)
                    publishAuthoritativeCatalog(profileID: profileID)
                }
                return .published
            case .revisionMoved, .invalid:
                return .retained
            case .retired:
                return .retained
            }
        } catch is CancellationError {
            return .retained
        } catch {
            guard DashboardCatalogRetryPolicy.isRetryableFailure(error) else { return .retained }
            return await catalogFailureOutcome(
                seed: seed,
                profileID: profileID,
                generation: generation,
                connectionID: connectionID,
                requestGeneration: requestGeneration
            )
        }
    }

    private func catalogFailureOutcome(
        seed: Entry,
        profileID: String,
        generation: Int,
        connectionID: Int,
        requestGeneration: Int
    ) async -> RefreshOutcome {
        guard admitsRefresh(
            profileID: profileID,
            generation: generation,
            connectionID: connectionID,
            requestGeneration: requestGeneration
        ) else { return .retained }
        do {
            try await seed.client.ensureResponsive(maximumSilence: .zero)
            let activeConnectionID = await seed.client.activeConnectionID()
            guard admitsRefresh(
                profileID: profileID,
                generation: generation,
                connectionID: connectionID,
                requestGeneration: requestGeneration
            ), activeConnectionID == connectionID else { return .retained }
            if entries[profileID]?.catalog.freshness == .live {
                entries[profileID]?.state = .connected
            } else {
                entries[profileID]?.state = .stale
            }
            publish(profileID: profileID)
            return .retryRead
        } catch {
            guard isCurrent(profileID: profileID, client: seed.client, generation: generation) else {
                return .retained
            }
            await seed.client.closeIfCurrent(connectionID: connectionID)
            seed.recorder.noteDisconnected(
                profileID: profileID, lifecycleGeneration: generation,
                foreground: true, cause: GatewayDiagnosticFailure.code(error)
            )
            retireConnectionEpoch(profileID: profileID, generation: generation, state: .reconnecting)
            scheduleReconnect(profileID: profileID, generation: generation)
            return .transportFailure
        }
    }

    private func admitsRefresh(
        profileID: String,
        generation: Int,
        connectionID: Int,
        requestGeneration: Int
    ) -> Bool {
        guard let entry = entries[profileID] else { return false }
        return entry.generation == generation
            && entry.connectionID == connectionID
            && entry.refreshRequestGeneration == requestGeneration
    }

    private func retireConnectionEpoch(
        profileID: String,
        generation: Int,
        state: DashboardServerConnectionState
    ) {
        guard var entry = entries[profileID], entry.generation == generation else { return }
        entry.refreshTask?.cancel()
        entry.refreshTask = nil
        entry.refreshRequestGeneration &+= 1
        entry.refreshRetryAttempt = 0
        entry.refreshFailedAttempts = 0
        entry.eventTask?.cancel()
        entry.eventTask = nil
        entry.connectionID = nil
        entry.state = state
        entry.catalog.markDisconnected()
        entries[profileID] = entry
        publish(profileID: profileID)
        publishAuthoritativeCatalog(profileID: profileID)
    }

    private func publish(profileID: String) {
        guard let entry = entries[profileID] else { return }
        delegate?.dashboardPoolDidUpdate(
            profileID: profileID,
            sessions: entry.catalog.sessions,
            state: entry.state,
            stopReason: entry.recovery.stopReason
        )
        delegate?.dashboardPoolDidUpdateArchivedCount(
            profileID: profileID,
            count: entry.catalog.archivedCount
        )
    }

    private func publishAuthoritativeCatalog(profileID: String) {
        delegate?.dashboardPoolDidPublishAuthoritativeCatalog(profileID: profileID)
    }
}
