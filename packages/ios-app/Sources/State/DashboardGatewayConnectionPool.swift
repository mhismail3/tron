import Foundation

enum DashboardCatalogRetryPolicy {
    nonisolated static func shouldRetry(
        isDirty: Bool,
        isCurrent: Bool,
        transportFailed: Bool
    ) -> Bool {
        isDirty && isCurrent && !transportFailed
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
}

extension DashboardGatewayConnectionPoolDelegate {
    func dashboardPoolAutomationChanged(profileID: String) {}
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
        var generation: Int
        var refreshInvalidationGeneration: Int
        var refreshSatisfiedGeneration: Int
        var refreshRequestGeneration: Int
        var refreshRetryAttempt: Int
    }

    weak var delegate: (any DashboardGatewayConnectionPoolDelegate)?
    private let clientFactory: @MainActor () -> GatewayClient
    private let clock: MonotonicClock
    private var entries: [String: Entry] = [:]
    private var generation = 0
    private var retirementTask: Task<Void, Never>?

    init(
        clientFactory: @escaping @MainActor () -> GatewayClient = { GatewayClient() },
        clock: MonotonicClock = .continuous
    ) {
        self.clientFactory = clientFactory
        self.clock = clock
    }

    func reconcile(
        profiles: [GatewayProfile],
        selectedProfileID: String?,
        token: @escaping (GatewayProfile) -> String?
    ) {
        generation &+= 1
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
        let clients = Array(entries.values).map(\.client)
        for profileID in Array(entries.keys) { stop(profileID: profileID, close: false) }
        let previous = retirementTask
        retirementTask = Task { @MainActor in
            await previous?.value
            for client in clients { await client.close() }
        }
    }

    func waitForRetirement() async {
        await retirementTask?.value
    }

    func state(for profileID: String) -> DashboardServerConnectionState? {
        entries[profileID]?.state
    }

    func infoSnapshot(for profileID: String) -> GatewayInfo? {
        entries[profileID]?.gatewayInfo
    }

    func request(
        profileID: String,
        method: String,
        params: JSONValue,
        timeout: Duration = .seconds(15)
    ) async throws -> JSONValue {
        guard let client = entries[profileID]?.client else {
            throw GatewayFailure(code: "disconnected", message: "The Mac gateway is offline.", retryable: true, details: nil)
        }
        return try await client.requestValue(method, params, timeout: timeout)
    }

    func info(for profileID: String) async -> GatewayInfo? {
        guard let client = entries[profileID]?.client else { return nil }
        return await client.info
    }

    func diagnostics(for profileID: String) -> GatewayDiagnosticsService? {
        guard let client = entries[profileID]?.client else { return nil }
        return GatewayDiagnosticsService(client: client)
    }

    func notificationInbox(for profileID: String) async throws -> NotificationInboxGatewayClient.Snapshot {
        guard let client = entries[profileID]?.client else {
            throw GatewayFailure(code: "disconnected", message: "The Mac gateway is offline.", retryable: true, details: nil)
        }
        return try await NotificationInboxGatewayClient.list(client: client)
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
            generation: generation,
            refreshInvalidationGeneration: 0,
            refreshSatisfiedGeneration: 0,
            refreshRequestGeneration: 0,
            refreshRetryAttempt: 0
        )
        publish(profileID: profile.id)
        let task = Task { @MainActor [weak self] in
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
                guard let self, let connectionID,
                      self.isCurrent(profileID: profile.id, client: client, generation: generation) else { return }
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
                    self.handle(delivery, profileID: profile.id, generation: generation)
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
            } catch let failure as GatewayFailure where failure.code == "identity_mismatch" {
                await client.close()
                guard let self,
                      self.isCurrent(profileID: profile.id, client: client, generation: generation) else { return }
                self.entries[profile.id]?.gatewayInfo = nil
                self.entries[profile.id]?.state = .identityMismatch
                self.publish(profileID: profile.id)
            } catch {
                guard let self,
                      self.isCurrent(profileID: profile.id, client: client, generation: generation) else { return }
                self.retireConnectionEpoch(
                    profileID: profile.id,
                    generation: generation,
                    state: .reconnecting
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
        delegate?.dashboardPoolDidUpdate(
            profileID: profileID,
            sessions: entry.catalog.sessions,
            state: .offline
        )
        if close { Task { await entry.client.close() } }
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
    ) {
        guard let entry = entries[profileID],
              entry.connectionID == delivery.connectionID,
              isCurrent(profileID: profileID, client: entry.client, generation: generation) else { return }
        let event = delivery.event
        switch event.topic {
        case "session.summary":
            guard case .sessionSummary(let update) = event.preparation,
                  var current = entries[profileID] else { return }
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
        case "automation.changed":
            guard case .automationChanged = event.preparation else { return }
            delegate?.dashboardPoolAutomationChanged(profileID: profileID)
        case "transport.disconnected":
            retireConnectionEpoch(profileID: profileID, generation: generation, state: .reconnecting)
            scheduleReconnect(profileID: profileID, generation: generation)
        case "system.stopping":
            retireConnectionEpoch(profileID: profileID, generation: generation, state: .restarting)
            scheduleReconnect(profileID: profileID, generation: generation, immediate: true)
        default:
            break
        }
    }

    private func scheduleReconnect(profileID: String, generation: Int, immediate: Bool = false) {
        guard let entry = entries[profileID], entry.generation == generation else { return }
        if immediate, let existing = entry.reconnectTask {
            existing.cancel()
            entries[profileID]?.reconnectTask = nil
        }
        guard entries[profileID]?.reconnectTask == nil else { return }
        let clock = self.clock
        let task = Task { @MainActor [weak self, clock] in
            var delay: Duration = immediate ? .zero : .seconds(2)
            while !Task.isCancelled {
                if delay > .zero { try? await clock.sleep(delay) }
                guard !Task.isCancelled, let self,
                      let entry = self.entries[profileID],
                      entry.generation == generation else { return }
                do {
                    let info = try await entry.client.reconnect()
                    guard Self.admitsIdentity(info, for: entry.profile) else {
                        throw GatewayFailure(
                            code: "identity_mismatch",
                            message: "The paired server identity no longer matches this endpoint.",
                            retryable: false,
                            details: nil
                        )
                    }
                    guard self.isCurrent(profileID: profileID, client: entry.client, generation: generation) else { return }
                    self.entries[profileID]?.gatewayInfo = info
                    self.entries[profileID]?.state = .connecting
                    self.publish(profileID: profileID)
                    let connectionID = await entry.client.activeConnectionID()
                    guard let connectionID,
                          self.isCurrent(profileID: profileID, client: entry.client, generation: generation) else { return }
                    self.entries[profileID]?.connectionID = connectionID
                    self.entries[profileID]?.reconnectTask = nil
                    self.scheduleRefresh(profileID: profileID, generation: generation, delay: .zero)
                    return
                } catch is CancellationError {
                    return
                } catch let failure as GatewayFailure where failure.code == "identity_mismatch" {
                    self.entries[profileID]?.gatewayInfo = nil
                    self.entries[profileID]?.state = .identityMismatch
                    self.publish(profileID: profileID)
                    return
                } catch {
                    self.entries[profileID]?.state = .reconnecting
                    self.publish(profileID: profileID)
                    delay = Self.nextReconnectDelay(after: delay)
                }
            }
        }
        entries[profileID]?.reconnectTask = task
    }

    nonisolated static func nextReconnectDelay(after current: Duration) -> Duration {
        current == .zero ? .seconds(2) : min(current * 2, .seconds(15))
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

    /// Structural events coalesce into one bounded per-profile lease. An
    /// active traversal is never cancelled merely because a newer event arrives.
    private func scheduleRefresh(
        profileID: String,
        generation: Int,
        delay: Duration = .milliseconds(250)
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
            let remainsDirty = current.refreshSatisfiedGeneration < current.refreshInvalidationGeneration
            if result.needsImmediateFollowUp {
                self.startRefreshLease(profileID: profileID, generation: generation, delay: .zero)
            } else if DashboardCatalogRetryPolicy.shouldRetry(
                isDirty: remainsDirty,
                isCurrent: true,
                transportFailed: result.outcome == .transportFailure
            ) {
                current.refreshRetryAttempt = min(3, current.refreshRetryAttempt + 1)
                self.entries[profileID] = current
                self.startRefreshLease(
                    profileID: profileID,
                    generation: generation,
                    delay: Self.refreshRetryDelay(attempt: current.refreshRetryAttempt)
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
        struct Params: Encodable { let cursor: String?; let limit: Int; let scope: String }
        struct Response: Decodable {
            let sessions: [SessionSummary]
            let nextCursor: String?
            let listRevision: Int
        }
        guard let seed = entries[profileID] else { return .retained }
        let key = SessionCatalogLoadKey(
            profileID: profileID,
            lifecycleGeneration: generation,
            connectionID: connectionID
        )

        for revisionAttempt in 0..<2 {
            guard var current = entries[profileID] else { return .retained }
            let admission = current.catalog.beginLoad(key: key)
            entries[profileID] = current
            var requestedContinuation = false
            do {
                var all: [SessionSummary] = []
                var cursor: String?
                var seenCursors = Set<String>()
                var seenSessionIDs = Set<String>()
                var expectedRevision: Int?
                var revisionChanged = false
                var pageCount = 0
                repeat {
                    guard pageCount < 50 else {
                        throw Self.invalidDashboardCatalog("The server returned too many dashboard pages.")
                    }
                    requestedContinuation = cursor != nil
                    let response: Response = try await seed.client.request(
                        "session.list",
                        Params(cursor: cursor, limit: 500, scope: "user"),
                        timeout: .seconds(10)
                    )
                    guard admitsRefresh(
                        profileID: profileID,
                        generation: generation,
                        connectionID: connectionID,
                        requestGeneration: requestGeneration
                    ), let admitted = entries[profileID],
                       admitted.catalog.admits(admission, key: key) else { return .retained }
                    pageCount += 1
                    if let expectedRevision, expectedRevision != response.listRevision {
                        revisionChanged = true
                        break
                    }
                    expectedRevision = response.listRevision
                    guard response.sessions.count <= 500,
                          all.count <= 25_000 - response.sessions.count,
                          response.sessions.allSatisfy({ seenSessionIDs.insert($0.id).inserted }) else {
                        throw Self.invalidDashboardCatalog("The server returned an invalid dashboard page.")
                    }
                    all.append(contentsOf: response.sessions.map {
                        $0.withGatewaySource(id: profileID, label: seed.profile.label)
                    })
                    cursor = response.nextCursor
                    if let cursor, !seenCursors.insert(cursor).inserted {
                        throw Self.invalidDashboardCatalog("The server returned a repeated dashboard cursor.")
                    }
                } while cursor != nil

                if revisionChanged {
                    if revisionAttempt == 0 { continue }
                    return .retryRead
                }
                guard var published = entries[profileID],
                      published.catalog.publishAuthoritative(all, admission: admission) else { return .retained }
                published.state = .connected
                published.refreshRetryAttempt = 0
                entries[profileID] = published
                publish(profileID: profileID)
                return .published
            } catch is CancellationError {
                return .retained
            } catch let failure as GatewayFailure
                where requestedContinuation && failure.code == "invalid_request" && revisionAttempt == 0 {
                guard admitsRefresh(
                    profileID: profileID,
                    generation: generation,
                    connectionID: connectionID,
                    requestGeneration: requestGeneration
                ) else { return .retained }
                continue
            } catch {
                return await catalogFailureOutcome(
                    seed: seed,
                    profileID: profileID,
                    generation: generation,
                    connectionID: connectionID,
                    requestGeneration: requestGeneration
                )
            }
        }
        return .retained
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
        entry.connectionID = nil
        entry.state = state
        entry.catalog.markDisconnected()
        entries[profileID] = entry
        publish(profileID: profileID)
    }

    private static func refreshRetryDelay(attempt: Int) -> Duration {
        .seconds(min(8, 1 << min(3, max(1, attempt))))
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
