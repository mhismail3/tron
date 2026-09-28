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
    func dashboardPoolNotificationInboxChanged(profileID: String, change: NotificationInboxChanged?)
    func dashboardPoolAutomationChanged(profileID: String)
    func dashboardPoolDevicesChanged(profileID: String)
    /// The Gateway-owned archived count for one background profile. `nil` means
    /// that profile has not published a count yet.
    func dashboardPoolDidUpdateArchivedCount(profileID: String, count: Int?)
    /// One background profile's catalog projection is authoritative again: it
    /// published a complete `session.list` page, or its connection epoch
    /// retired. The dashboard's archived container reads its rows from exactly
    /// those pages, so it must re-read even when the archived count is
    /// unchanged — a renamed archived session, or one archived while another is
    /// unarchived, changes rows and not the count.
    func dashboardPoolDidPublishAuthoritativeCatalog(profileID: String)
}

extension DashboardGatewayConnectionPoolDelegate {
    func dashboardPoolAutomationChanged(profileID: String) {}
    func dashboardPoolDevicesChanged(profileID: String) {}
}

/// Everything a background entry's connection, identity admission and catalog
/// projection depend on. The LAN advertisement is deliberately excluded: E-3b
/// replaces `lanEndpoints`/`lanPin` on every hello, and this pool dials the
/// saved endpoint rather than the lane, so a refreshed advertisement must not
/// stop and restart a working background connection.
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

/// Maintains lightweight dashboard catalog connections for non-focused servers.
/// The focused chat remains owned by GatewayLifecycleCoordinator; each other
/// profile has an independent connection and failure boundary.
@MainActor
final class DashboardGatewayConnectionPool {
    /// Consecutive failed attempts at one entry after which that profile is
    /// treated as unreachable: its retries escalate to `POOL_MAX_RETRY`, so a
    /// Mac that is not there costs a few attempts and then one every five
    /// minutes. Three rules out a blip.
    static let POOL_UNREACHABLE_AFTER = 3
    /// The longest wait between attempts for an unreachable background profile.
    static let POOL_MAX_RETRY: Duration = .seconds(300)
    /// A background entry's curve before it is unreachable: the selected
    /// profile's progression (2 s, ×1.7, 15 s cap) without jitter. It is not
    /// jittered so a pool wait is deterministic and its cap is a floor rather
    /// than a nominal average; the selected profile's lifecycle keeps its own
    /// jittered curve.
    private static let reconnectDelayPolicy = ReconnectDelayPolicy(
        initialSeconds: ReconnectDelayPolicy.standard.initialSeconds,
        multiplier: ReconnectDelayPolicy.standard.multiplier,
        maximumSeconds: ReconnectDelayPolicy.standard.maximumSeconds,
        jitterFraction: 0,
        nextUnitInterval: { 0.5 }
    )
    /// The curve a pool entry adopts once `POOL_UNREACHABLE_AFTER` attempts have
    /// failed in a row: four times longer each step, up to `POOL_MAX_RETRY`,
    /// still without jitter so the five-minute cap is a floor. It continues
    /// from the nominal delay the standard phase reached, so the switch never
    /// shortens a wait.
    private static let unreachableReconnectDelayPolicy = ReconnectDelayPolicy(
        initialSeconds: ReconnectDelayPolicy.standard.initialSeconds,
        multiplier: 4,
        maximumSeconds: Double(POOL_MAX_RETRY.components.seconds),
        jitterFraction: 0,
        nextUnitInterval: { 0.5 }
    )

    private struct Entry {
        let profile: GatewayProfile
        let token: String
        let client: GatewayClient
        /// One connection recorder per entry: attempts and episodes are
        /// attributable to the profile that made them, and two pool profiles
        /// write to the one always-on log without mixing timelines.
        let recorder: GatewayConnectionEpisodeRecorder
        var connectionID: Int?
        var gatewayInfo: GatewayInfo?
        var state: DashboardServerConnectionState
        var catalog: SessionCatalogCoordinator
        var task: Task<Void, Never>?
        var refreshTask: Task<Void, Never>?
        var reconnectTask: Task<Void, Never>?
        /// The reader of this entry's live connection events. The client's event
        /// stream is client-lifetime, so the reader is owned by the connection
        /// epoch it serves and is retired with it; an entry whose attempts have
        /// not connected yet has none.
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
        var connectionFailureClassifier: GatewayConnectionFailureClassifier
        /// The pool's own count of this entry's attempts that failed in a row.
        /// Only a successful attempt clears it; it decides when the retry curve
        /// escalates, unlike the display classifier, which stops counting an
        /// outage as never-opened as soon as one attempt opened a transport.
        var consecutiveFailedAttempts: Int
        /// The loop that owns `reconnectTask`, and the loop whose attempt is in
        /// flight. They are identities, not flags: a retired loop must not
        /// clear its successor's marker, and the stall watchdog reads them to
        /// tell a running attempt from a parked loop.
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
        for profileID in Array(entries.keys) {
            guard let profile = desired.first(where: { $0.id == profileID }),
                  let current = entries[profileID],
                  let currentToken = token(profile) else {
                if !desiredIDs.contains(profileID) { stop(profileID: profileID) }
                continue
            }
            if DashboardPoolProfileIdentity(current.profile) != DashboardPoolProfileIdentity(profile)
                || current.token != currentToken {
                stop(profileID: profileID)
            }
        }
        for profile in desired where entries[profile.id] == nil {
            start(profile: profile, token: token(profile), generation: generation)
        }
    }

    /// Retires every entry: the pool holds nothing until the next `reconcile`,
    /// which starts fresh entries and connects at once. That is why a real
    /// foreground cycle needs no backoff acceleration here.
    ///
    /// `endedBy` names who ended the open episodes. The scene suspension that
    /// parks every pool entry is a `background` retirement; the projection
    /// retirements of a profile switch, removal, pairing and teardown `stopped`
    /// them, exactly as a `stop` for a removed profile does.
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
        // One recorder per entry, but only the selected profile's recorder
        // pings the main actor: with one ping per open pool outage the same
        // main-thread stall would be recorded once per profile. The entry keeps
        // its own attempts, episodes and stall guard.
        let recorder = GatewayConnectionEpisodeRecorder(
            clock: clock, appLog: appLog, mainStallPing: {}
        )
        // `self` is unwrapped before the guard is read: folding the lookup into
        // one optional would turn "recovery is progressing" into `other` and
        // report a stall whenever an episode is open.
        recorder.stallGuard = { [weak self] in
            guard let self else { return nil }
            return self.stallGuard(profileID: profile.id)
        }
        entries[profile.id] = Entry(
            profile: profile,
            token: token,
            client: client,
            recorder: recorder,
            connectionID: nil,
            gatewayInfo: nil,
            state: .connecting,
            catalog: SessionCatalogCoordinator(),
            task: nil,
            refreshTask: nil,
            reconnectTask: nil,
            eventTask: nil,
            reconnectSchedule: GatewayReconnectSchedule(
                clock: clock, delayPolicy: Self.reconnectDelayPolicy
            ),
            reconnectWaiting: false,
            networkPathSatisfied: true,
            generation: generation,
            refreshInvalidationGeneration: 0,
            refreshSatisfiedGeneration: 0,
            refreshRequestGeneration: 0,
            refreshRetryAttempt: 0,
            refreshFailedAttempts: 0,
            connectionFailureClassifier: GatewayConnectionFailureClassifier(),
            consecutiveFailedAttempts: 0,
            reconnectLoopID: nil,
            attemptInFlightLoopID: nil
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
            let startedAt = self.clock.now()
            do {
                // The identity carries the hello's Gateway connection id, so the
                // first attempt of a pool profile is joinable to the Gateway's
                // own records exactly like its reconnects are.
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
                    // The hello's connection is already gone, or is no longer the
                    // one this client would serve: fail the attempt like any
                    // other, so the entry records it and keeps its reconnect
                    // loop instead of parking `.connecting` with nothing
                    // scheduled.
                    throw GatewayFailure(
                        code: "replaced",
                        message: "The connection ended before its handshake completed.",
                        retryable: true,
                        details: nil
                    )
                }
                self.entries[profile.id]?.reconnectSchedule.reset()
                self.entries[profile.id]?.connectionFailureClassifier.reset()
                self.entries[profile.id]?.consecutiveFailedAttempts = 0
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
                // The connection is live: somebody has to read its events. The
                // admitted connection is the identity the guard above pinned to
                // the client's own active one.
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
                if let failurePresentationGeneration {
                    _ = self.entries[profile.id]?.connectionFailureClassifier.failedAttempt(
                        diagnostic,
                        code: GatewayDiagnosticFailure.code(error),
                        attemptGeneration: failurePresentationGeneration
                    )
                }
                let failedState = self.entries[profile.id]?.connectionFailureClassifier.noPath
                    .map { DashboardServerConnectionState.noPath($0.interface) } ?? .reconnecting
                self.entries[profile.id]?.consecutiveFailedAttempts += 1
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
        entry.task?.cancel()
        entry.refreshTask?.cancel()
        entry.reconnectTask?.cancel()
        entry.eventTask?.cancel()
        entry.reconnectSchedule.cancel()
        // A retired entry ends the episode it was explaining: `stopped` for a
        // profile switch, removal or explicit retry, `background` for the
        // scene retirement that parks every pool entry.
        entry.recorder.endEpisode(
            endedBy, profileID: profileID, lifecycleGeneration: entry.generation
        )
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

    /// Starts this entry's reader for one live connection's events. The client's
    /// event stream is client-lifetime, so the reader is owned by the connection
    /// epoch it serves: `retireConnectionEpoch` cancels it with that epoch, and a
    /// connection that connects starts its own. That is what makes every live
    /// socket consumed exactly once — including a reconnect after an initial
    /// connect that failed, whose `start` task ended in its failure branch and
    /// therefore never reached the stream.
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
            // The event stream ended without a disconnect event and is still a
            // loss: the episode it opens keeps whatever the first failed attempt
            // adds as its cause.
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
            entries[profileID]?.connectionFailureClassifier.failedAttempt(nil, code: "transport")
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

    /// Path hints are advisory per profile. A satisfied return hint can revive
    /// a parked secondary entry even when its previous callback was missed.
    ///
    /// Only a real path change — unsatisfied to satisfied — ends a wait early.
    /// `AppModel.lifecycleNotePathHint` forwards every monitor update while the
    /// network is available and every scene activation, so reading any
    /// satisfied notice as a change would cut a five-minute pool backoff short
    /// on a scene resume and make the cap a lie.
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
        // No loop holds this entry: it was stopped or parked while the path was
        // gone (or before it was ever up), so a satisfied hint restarts it at
        // once rather than waiting for a wait that does not exist.
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
        entries[profileID]?.reconnectLoopID = loopID
        let task = Task { @MainActor [weak self, clock] in
            // Whatever ends this loop — success, a state mismatch that returns
            // early, a path park or cancellation — a later drop must not read a
            // dead loop's marker as an attempt in flight, and `scheduleReconnect`
            // must not read a dead loop as a pending task and refuse to start
            // its successor. The identity check keeps a replaced loop from
            // clearing or erasing what its successor owns.
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
                    // The escalation only starts at the threshold. Below it the
                    // entry follows the standard progression, so a blip is
                    // retried on the same curve the selected profile uses
                    // rather than the base interval for ever; at the threshold
                    // it keeps the nominal delay it reached and grows by 4.
                    self.entries[profileID]?.reconnectSchedule.adopt(
                        delayPolicy: self.isUnreachable(profileID: profileID)
                            ? Self.unreachableReconnectDelayPolicy
                            : Self.reconnectDelayPolicy
                    )
                    self.entries[profileID]?.reconnectWaiting = true
                    delayStartedAt = clock.now()
                    let delayCompleted = await waitingEntry.reconnectSchedule.afterFailure()
                    guard !Task.isCancelled else { return }
                    // The wait ended while the path was gone: park the entry. Its
                    // backoff is over, so a path return has to find no task here
                    // and start the next attempt itself.
                    guard delayCompleted || self.entries[profileID]?.networkPathSatisfied == true else { return }
                }
                // A path that went away mid-wait parks the entry here instead of
                // leaving `reconnectTask` behind: a wait that no longer exists
                // cannot be woken by the return hint, and a task still in this
                // slot is what stopped `scheduleReconnect` from starting one.
                guard !Task.isCancelled, self.isCurrent(profileID: profileID, client: waitingEntry.client, generation: generation),
                      self.entries[profileID]?.networkPathSatisfied == true else { return }
                self.entries[profileID]?.reconnectWaiting = false
                guard !Task.isCancelled,
                      let entry = self.entries[profileID],
                      entry.generation == generation else { return }
                retry += 1
                let startedAt = clock.now()
                // The loop is inside one transport attempt until this attempt
                // ends; the stall watchdog reads this identity to tell a running
                // attempt from a parked loop.
                self.entries[profileID]?.attemptInFlightLoopID = loopID
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
                    self.entries[profileID]?.consecutiveFailedAttempts = 0
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
                    // A reconnect that connected owes its live socket the same
                    // event reader an initial connect gets. Without it the
                    // socket delivers summaries and control events nobody
                    // reads, which is how an entry whose first attempt failed
                    // went silent until it was recreated.
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
                    if let failurePresentationGeneration {
                        _ = self.entries[profileID]?.connectionFailureClassifier.failedAttempt(
                            diagnostic,
                            code: GatewayDiagnosticFailure.code(error),
                            attemptGeneration: failurePresentationGeneration
                        )
                    }
                    let failureCode = GatewayDiagnosticFailure.code(error)
                    self.entries[profileID]?.consecutiveFailedAttempts += 1
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

    /// Whether this entry has failed `POOL_UNREACHABLE_AFTER` attempts in a
    /// row. The count is the pool's own and only a successful attempt clears
    /// it: the display classifier's never-opened counter stops counting as soon
    /// as any attempt of the outage opened a transport (the dropped socket of a
    /// secondary Mac, a hello timeout, a 503), which is exactly the run the
    /// retry curve still has to escalate.
    private func isUnreachable(profileID: String) -> Bool {
        guard let entry = entries[profileID] else { return false }
        return entry.consecutiveFailedAttempts >= Self.POOL_UNREACHABLE_AFTER
    }

    /// Why no attempt is in flight or scheduled, for the stall watchdog. `nil`
    /// means recovery is progressing: an attempt is running or the loop is
    /// waiting in its bounded backoff. Both are read through the loop's own
    /// identity, because a task a returned loop left in the slot is not
    /// progress: reading it as progress is how a parked entry went unnamed.
    /// `reconnectTaskBusy` is the loop existing but neither attempting nor
    /// waiting, which is where this pool could park recovery; C-1 owns what a
    /// parked loop should do instead.
    private func stallGuard(profileID: String) -> GatewayReconnectStallGuard? {
        guard let entry = entries[profileID] else { return .other }
        if entry.reconnectLoopID != nil, entry.attemptInFlightLoopID == entry.reconnectLoopID { return nil }
        if entry.reconnectLoopID != nil, entry.reconnectTask != nil, entry.reconnectWaiting { return nil }
        if !entry.networkPathSatisfied { return .pathUnsatisfied }
        if nonRetryableProfiles.contains(profileID) { return .nonRetryable }
        if entry.reconnectTask != nil { return .reconnectTaskBusy }
        return .other
    }

    /// One `gateway.attempt` record for an attempt this entry made, plus the
    /// episode bookkeeping the recorder derives from it. Pool entries exist
    /// only between a foreground reconcile and the background retirement, so
    /// every pool attempt is a foreground attempt. `stageReached` is the
    /// client's own handshake stage when it recorded one; without one the
    /// attempt never opened a transport, which is what a pool attempt is. The
    /// record is owned by the pool: the profile ID alone cannot say whether an
    /// attempt came from the selected profile's lifecycle or from a pool entry,
    /// because a profile switch moves one profile between the two.
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
            if result.needsImmediateFollowUp
                && (result.outcome == .published || result.outcome == .retained) {
                // A newer invalidation arrived while the final traversal was
                // reading, so that traversal can have been retired by the very
                // change it was meant to publish: its page cannot be this
                // profile's catalog. `.retained` covers that retirement as well
                // as a page this client rejected, and both need the catch-up
                // this lease owed — the fresh lease owns the next attempt and
                // its own failure budget. The flag requires a fresh invalidation
                // each time, so this cannot spin. `.retryRead` and
                // `.transportFailure` keep their own backoff instead.
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
                // The rows are confirmed, not republished. A retired epoch had
                // marked this catalog disconnected, and both the archived
                // container and the profile's own state read from the signals
                // a published catalog sends, so a confirmation that revives a
                // retired projection republishes them — the rows it sends are
                // the ones it already held.
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
            // A catalog read that proves the socket dead is a loss like any
            // other: it opens the episode the following attempts belong to.
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
        // The epoch's event reader ends with the epoch. A reader left waiting on
        // the client's shared stream would keep its place in the hub's waiter
        // queue and could take (and drop) a successor connection's deliveries.
        entry.eventTask?.cancel()
        entry.eventTask = nil
        entry.connectionID = nil
        entry.state = state
        entry.catalog.markDisconnected()
        entries[profileID] = entry
        publish(profileID: profileID)
        // A server the container can no longer read loses its rows, so the
        // archived projection changed with the epoch.
        publishAuthoritativeCatalog(profileID: profileID)
    }

    private func publish(profileID: String) {
        guard let entry = entries[profileID] else { return }
        delegate?.dashboardPoolDidUpdate(
            profileID: profileID,
            sessions: entry.catalog.sessions,
            state: entry.state
        )
        delegate?.dashboardPoolDidUpdateArchivedCount(
            profileID: profileID,
            count: entry.catalog.archivedCount
        )
    }

    /// Reports the one moment a background profile's catalog authority changes,
    /// which is also the archived projection's own authority. `publish` alone
    /// cannot carry this: it also runs for summary updates, where the archived
    /// rows cannot change.
    private func publishAuthoritativeCatalog(profileID: String) {
        delegate?.dashboardPoolDidPublishAuthoritativeCatalog(profileID: profileID)
    }
}
