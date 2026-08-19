import Foundation

@MainActor
protocol DashboardGatewayConnectionPoolDelegate: AnyObject {
    func dashboardPoolDidUpdate(
        profileID: String,
        sessions: [SessionSummary],
        state: DashboardServerConnectionState
    )
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
        var state: DashboardServerConnectionState
        var sessions: [SessionSummary]
        var task: Task<Void, Never>?
        var refreshTask: Task<Void, Never>?
        var reconnectTask: Task<Void, Never>?
        var generation: Int
    }

    weak var delegate: (any DashboardGatewayConnectionPoolDelegate)?
    private var entries: [String: Entry] = [:]
    private var generation = 0
    private var retirementTask: Task<Void, Never>?

    func reconcile(
        profiles: [GatewayProfile],
        selectedProfileID: String?,
        token: (GatewayProfile) -> String?
    ) {
        generation &+= 1
        let selectedGroup = profiles.first(where: { $0.id == selectedProfileID })?.machineGroupID
        let admittedIDs = Self.admittedProfileIDs(
            profiles,
            selectedProfileID: selectedProfileID,
            selectedMachineGroupID: selectedGroup
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

    func refreshAll() async {
        let work = entries.compactMap { entry -> (String, Int, Int)? in
            guard let connectionID = entry.value.connectionID else { return nil }
            return (entry.key, entry.value.generation, connectionID)
        }
        for item in work {
            await refresh(profileID: item.0, generation: item.1, expectedConnectionID: item.2)
        }
    }

    func state(for profileID: String) -> DashboardServerConnectionState? {
        entries[profileID]?.state
    }

    nonisolated static func shouldAdmit(
        _ profile: GatewayProfile,
        selectedProfileID: String?,
        selectedMachineGroupID: String?
    ) -> Bool {
        profile.id != selectedProfileID
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
        selectedMachineGroupID: String?
    ) -> Set<String> {
        var groups = Set<String>()
        return Set(profiles.compactMap { profile in
            guard shouldAdmit(
                profile,
                selectedProfileID: selectedProfileID,
                selectedMachineGroupID: selectedMachineGroupID
            ), groups.insert(profile.machineGroupID).inserted else { return nil }
            return profile.id
        })
    }

    private func start(profile: GatewayProfile, token: String?, generation: Int) {
        guard let token else { return }
        let client = GatewayClient()
        entries[profile.id] = Entry(
            profile: profile,
            token: token,
            client: client,
            connectionID: nil,
            state: .connecting,
            sessions: [],
            task: nil,
            refreshTask: nil,
            reconnectTask: nil,
            generation: generation
        )
        publish(profileID: profile.id)
        let task = Task { @MainActor [weak self] in
            do {
                _ = try await client.connect(profile: profile, token: token)
                let connectionID = await client.activeConnectionID()
                guard let self, let connectionID,
                      self.isCurrent(profileID: profile.id, client: client, generation: generation) else { return }
                self.entries[profile.id]?.connectionID = connectionID
                self.entries[profile.id]?.state = .connecting
                self.publish(profileID: profile.id)
                await self.refresh(
                    profileID: profile.id,
                    generation: generation,
                    expectedConnectionID: connectionID
                )
                for await delivery in client.events {
                    guard !Task.isCancelled,
                          self.isCurrent(profileID: profile.id, client: client, generation: generation) else { return }
                    self.handle(delivery, profileID: profile.id, generation: generation)
                }
                guard !Task.isCancelled,
                      self.isCurrent(profileID: profile.id, client: client, generation: generation) else { return }
                self.entries[profile.id]?.state = .offline
                self.publish(profileID: profile.id)
                self.scheduleReconnect(profileID: profile.id, generation: generation)
            } catch is CancellationError {
                return
            } catch {
                guard let self,
                      self.isCurrent(profileID: profile.id, client: client, generation: generation) else { return }
                self.entries[profile.id]?.state = .offline
                self.publish(profileID: profile.id)
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
        if close { Task { await entry.client.close() } }
        delegate?.dashboardPoolDidUpdate(profileID: profileID, sessions: [], state: .stale)
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
            if let index = current.sessions.firstIndex(where: { $0.id == update.sessionId }) {
                let summary = current.sessions[index]
                current.sessions[index] = SessionSummary(
                    id: summary.id,
                    name: update.name,
                    cwd: summary.cwd,
                    kind: summary.kind,
                    parentSessionId: summary.parentSessionId,
                    createdAt: summary.createdAt,
                    updatedAt: update.updatedAt,
                    messageCount: update.messageCount,
                    firstMessage: update.firstMessage,
                    phase: update.phase,
                    summaryRevision: update.summaryRevision,
                    gatewayProfileID: profileID,
                    gatewayProfileLabel: current.profile.label
                )
                entries[profileID] = current
                publish(profileID: profileID)
            } else {
                scheduleRefresh(profileID: profileID, generation: generation)
            }
        case "session.listChanged":
            scheduleRefresh(profileID: profileID, generation: generation)
        case "transport.disconnected":
            entries[profileID]?.state = .offline
            publish(profileID: profileID)
            scheduleReconnect(profileID: profileID, generation: generation)
        case "system.stopping":
            entries[profileID]?.state = .offline
            publish(profileID: profileID)
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
        let task = Task { @MainActor [weak self] in
            var delay: Duration = immediate ? .zero : .seconds(2)
            while !Task.isCancelled {
                if delay > .zero { try? await Task.sleep(for: delay) }
                guard !Task.isCancelled, let self,
                      let entry = self.entries[profileID],
                      entry.generation == generation else { return }
                do {
                    _ = try await entry.client.reconnect()
                    guard self.isCurrent(profileID: profileID, client: entry.client, generation: generation) else { return }
                    self.entries[profileID]?.state = .connecting
                    self.publish(profileID: profileID)
                    let connectionID = await entry.client.activeConnectionID()
                    guard let connectionID,
                          self.isCurrent(profileID: profileID, client: entry.client, generation: generation) else { return }
                    self.entries[profileID]?.connectionID = connectionID
                    self.entries[profileID]?.reconnectTask = nil
                    await self.refresh(
                        profileID: profileID,
                        generation: generation,
                        expectedConnectionID: connectionID
                    )
                    return
                } catch is CancellationError {
                    return
                } catch {
                    self.entries[profileID]?.state = .offline
                    self.publish(profileID: profileID)
                    delay = min(delay * 2, .seconds(15))
                }
            }
        }
        entries[profileID]?.reconnectTask = task
    }

    private func scheduleRefresh(profileID: String, generation: Int) {
        entries[profileID]?.refreshTask?.cancel()
        let task = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self else { return }
            guard let expectedConnectionID = self.entries[profileID]?.connectionID else { return }
            await self.refresh(
                profileID: profileID,
                generation: generation,
                expectedConnectionID: expectedConnectionID
            )
        }
        entries[profileID]?.refreshTask = task
    }

    private func refresh(
        profileID: String,
        generation: Int,
        expectedConnectionID: Int
    ) async {
        guard let entry = entries[profileID],
              entry.generation == generation,
              entry.connectionID == expectedConnectionID else { return }
        struct Params: Encodable { let cursor: String?; let limit: Int; let scope: String }
        struct Response: Decodable {
            let sessions: [SessionSummary]
            let nextCursor: String?
        }
        do {
            var all: [SessionSummary] = []
            var cursor: String?
            var seenCursors = Set<String>()
            var seenSessionIDs = Set<String>()
            var pageCount = 0
            repeat {
                guard pageCount < 50 else { return }
                let response: Response = try await entry.client.request(
                    "session.list",
                    Params(cursor: cursor, limit: 500, scope: "user")
                )
                guard response.sessions.count <= 500,
                      all.count <= 25_000 - response.sessions.count,
                      response.sessions.allSatisfy({ seenSessionIDs.insert($0.id).inserted }) else { return }
                pageCount += 1
                all.append(contentsOf: response.sessions.map {
                    $0.withGatewaySource(id: profileID, label: entry.profile.label)
                })
                cursor = response.nextCursor
                if let cursor, !seenCursors.insert(cursor).inserted { return }
            } while cursor != nil
            guard isCurrent(profileID: profileID, client: entry.client, generation: generation),
                  entries[profileID]?.connectionID == expectedConnectionID else { return }
            entries[profileID]?.sessions = all
            entries[profileID]?.state = .connected
            publish(profileID: profileID)
        } catch is CancellationError {
            return
        } catch {
            guard isCurrent(profileID: profileID, client: entry.client, generation: generation),
                  entries[profileID]?.connectionID == expectedConnectionID else { return }
            entries[profileID]?.state = .offline
            publish(profileID: profileID)
            scheduleReconnect(profileID: profileID, generation: generation)
        }
    }

    private func publish(profileID: String) {
        guard let entry = entries[profileID] else { return }
        delegate?.dashboardPoolDidUpdate(
            profileID: profileID,
            sessions: entry.sessions,
            state: entry.state
        )
    }
}
