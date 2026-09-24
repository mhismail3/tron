import Foundation

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
        sessions: [SessionSummary],
        state: DashboardServerConnectionState
    )
    func dashboardPoolNotificationInboxChanged(profileID: String)
    func dashboardPoolAutomationChanged(profileID: String)
    func dashboardPoolDevicesChanged(profileID: String)
}

extension DashboardGatewayConnectionPoolDelegate {
    func dashboardPoolAutomationChanged(profileID: String) {}
    func dashboardPoolDevicesChanged(profileID: String) {}
}

/// Maintains lightweight dashboard catalog connections for non-focused servers.
/// The focused chat remains owned by GatewayLifecycleCoordinator; each other
/// profile has an independent connection and failure boundary.
@MainActor
final class DashboardGatewayConnectionPool {
    private struct Entry {
        let profile: GatewayProfile
        let token: String
        let client: GatewayClient
        var connectionID: Int?
        var gatewayInfo: GatewayInfo?
        var state: DashboardServerConnectionState
        var catalog: SessionCatalogCoordinator
        var task: Task<Void, Never>?
        var refreshTask: Task<Void, Never>?
        var reconnectTask: Task<Void, Never>?
        let reconnectSchedule: GatewayReconnectSchedule
        var reconnectWaiting: Bool
        var networkPathSatisfied: Bool
        var generation: Int
        var refreshInvalidationGeneration: Int
        var refreshSatisfiedGeneration: Int
        var refreshRequestGeneration: Int
        var refreshRetryAttempt: Int
        var refreshFailedAttempts: Int
        var connectionFailureClassifier: GatewayConnectionFailureClassifier
    }

    weak var delegate: (any DashboardGatewayConnectionPoolDelegate)?
    private let clientFactory: @MainActor () -> GatewayClient
    private let clock: MonotonicClock
    private let reconnectDelayPolicy: ReconnectDelayPolicy
    private var entries: [String: Entry] = [:]
    private var generation = 0
    private var retirementTasks: [String: (generation: Int, task: Task<Void, Never>)] = [:]
    private var nonRetryableProfiles = Set<String>()

    init(
        clientFactory: @escaping @MainActor () -> GatewayClient = { GatewayClient() },
        clock: MonotonicClock = .continuous,
        reconnectDelayPolicy: ReconnectDelayPolicy = .standard
    ) {
        self.clientFactory = clientFactory
        self.clock = clock
        self.reconnectDelayPolicy = reconnectDelayPolicy
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
        for profileID in Array(entries.keys) {
            guard let profile = desired.first(where: { $0.id == profileID }),
                  let current = entries[profileID],
                  let currentToken = token(profile) else {
                if !desiredIDs.contains(profileID) { stop(profileID: profileID) }
                continue
            }
            if current.profile != profile || current.token != currentToken {
                stop(profileID: profileID)
            }
        }
        for profile in desired where entries[profile.id] == nil {
            start(profile: profile, token: token(profile), generation: generation)
        }
    }

    func retire() {
        generation &+= 1
        for profileID in Array(entries.keys) { stop(profileID: profileID) }
    }

    func waitForRetirement() async {
        for retirement in Array(retirementTasks.values) { await retirement.task.value }
    }

    func state(for profileID: String) -> DashboardServerConnectionState? {
        entries[profileID]?.state
    }

    func infoSnapshot(for profileID: String) -> GatewayInfo? {
        entries[profileID]?.gatewayInfo
    }

    func connectionID(for profileID: String) async -> Int? {
        guard let entry = entries[profileID] else { return nil }
        return await entry.client.activeConnectionID()
    }

    /// MainActor projection used only for bounded presentation admission keys.
    /// The pool's connection entry remains the authority; this is not a cache
    /// of transport state and is refreshed whenever the pool publishes.
    func connectionIDSnapshot(for profileID: String) -> Int? {
        entries[profileID]?.connectionID
    }

    /// Policy demand must distinguish replacement clients whose local epoch
    /// counters can both start at one. No transport state is retained here.
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
        cursor: String? = nil,
        revision: String? = nil,
        connectionID: Int? = nil
    ) async throws -> NotificationInboxGatewayClient.Snapshot {
        guard let client = entries[profileID]?.client else {
            throw GatewayFailure(code: "disconnected", message: "The Mac gateway is offline.", retryable: true, details: nil)
        }
        return try await NotificationInboxGatewayClient.list(
            client: client,
            cursor: cursor,
            expectedRevision: revision,
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

    func markAllNotificationsRead(profileID: String, commandID: String) async throws {
        guard let client = entries[profileID]?.client else {
            throw GatewayFailure(code: "disconnected", message: "The Mac gateway is offline.", retryable: true, details: nil)
        }
        try await NotificationInboxGatewayClient.markAllRead(client: client, commandID: commandID)
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
            // Older stored profiles use machineId as a provisional group.
            // Select once to handshake and persist the real physical group
            // before allowing a secondary background connection.
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
        entries[profile.id] = Entry(
            profile: profile,
            token: token,
            client: client,
            connectionID: nil,
            gatewayInfo: nil,
            state: .connecting,
            catalog: SessionCatalogCoordinator(),
            task: nil,
            refreshTask: nil,
            reconnectTask: nil,
            reconnectSchedule: GatewayReconnectSchedule(clock: clock),
            reconnectWaiting: false,
            networkPathSatisfied: true,
            generation: generation,
            refreshInvalidationGeneration: 0,
            refreshSatisfiedGeneration: 0,
            refreshRequestGeneration: 0,
            refreshRetryAttempt: 0,
            refreshFailedAttempts: 0,
            connectionFailureClassifier: GatewayConnectionFailureClassifier()
        )
        publish(profileID: profile.id)
        let task = Task { @MainActor [weak self] in
            await retirementBarrier?.value
            guard let self,
                  !Task.isCancelled,
                  self.isCurrent(profileID: profile.id, client: client, generation: generation) else { return }
            let failurePresentationGeneration = self.entries[profile.id]?.connectionFailureClassifier.beginAttempt()
            let diagnosticSequence = await client.latestDiagnosticSequence()
            guard self.isCurrent(profileID: profile.id, client: client, generation: generation) else { return }
            do {
                let info = try await client.connect(profile: profile, token: token)
                guard Self.admitsIdentity(info, for: profile) else {
                    throw GatewayFailure(
                        code: "identity_mismatch",
                        message: "The paired server identity no longer matches this endpoint.",
                        retryable: false,
                        details: nil
                    )
                }
                let connectionID = await client.activeConnectionID()
                guard let connectionID, !Task.isCancelled,
                      self.isCurrent(profileID: profile.id, client: client, generation: generation) else { return }
                self.entries[profile.id]?.reconnectSchedule.reset()
                self.entries[profile.id]?.connectionFailureClassifier.reset()
                self.entries[profile.id]?.connectionID = connectionID
                self.entries[profile.id]?.gatewayInfo = info
                self.entries[profile.id]?.state = .connecting
                self.publish(profileID: profile.id)
                self.scheduleRefresh(
                    profileID: profile.id,
                    generation: generation,
                    delay: .zero
                )
                for await delivery in client.events {
                    guard !Task.isCancelled,
                          self.isCurrent(profileID: profile.id, client: client, generation: generation) else { return }
                    await self.handle(delivery, profileID: profile.id, generation: generation)
                }
                guard !Task.isCancelled,
                      self.isCurrent(profileID: profile.id, client: client, generation: generation) else { return }
                self.retireConnectionEpoch(
                    profileID: profile.id,
                    generation: generation,
                    state: .reconnecting
                )
                self.scheduleReconnect(profileID: profile.id, generation: generation)
            } catch is CancellationError {
                return
            } catch let failure as GatewayFailure where GatewayRecoveryFailurePolicy.isNonRetryable(failure) {
                await client.close()
                guard self.isCurrent(profileID: profile.id, client: client, generation: generation) else { return }
                self.nonRetryableProfiles.insert(profile.id)
                self.entries[profile.id]?.gatewayInfo = nil
                self.entries[profile.id]?.state = failure.code == "identity_mismatch" ? .identityMismatch : .offline
                self.publish(profileID: profile.id)
            } catch {
                guard !Task.isCancelled,
                      self.isCurrent(profileID: profile.id, client: client, generation: generation) else { return }
                let diagnostic = await client.latestHandshakeDiagnostic(after: diagnosticSequence)
                guard self.isCurrent(profileID: profile.id, client: client, generation: generation) else { return }
                if let failurePresentationGeneration {
                    _ = self.entries[profile.id]?.connectionFailureClassifier.failedAttempt(
                        diagnostic,
                        code: GatewayDiagnosticFailure.code(error),
                        attemptGeneration: failurePresentationGeneration
                    )
                }
                let failedState = self.entries[profile.id]?.connectionFailureClassifier.noPath
                    .map { DashboardServerConnectionState.noPath($0.interface) } ?? .reconnecting
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

    private func stop(profileID: String, close: Bool = true) {
        guard let entry = entries.removeValue(forKey: profileID) else { return }
        entry.task?.cancel()
        entry.refreshTask?.cancel()
        entry.reconnectTask?.cancel()
        entry.reconnectSchedule.cancel()
        delegate?.dashboardPoolDidUpdate(
            profileID: profileID,
            sessions: entry.catalog.sessions,
            state: .offline
        )
        if close {
            let previous = retirementTasks[profileID]?.task
            let task = Task { @MainActor [weak self] in
                await previous?.value
                await entry.client.close()
                guard let self else { return }
                // A predecessor must not erase the successor that joined it.
                // Replacement admission observes the tail of this exact chain.
                if self.retirementTasks[profileID]?.generation == entry.generation {
                    self.retirementTasks[profileID] = nil
                }
            }
            retirementTasks[profileID] = (entry.generation, task)
        }
        // Retiring a background transport is not deletion of its bounded
        // dashboard projection. The AppModel keeps the last-known bucket while
        // this profile reconnects, is blocked, or is temporarily unadmitted.
    }

    private func isCurrent(profileID: String, client: GatewayClient, generation: Int) -> Bool {
        guard let entry = entries[profileID] else { return false }
        return entry.client === client && entry.generation == generation
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
                // Do not leave a background dashboard row stale when a Gateway
                // sends a summary shape this client cannot decode. Its bounded
                // catalog read is the authoritative recovery path.
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
            delegate?.dashboardPoolNotificationInboxChanged(profileID: profileID)
        case "devices.changed":
            delegate?.dashboardPoolDevicesChanged(profileID: profileID)
        case "automation.changed":
            guard case .automationChanged = event.preparation else { return }
            delegate?.dashboardPoolAutomationChanged(profileID: profileID)
        case "transport.disconnected":
            guard isCurrent(profileID: profileID, client: entry.client, generation: generation),
                  entries[profileID]?.connectionID == delivery.connectionID else { return }
            entries[profileID]?.connectionFailureClassifier.failedAttempt(nil, code: "transport")
            retireConnectionEpoch(profileID: profileID, generation: generation, state: .reconnecting)
            scheduleReconnect(profileID: profileID, generation: generation)
        case "system.stopping":
            retireConnectionEpoch(profileID: profileID, generation: generation, state: .restarting)
            scheduleReconnect(profileID: profileID, generation: generation, immediate: true)
        default:
            break
        }
    }

    /// Path hints are advisory per profile. A satisfied return hint can revive
    /// a parked secondary entry even when its previous callback was missed.
    func notePathHint(profileID: String, satisfied: Bool) {
        guard var entry = entries[profileID] else { return }
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
            entry.reconnectSchedule.accelerate()
            return
        }
        scheduleReconnect(profileID: profileID, generation: entry.generation, immediate: true)
    }

    /// Explicit user retry clears this profile's nonretryable stop; background
    /// retirement and navigation never do so.
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
        stop(profileID: profileID)
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
        let task = Task { @MainActor [weak self, clock] in
            var shouldWait = !immediate
            while !Task.isCancelled {
                guard let self, let waitingEntry = self.entries[profileID], waitingEntry.generation == generation else { return }
                if shouldWait {
                    self.entries[profileID]?.reconnectWaiting = true
                    let delayCompleted = await waitingEntry.reconnectSchedule.afterFailure()
                    guard !Task.isCancelled else { return }
                    guard delayCompleted || self.entries[profileID]?.networkPathSatisfied == true else {
                        self.entries[profileID]?.reconnectTask = nil
                        return
                    }
                }
                guard !Task.isCancelled, self.isCurrent(profileID: profileID, client: waitingEntry.client, generation: generation),
                      self.entries[profileID]?.networkPathSatisfied == true else { return }
                self.entries[profileID]?.reconnectWaiting = false
                guard !Task.isCancelled,
                      let entry = self.entries[profileID],
                      entry.generation == generation else { return }
                let failurePresentationGeneration = self.entries[profileID]?.connectionFailureClassifier.beginAttempt()
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
                    self.entries[profileID]?.connectionFailureClassifier.reset()
                    self.entries[profileID]?.state = .connecting
                    self.publish(profileID: profileID)
                    let connectionID = identity.id
                    guard self.isCurrent(profileID: profileID, client: entry.client, generation: generation) else { return }
                    self.entries[profileID]?.connectionID = connectionID
                    self.entries[profileID]?.reconnectTask = nil
                    self.scheduleRefresh(profileID: profileID, generation: generation, delay: .zero)
                    return
                } catch is CancellationError {
                    return
                } catch let failure as GatewayFailure where GatewayRecoveryFailurePolicy.isNonRetryable(failure) {
                    guard !Task.isCancelled,
                          self.isCurrent(profileID: profileID, client: entry.client, generation: generation) else { return }
                    self.nonRetryableProfiles.insert(profileID)
                    self.entries[profileID]?.gatewayInfo = nil
                    self.entries[profileID]?.state = failure.code == "identity_mismatch" ? .identityMismatch : .offline
                    self.entries[profileID]?.reconnectTask = nil
                    self.publish(profileID: profileID)
                    return
                } catch {
                    guard !Task.isCancelled,
                          self.isCurrent(profileID: profileID, client: entry.client, generation: generation) else { return }
                    guard self.isCurrent(profileID: profileID, client: entry.client, generation: generation) else { return }
                    let diagnostic = await entry.client.latestHandshakeDiagnostic(after: diagnosticSequence)
                    guard self.isCurrent(profileID: profileID, client: entry.client, generation: generation) else { return }
                    if let failurePresentationGeneration {
                        _ = self.entries[profileID]?.connectionFailureClassifier.failedAttempt(
                            diagnostic,
                            code: GatewayDiagnosticFailure.code(error),
                            attemptGeneration: failurePresentationGeneration
                        )
                    }
                    let failedState = self.entries[profileID]?.connectionFailureClassifier.noPath
                        .map { DashboardServerConnectionState.noPath($0.interface) } ?? .reconnecting
                    self.entries[profileID]?.state = failedState
                    self.publish(profileID: profileID)
                    shouldWait = true
                }
            }
        }
        entries[profileID]?.reconnectTask = task
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

    // Coalesce bursts of structural events before opening one per-profile list traversal.
    private static let refreshCoalescingDelay: Duration = .milliseconds(250)

    /// Structural events coalesce into one bounded per-profile lease. An
    /// active traversal is never cancelled merely because a newer event arrives.
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
            if result.needsImmediateFollowUp && result.outcome == .published {
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
            let loaded = try await SessionCatalogLoader.load(client: seed.client) {
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
            case let .loaded(rows, _, _):
                let sourced = rows.map { $0.withGatewaySource(id: profileID, label: seed.profile.label) }
                guard admitted.catalog.publishAuthoritative(sourced, admission: admission) else { return .retained }
                admitted.state = .connected
                admitted.refreshRetryAttempt = 0
                admitted.refreshFailedAttempts = 0
                entries[profileID] = admitted
                publish(profileID: profileID)
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
            // A schema/application error on a responsive socket retires only
            // the read lease, not the transport or the last complete catalog.
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
                // The socket is responsive, but no complete catalog for this
                // epoch has published. Preserve any AppModel cache as stale.
                entries[profileID]?.state = .stale
            }
            publish(profileID: profileID)
            return .retryRead
        } catch {
            guard isCurrent(profileID: profileID, client: seed.client, generation: generation) else {
                return .retained
            }
            await seed.client.closeIfCurrent(connectionID: connectionID)
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
        entry.connectionID = nil
        entry.state = state
        entry.catalog.markDisconnected()
        entries[profileID] = entry
        publish(profileID: profileID)
    }

    private static func invalidDashboardCatalog(_ message: String) -> GatewayFailure {
        GatewayFailure(code: "invalid_dashboard_catalog", message: message, retryable: true, details: nil)
    }

    private func publish(profileID: String) {
        guard let entry = entries[profileID] else { return }
        delegate?.dashboardPoolDidUpdate(
            profileID: profileID,
            sessions: entry.catalog.sessions,
            state: entry.state
        )
    }
}
