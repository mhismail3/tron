import Foundation
import Observation
import Synchronization
import Testing
@testable import TronMobile

@Suite("Dashboard state ownership")
struct DashboardStateOwnerTests {
    @Test("a newer navigation intent rejects an older asynchronous completion")
    func navigationAdmission() {
        var owner = DashboardNavigationOwner()
        let importIntent = owner.begin()
        let newerIntent = owner.begin()

        let admittedImport = owner.admit(importIntent)
        let admittedNewer = owner.admit(newerIntent)
        let admittedDuplicate = owner.admit(newerIntent)
        #expect(!admittedImport)
        #expect(admittedNewer)
        #expect(!admittedDuplicate)
    }

    @Test("dirty catalog retries are attempt-unbounded and stop only when satisfied or retired")
    func catalogDirtyRetryPolicy() {
        for _ in 0..<12 {
            #expect(DashboardCatalogRetryPolicy.shouldRetry(
                isDirty: true,
                isCurrent: true,
                transportFailed: false
            ))
        }
        #expect(!DashboardCatalogRetryPolicy.shouldRetry(
            isDirty: false,
            isCurrent: true,
            transportFailed: false
        ))
        #expect(!DashboardCatalogRetryPolicy.shouldRetry(
            isDirty: true,
            isCurrent: false,
            transportFailed: false
        ))
        #expect(!DashboardCatalogRetryPolicy.shouldRetry(
            isDirty: true,
            isCurrent: true,
            transportFailed: true
        ))
    }

    @MainActor
    @Test("dashboard admits only one enabled profile per physical machine group")
    func sameMachineAdmission() {
        let selected = GatewayProfile(id: "prod", label: "Production", host: "mac", port: 9847, machineId: "runtime-prod", machineGroupID: "physical", deviceId: "device")
        let dev = GatewayProfile(id: "dev", label: "Dev", host: "mac", port: 9848, machineId: "runtime-dev", machineGroupID: "physical", deviceId: "device")
        let other = GatewayProfile(id: "other", label: "Other", host: "other-mac", port: 9847, machineId: "runtime-other", machineGroupID: "other-physical", deviceId: "device")
        #expect(!DashboardGatewayConnectionPool.shouldAdmit(dev, selectedProfileID: selected.id, selectedMachineGroupID: selected.machineGroupID))
        #expect(DashboardGatewayConnectionPool.shouldAdmit(other, selectedProfileID: selected.id, selectedMachineGroupID: selected.machineGroupID))
        var disabled = other
        disabled.isEnabled = false
        #expect(!DashboardGatewayConnectionPool.shouldAdmit(disabled, selectedProfileID: selected.id, selectedMachineGroupID: selected.machineGroupID))
        let legacy = GatewayProfile(id: "legacy", label: "Legacy", host: "legacy-mac", port: 9847, machineId: "legacy-runtime", deviceId: "device")
        #expect(!DashboardGatewayConnectionPool.shouldAdmit(legacy, selectedProfileID: selected.id, selectedMachineGroupID: selected.machineGroupID))
        let sameGroupOther = GatewayProfile(id: "other-dev", label: "Other Dev", host: "other-mac", port: 9848, machineId: "runtime-other-dev", machineGroupID: "other-physical", deviceId: "device")
        #expect(DashboardGatewayConnectionPool.admittedProfileIDs(
            [dev, other, sameGroupOther],
            selectedProfileID: selected.id,
            selectedMachineGroupID: selected.machineGroupID
        ) == Set([other.id]))

        #expect(DashboardGatewayConnectionPool.admittedProfileIDs(
            [dev, other],
            selectedProfileID: selected.id,
            selectedMachineGroupID: selected.machineGroupID,
            selectedProfileIsProvisional: true
        ).isEmpty)

        let firstRemote = GatewayProfile(id: "first-remote", label: "First", host: "first", port: 9847, machineId: "first-machine", machineGroupID: "remote", deviceId: "device")
        let secondRemote = GatewayProfile(id: "second-remote", label: "Second", host: "second", port: 9847, machineId: "second-machine", machineGroupID: "remote", deviceId: "device")
        #expect(DashboardGatewayConnectionPool.admittedProfileIDs(
            [firstRemote, secondRemote],
            selectedProfileID: selected.id,
            selectedMachineGroupID: selected.machineGroupID,
            tokenAvailable: { $0.id == secondRemote.id }
        ) == Set([secondRemote.id]))

        let matchingInfo = GatewayInfo(
            gatewayVersion: "1", piVersion: "1", protocolVersion: 3, minProtocolVersion: 3,
            machineId: other.machineId, machineGroupID: other.machineGroupID,
            machineName: "Other", capabilities: []
        )
        #expect(DashboardGatewayConnectionPool.admitsIdentity(matchingInfo, for: other))
        #expect(!DashboardGatewayConnectionPool.admitsIdentity(
            GatewayInfo(
                gatewayVersion: "1", piVersion: "1", protocolVersion: 3, minProtocolVersion: 3,
                machineId: "wrong", machineGroupID: other.machineGroupID,
                machineName: "Other", capabilities: []
            ),
            for: other
        ))
    }

    @MainActor
    @Test("dashboard catalog errors retain a responsive socket")
    func dashboardCatalogErrorRetainsSocket() async throws {
        try await withTestWatchdog { @MainActor in
            let selected = GatewayProfile(
                id: "selected", label: "Selected", host: "selected.test", port: 9_847,
                machineId: "selected-runtime", machineGroupID: "selected-machine", deviceId: "device"
            )
            let remote = GatewayProfile(
                id: "remote", label: "Remote", host: "remote.test", port: 9_847,
                machineId: "remote-runtime", machineGroupID: "remote-machine", deviceId: "device"
            )
            let socket = ScriptedGatewaySocket()
            let socketFactory = ScriptedGatewaySocketFactory(socket: socket)
            let pool = DashboardGatewayConnectionPool(clientFactory: {
                GatewayClient(socketFactory: socketFactory.factory)
            })
            await socket.enqueue(Data(#"{"type":"hello","gatewayVersion":"1","piVersion":"1","protocolVersion":3,"minProtocolVersion":3,"machineId":"remote-runtime","machineGroupID":"remote-machine","machineName":"Remote","gatewayChannel":"stable","capabilities":[]}"#.utf8))

            pool.reconcile(
                profiles: [selected, remote],
                selectedProfileID: selected.id,
                token: { $0.id == remote.id ? "token" : nil }
            )
            try await socket.waitUntilSent(count: 2)
            let catalogRequest = try Self.requestFrame(await socket.sentFrames()[1])
            #expect(catalogRequest.method == "session.list")
            await socket.enqueue(try JSONEncoder.gateway.encode(JSONValue.object([
                "type": .string("response"),
                "id": .string(catalogRequest.id),
                "ok": .bool(false),
                "error": .object([
                    "code": .string("invalid_dashboard_catalog"),
                    "message": .string("synthetic catalog failure"),
                    "retryable": .bool(true),
                    "details": .null,
                ]),
            ])))

            try await socket.waitUntilSent(count: 3)
            let probe = try Self.requestFrame(await socket.sentFrames()[2])
            #expect(probe.method == "system.info")
            await socket.enqueue(try JSONEncoder.gateway.encode(JSONValue.object([
                "type": .string("response"),
                "id": .string(probe.id),
                "ok": .bool(true),
                "result": .object(["protocolVersion": .number(3)]),
            ])))
            try await Self.waitUntil { pool.state(for: remote.id) == .stale }

            #expect(socketFactory.requests.count == 1)
            #expect(!(await socket.closed()))
            pool.retire()
            await pool.waitForRetirement()
        }
    }

    @MainActor
    @Test("secondary dirty catalog retries beyond the former cap and stops after publication")
    func secondaryCatalogDirtyRetryConverges() async throws {
        try await withTestWatchdog { @MainActor in
            let selected = GatewayProfile(
                id: "selected", label: "Selected", host: "selected.test", port: 9_847,
                machineId: "selected-runtime", machineGroupID: "selected-machine", deviceId: "device"
            )
            let remote = GatewayProfile(
                id: "remote", label: "Remote", host: "remote.test", port: 9_847,
                machineId: "remote-runtime", machineGroupID: "remote-machine", deviceId: "device"
            )
            let clock = ManualClock()
            let socket = ScriptedGatewaySocket()
            let factory = ScriptedGatewaySocketFactory(socket: socket)
            let pool = DashboardGatewayConnectionPool(
                clientFactory: { GatewayClient(socketFactory: factory.factory, clock: clock.clock) },
                clock: clock.clock
            )
            await socket.enqueue(Data(#"{"type":"hello","gatewayVersion":"1","piVersion":"1","protocolVersion":3,"minProtocolVersion":3,"machineId":"remote-runtime","machineGroupID":"remote-machine","machineName":"Remote","gatewayChannel":"stable","capabilities":[]}"#.utf8))
            pool.reconcile(
                profiles: [selected, remote],
                selectedProfileID: selected.id,
                token: { $0.id == remote.id ? "token" : nil }
            )

            try await socket.waitUntilSent(count: 2)
            var catalog = try Self.requestFrame(await socket.sentFrames()[1])
            for attempt in 0..<5 {
                let sleepsBeforeFailure = clock.recordedSleeps().count
                await socket.enqueue(try JSONEncoder.gateway.encode(JSONValue.object([
                    "type": .string("response"),
                    "id": .string(catalog.id),
                    "ok": .bool(false),
                    "error": .object([
                        "code": .string("invalid_dashboard_catalog"),
                        "message": .string("synthetic catalog failure"),
                        "retryable": .bool(true),
                        "details": .null,
                    ]),
                ])))
                try await Self.waitUntil {
                    clock.recordedSleeps().count > sleepsBeforeFailure
                }
                try await clock.waitUntilSleeping(count: 1)
                clock.advance(by: .seconds(8))
                let catalogCount = 3 + attempt
                try await socket.waitUntilSent(count: catalogCount)
                catalog = try Self.requestFrame(await socket.sentFrames()[catalogCount - 1])
                #expect(catalog.method == "session.list")
            }

            await socket.enqueue(Self.catalogResponse(id: catalog.id, sessions: [], listRevision: 6))
            try await Self.waitUntil { pool.state(for: remote.id) == .connected }
            let publishedCatalogCount = try (await socket.sentFrames()).dropFirst().map(Self.requestFrame)
                .filter { $0.method == "session.list" }.count
            clock.advance(by: .seconds(60))
            try await Task.sleep(for: .milliseconds(20))
            let laterCatalogCount = try (await socket.sentFrames()).dropFirst().map(Self.requestFrame)
                .filter { $0.method == "session.list" }.count
            #expect(laterCatalogCount == publishedCatalogCount)
            #expect(factory.requests.count == 1)
            #expect(!(await socket.closed()))
            pool.retire()
            await pool.waitForRetirement()
        }
    }

    @MainActor
    @Test("secondary catalogs restart mixed revisions and coalesce live overlays")
    func secondaryCatalogConvergence() async throws {
        try await withTestWatchdog { @MainActor in
            let selected = GatewayProfile(
                id: "selected", label: "Selected", host: "selected.test", port: 9_847,
                machineId: "selected-runtime", machineGroupID: "selected-machine", deviceId: "device"
            )
            let remote = GatewayProfile(
                id: "remote", label: "Remote", host: "remote.test", port: 9_847,
                machineId: "remote-runtime", machineGroupID: "remote-machine", deviceId: "device"
            )
            let socket = ScriptedGatewaySocket()
            let recorder = DashboardPoolRecorder()
            let pool = DashboardGatewayConnectionPool(clientFactory: {
                GatewayClient(socketFactory: ScriptedGatewaySocketFactory(socket: socket).factory)
            })
            pool.delegate = recorder
            await socket.enqueue(Data(#"{"type":"hello","gatewayVersion":"1","piVersion":"1","protocolVersion":3,"minProtocolVersion":3,"machineId":"remote-runtime","machineGroupID":"remote-machine","machineName":"Remote","gatewayChannel":"stable","capabilities":[]}"#.utf8))
            pool.reconcile(
                profiles: [selected, remote],
                selectedProfileID: selected.id,
                token: { $0.id == remote.id ? "token" : nil }
            )

            try await socket.waitUntilSent(count: 2)
            let first = try Self.requestFrame(await socket.sentFrames()[1])
            await socket.enqueue(Self.catalogResponse(
                id: first.id,
                sessions: [summary(revision: 1)],
                listRevision: 1,
                nextCursor: "page-two"
            ))
            try await socket.waitUntilSent(count: 3)
            let mixed = try Self.requestFrame(await socket.sentFrames()[2])
            await socket.enqueue(Self.catalogResponse(
                id: mixed.id,
                sessions: [],
                listRevision: 2
            ))

            // The mixed traversal restarts from nil. While that complete list
            // is in flight, a newer row event and an event burst dirty exactly
            // one shared follow-up lease.
            try await socket.waitUntilSent(count: 4)
            let restarted = try Self.requestFrame(await socket.sentFrames()[3])
            await socket.enqueue(Self.summaryEvent(revision: 5, phase: .running))
            for _ in 0..<3 { await socket.enqueue(Self.listChangedEvent()) }
            await socket.enqueue(Self.catalogResponse(
                id: restarted.id,
                sessions: [summary(revision: 2)],
                listRevision: 3
            ))
            try await Self.waitUntil {
                recorder.updates.contains(where: {
                    $0.sessions.first?.summaryRevision == 5 && $0.sessions.first?.phase == .running
                })
            }
            let overlaid = try #require(recorder.updates.last(where: {
                $0.sessions.first?.summaryRevision == 5
            })?.sessions.first)
            #expect(overlaid.gatewayProfileID == remote.id)
            #expect(overlaid.gatewayProfileLabel == remote.label)

            try await socket.waitUntilSent(count: 5)
            try await Task.sleep(for: .milliseconds(20))
            #expect((await socket.sentFrames()).count == 5)
            let followUp = try Self.requestFrame(await socket.sentFrames()[4])
            await socket.enqueue(Self.catalogResponse(
                id: followUp.id,
                sessions: [],
                listRevision: 4
            ))
            try await Self.waitUntil { recorder.updates.last?.sessions.isEmpty == true }
            #expect(recorder.updates.last?.state == .connected)

            pool.retire()
            await pool.waitForRetirement()
        }
    }

    @MainActor
    @Test("secondary reconnect rejects the retired socket epoch and loads fresh truth")
    func secondaryReconnectAdmission() async throws {
        try await withTestWatchdog { @MainActor in
            let selected = GatewayProfile(
                id: "selected", label: "Selected", host: "selected.test", port: 9_847,
                machineId: "selected-runtime", machineGroupID: "selected-machine", deviceId: "device"
            )
            let remote = GatewayProfile(
                id: "remote", label: "Remote", host: "remote.test", port: 9_847,
                machineId: "remote-runtime", machineGroupID: "remote-machine", deviceId: "device"
            )
            let oldSocket = ScriptedGatewaySocket()
            let replacement = ScriptedGatewaySocket()
            let socketFactory = ScriptedGatewaySocketFactory(sockets: [oldSocket, replacement])
            let recorder = DashboardPoolRecorder()
            let pool = DashboardGatewayConnectionPool(clientFactory: {
                GatewayClient(socketFactory: socketFactory.factory)
            })
            pool.delegate = recorder
            let hello = Data(#"{"type":"hello","gatewayVersion":"1","piVersion":"1","protocolVersion":3,"minProtocolVersion":3,"machineId":"remote-runtime","machineGroupID":"remote-machine","machineName":"Remote","gatewayChannel":"stable","capabilities":[]}"#.utf8)
            await oldSocket.enqueue(hello)
            pool.reconcile(
                profiles: [selected, remote], selectedProfileID: selected.id,
                token: { $0.id == remote.id ? "token" : nil }
            )
            try await oldSocket.waitUntilSent(count: 2)
            let initial = try Self.requestFrame(await oldSocket.sentFrames()[1])
            await oldSocket.enqueue(Self.catalogResponse(
                id: initial.id, sessions: [summary(revision: 1)], listRevision: 1
            ))
            try await Self.waitUntil { recorder.updates.last?.sessions.first?.summaryRevision == 1 }
            await oldSocket.enqueue(Self.notificationInboxChangedEvent())
            try await Self.waitUntil { recorder.notificationInvalidations == [remote.id] }

            await replacement.enqueue(hello)
            await oldSocket.enqueue(Self.stoppingEvent())
            // This old-epoch row event is delivered after retirement and must
            // not overlay the replacement connection's catalog.
            await oldSocket.enqueue(Self.summaryEvent(revision: 9, phase: .running))
            try await replacement.waitUntilSent(count: 2)
            let refreshed = try Self.requestFrame(await replacement.sentFrames()[1])
            await replacement.enqueue(Self.catalogResponse(
                id: refreshed.id, sessions: [summary(revision: 2)], listRevision: 2
            ))
            try await Self.waitUntil {
                recorder.updates.last?.sessions.first?.summaryRevision == 2
                    && recorder.updates.last?.state == .connected
            }
            #expect(!recorder.updates.contains(where: { $0.sessions.first?.summaryRevision == 9 }))

            pool.retire()
            await pool.waitForRetirement()
        }
    }

    @Test("dashboard reconnect backoff advances after an immediate failed attempt")
    func dashboardReconnectBackoff() {
        #expect(DashboardGatewayConnectionPool.nextReconnectDelay(after: .zero) == .seconds(2))
        #expect(DashboardGatewayConnectionPool.nextReconnectDelay(after: .seconds(2)) == .seconds(4))
        #expect(DashboardGatewayConnectionPool.nextReconnectDelay(after: .seconds(10)) == .seconds(15))
    }

    @Test("connection status labels cover live, restart, and failure states")
    func connectionStatusLabels() {
        #expect(DashboardServerConnectionState.connected.label == "Connected")
        #expect(DashboardServerConnectionState.reconnecting.label == "Reconnecting")
        #expect(DashboardServerConnectionState.restarting.label == "Restarting")
        #expect(DashboardServerConnectionState.identityMismatch.label == "Identity changed")
        #expect(DashboardServerConnectionState.disabled.label == "Disabled")
    }

    @Test("retiring a background transport retains its bounded dashboard bucket")
    func dashboardProjectionRetention() {
        #expect(DashboardProjectionRetentionPolicy.retainsExistingBucket(
            profileExists: true,
            existingSessionCount: 3,
            incomingSessionCount: 0,
            state: .connecting
        ))
        #expect(DashboardProjectionRetentionPolicy.retainsExistingBucket(
            profileExists: true,
            existingSessionCount: 3,
            incomingSessionCount: 0,
            state: .stale
        ))
        #expect(!DashboardProjectionRetentionPolicy.retainsExistingBucket(
            profileExists: true,
            existingSessionCount: 0,
            incomingSessionCount: 0,
            state: .connecting
        ))
        #expect(!DashboardProjectionRetentionPolicy.retainsExistingBucket(
            profileExists: true,
            existingSessionCount: 3,
            incomingSessionCount: 1,
            state: .connected
        ))
        #expect(!DashboardProjectionRetentionPolicy.retainsExistingBucket(
            profileExists: false,
            existingSessionCount: 3,
            incomingSessionCount: 0,
            state: .stale
        ))
    }

    private struct RequestFrame {
        let id: String
        let method: String
    }

    private static func requestFrame(_ data: Data) throws -> RequestFrame {
        let value = try JSONDecoder.gateway.decode(JSONValue.self, from: data)
        let object = try #require(value.objectValue)
        return RequestFrame(
            id: try #require(object["id"]?.stringValue),
            method: try #require(object["method"]?.stringValue)
        )
    }

    private static func catalogResponse(
        id: String,
        sessions: [SessionSummary],
        listRevision: Int,
        nextCursor: String? = nil
    ) -> Data {
        let encoded = try! JSONEncoder.gateway.encode(sessions)
        let rawSessions = try! JSONSerialization.jsonObject(with: encoded)
        var result: [String: Any] = ["sessions": rawSessions, "listRevision": listRevision]
        if let nextCursor { result["nextCursor"] = nextCursor }
        return try! JSONSerialization.data(withJSONObject: [
            "type": "response", "id": id, "ok": true, "result": result,
        ])
    }

    private static func summaryEvent(revision: Int, phase: SessionPhase) -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "type": "event", "topic": "session.summary",
            "payload": [
                "sessionId": "session", "summaryRevision": revision,
                "phase": phase.rawValue, "name": "Updated",
                "updatedAt": "2026-01-01T00:00:05Z", "messageCount": revision,
                "firstMessage": "Updated",
            ],
        ])
    }

    private static func listChangedEvent() -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "type": "event", "topic": "session.listChanged", "payload": [:],
        ])
    }

    private static func notificationInboxChangedEvent() -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "type": "event", "topic": "notification.inbox.changed", "payload": [:],
        ])
    }

    private static func stoppingEvent() -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "type": "event", "topic": "system.stopping", "payload": [:],
        ])
    }

    @MainActor
    private static func waitUntil(_ predicate: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !predicate() {
            guard ContinuousClock.now < deadline else {
                throw GatewayFailure(code: "timeout", message: "condition timed out", retryable: true, details: nil)
            }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    @Test("server filter defaults to all and preserves explicit selections")
    func serverFilterSelection() {
        var filter = DashboardServerFilterState()
        filter.reconcile(profileIDs: ["a", "b", "c"])
        #expect(filter.isAllSelected)
        #expect(filter.allows("a"))

        filter.toggle("b")
        #expect(filter.isFiltering)
        #expect(filter.allows("a"))
        #expect(!filter.allows("b"))
        #expect(filter.allows(nil, selectedProfileID: "a"))
        #expect(!filter.allows(nil, selectedProfileID: "b"))
        #expect(filter.isSelected("c"))

        filter.toggle("b")
        #expect(filter.isAllSelected)
        filter.selectAll()
        #expect(filter.isAllSelected)

        filter.setSortMode(.recent)
        #expect(filter.sortMode == .recent)
        #expect(filter.isFiltering)
        filter.setSortMode(.projectServer)
        #expect(!filter.isFiltering)
    }

    @Test("dashboard ordering and server choices persist and reconcile safely")
    func filterPreferencePersistence() {
        let suiteName = "DashboardStateOwnerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var stored = DashboardServerFilterPreferences.load(from: defaults)
        #expect(stored.sortMode == .projectServer)
        stored.reconcile(profileIDs: ["a", "b", "c"])
        stored.toggle("b")
        stored.setSortMode(.recent)
        DashboardServerFilterPreferences.save(stored, to: defaults)

        var restored = DashboardServerFilterPreferences.load(from: defaults)
        #expect(restored.sortMode == .recent)
        #expect(!restored.isSelected("b"))
        restored.reconcile(profileIDs: [])
        #expect(!restored.isSelected("b"))
        restored.reconcile(profileIDs: ["b", "c"])
        #expect(!restored.isAllSelected)
        #expect(!restored.isSelected("b"))
        #expect(restored.isSelected("c"))
    }

    @Test("malformed or oversized dashboard preferences fail closed")
    func invalidFilterPreferences() {
        let suiteName = "DashboardStateOwnerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(Data(#"{"version":1,"sortMode":"Recent Activity","selectedProfileIDs":["duplicate","duplicate"]}"#.utf8), forKey: DashboardServerFilterPreferences.documentKey)
        #expect(DashboardServerFilterPreferences.load(from: defaults) == DashboardServerFilterState())
        defaults.set(Data(repeating: 0x41, count: 32 * 1024 + 1), forKey: DashboardServerFilterPreferences.documentKey)
        #expect(DashboardServerFilterPreferences.load(from: defaults) == DashboardServerFilterState())
    }

    @Test("direct navigation invalidates pending asynchronous navigation")
    func navigationInvalidation() {
        var owner = DashboardNavigationOwner()
        let pending = owner.begin()
        owner.invalidate()
        let admitted = owner.admit(pending)
        #expect(!admitted)
    }

    @Test("only the latest catalog load may publish")
    func catalogAdmission() {
        var owner = SessionCatalogCoordinator()
        let first = owner.beginLoad()
        let second = owner.beginLoad()
        let firstPublished = owner.publishAuthoritative([summary(revision: 1)], admission: first)
        let secondPublished = owner.publishAuthoritative([summary(revision: 2)], admission: second)
        #expect(!firstPublished)
        #expect(secondPublished)
        #expect(owner.sessions.first?.summaryRevision == 2)
        owner.invalidateLoads()
        #expect(!owner.admits(second))
    }

    @Test("catalog admissions reject stale profile and connection epochs")
    func catalogEpochAdmission() {
        var owner = SessionCatalogCoordinator()
        let firstKey = SessionCatalogLoadKey(
            profileID: "remote", lifecycleGeneration: 1, connectionID: 10
        )
        let replacementKey = SessionCatalogLoadKey(
            profileID: "remote", lifecycleGeneration: 2, connectionID: 11
        )
        let first = owner.beginLoad(key: firstKey)
        #expect(owner.admits(first, key: firstKey))
        #expect(!owner.admits(first, key: replacementKey))
        let replacement = owner.beginLoad(key: replacementKey)
        #expect(!owner.admits(first, key: firstKey))
        #expect(owner.admits(replacement, key: replacementKey))
    }

    @Test("newer live summaries survive an older authoritative catalog page")
    func liveSummaryOverlay() {
        var owner = SessionCatalogCoordinator()
        let first = owner.beginLoad()
        let firstPublished = owner.publishAuthoritative([summary(revision: 1)], admission: first)
        let updated = owner.apply(update(
            revision: 3,
            phase: .running,
            activeSince: "2026-01-01T00:00:00Z",
            completionRevision: 2,
            isUnread: true
        ))
        let stale = owner.apply(update(revision: 2, phase: .idle))
        #expect(firstPublished)
        #expect(updated == .updated)
        #expect(stale == .stale)

        let refresh = owner.beginLoad()
        let refreshed = owner.publishAuthoritative([summary(revision: 2)], admission: refresh)
        #expect(refreshed)
        #expect(owner.sessions.first?.summaryRevision == 3)
        #expect(owner.sessions.first?.phase == .running)
        #expect(owner.sessions.first?.activeSince == "2026-01-01T00:00:00Z")
        #expect(owner.sessions.first?.completionRevision == 2)
        #expect(owner.sessions.first?.isUnread == true)
    }

    @Test("unknown live summaries request discovery without fabricating a row")
    func unknownSummary() {
        var owner = SessionCatalogCoordinator()
        let unknown = owner.apply(update(revision: 1, phase: .running))
        #expect(unknown == .unknownSession)
        #expect(owner.sessions.isEmpty)

        let load = owner.beginLoad()
        let published = owner.publishAuthoritative([summary(revision: 1)], admission: load)
        #expect(published)
        #expect(owner.sessions.first?.phase == .idle)
    }

    @Test("selected authoritative rows are not hidden by background profile buckets")
    func selectedProfileFallback() {
        let selected = SessionSummary(
            id: "same-id", name: "Selected", cwd: "/selected", parentSessionId: nil,
            createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z",
            messageCount: 0, firstMessage: "", phase: .idle, summaryRevision: 1
        )
        let background = SessionSummary(
            id: "background-id", name: "Background", cwd: "/background", parentSessionId: nil,
            createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z",
            messageCount: 0, firstMessage: "", phase: .idle, summaryRevision: 1
        ).withGatewaySource(id: "background", label: "Background")
        let values = AppModel.dashboardProjection(
            selectedProfileID: "selected",
            selectedProfileLabel: "Selected",
            selectedSessions: [selected],
            buckets: ["background": [background]]
        )
        #expect(Set(values.map(\.dashboardID)) == Set(["selected:same-id", "background:background-id"]))
    }

    @Test("attention responses update cold rows monotonically without fabricating unknown rows")
    func attentionProjection() {
        var owner = SessionCatalogCoordinator()
        let load = owner.beginLoad()
        let published = owner.publishAuthoritative([summary(revision: 1)], admission: load)
        #expect(published)
        let appliedAttention = owner.applyAttention(
            sessionID: "session",
            SessionAttentionProjection(completionRevision: 0, attentionRevision: 2, isUnread: true)
        )
        #expect(appliedAttention)
        #expect(owner.sessions.first?.isUnread == true)
        let staleUpdate = SessionSummaryUpdate(
            sessionId: "session", summaryRevision: 2, phase: .running, name: "Older attention",
            updatedAt: "2026-01-01T00:00:02Z", messageCount: 2, firstMessage: "Older",
            completionRevision: 0, attentionRevision: 1, isUnread: false
        )
        let staleUpdateResult = owner.apply(staleUpdate)
        #expect(staleUpdateResult == .updated)
        #expect(owner.sessions.first?.isUnread == true)
        let staleAttention = owner.applyAttention(
            sessionID: "session",
            SessionAttentionProjection(completionRevision: 0, attentionRevision: 1, isUnread: false)
        )
        #expect(!staleAttention)
        let unknownAttention = owner.applyAttention(
            sessionID: "unknown",
            SessionAttentionProjection(completionRevision: 0, attentionRevision: 3, isUnread: true)
        )
        #expect(!unknownAttention)
        #expect(owner.sessions.count == 1)
    }

    @Test("cached and disconnected phases retain provenance without fabricating interruption")
    func catalogFreshnessAndActivity() {
        var owner = SessionCatalogCoordinator()
        let load = owner.beginLoad()
        let published = owner.publishAuthoritative([
            summary(revision: 1, phase: .running),
        ], admission: load)
        #expect(published)
        #expect(owner.freshness == .live)
        #expect(owner.activity(for: "session") == .active)

        let pendingBeforeDisconnect = owner.beginLoad()
        owner.markDisconnected()
        #expect(owner.sessions.first?.phase == .running)
        #expect(owner.freshness == .stale)
        #expect(owner.activity(for: "session") == .resuming)
        let disconnectedPublish = owner.publishAuthoritative(
            [summary(revision: 2, phase: .running)],
            admission: pendingBeforeDisconnect
        )
        #expect(!disconnectedPublish)

        let pendingBeforeCache = owner.beginLoad()
        owner.installCached([summary(revision: 2, phase: .interrupted)])
        #expect(owner.sessions.first?.phase == .interrupted)
        #expect(owner.freshness == .cached)
        #expect(owner.activity(for: "session") == .resuming)
        let cachedPublish = owner.publishAuthoritative(
            [summary(revision: 3)],
            admission: pendingBeforeCache
        )
        #expect(!cachedPublish)

        let liveInterrupted = owner.apply(update(revision: 4, phase: .interrupted))
        #expect(liveInterrupted == .updated)
        #expect(owner.activity(for: "session") == .interrupted)
    }

    @Test("removal clears both the row and retained live revision")
    func removal() {
        var owner = SessionCatalogCoordinator()
        let load = owner.beginLoad()
        let published = owner.publishAuthoritative([summary(revision: 1)], admission: load)
        let updated = owner.apply(update(revision: 2, phase: .running))
        #expect(published)
        #expect(updated == .updated)
        let pendingBeforeRemoval = owner.beginLoad()
        owner.remove("session")
        #expect(owner.sessions.isEmpty)
        let removedPublish = owner.publishAuthoritative(
            [summary(revision: 3)],
            admission: pendingBeforeRemoval
        )
        #expect(!removedPublish)
        let unknown = owner.apply(update(revision: 2, phase: .idle))
        #expect(unknown == .unknownSession)
    }

    @Test("facade replacement and clear invalidate pending loads")
    func replacementAndClearInvalidateLoads() {
        var owner = SessionCatalogCoordinator()
        let beforeReplacement = owner.beginLoad()
        owner.replaceForFacade([summary(revision: 1)])
        let replacedPublish = owner.publishAuthoritative(
            [summary(revision: 2)],
            admission: beforeReplacement
        )
        #expect(!replacedPublish)

        let beforeClear = owner.beginLoad()
        owner.clear()
        let clearedPublish = owner.publishAuthoritative(
            [summary(revision: 3)],
            admission: beforeClear
        )
        #expect(!clearedPublish)
        #expect(owner.sessions.isEmpty)
        #expect(owner.hasConsistentIndex())
    }

    @Test("catalog index stays exact across publication, update, removal, replacement, and clear")
    func catalogIndexIntegrity() {
        var owner = SessionCatalogCoordinator()
        let load = owner.beginLoad()
        let published = owner.publishAuthoritative([summary(revision: 1)], admission: load)
        #expect(published)
        #expect(owner.hasConsistentIndex())
        let updated = owner.apply(update(revision: 2, phase: .running))
        #expect(updated == .updated)
        #expect(owner.hasConsistentIndex())
        owner.remove("session")
        #expect(owner.hasConsistentIndex())
        owner.replaceForFacade([summary(revision: 3)])
        #expect(owner.hasConsistentIndex())
        owner.clear()
        #expect(owner.hasConsistentIndex())
    }

    @MainActor
    @Test("the AppModel sessions façade remains observable")
    func sessionsFacadeObservation() {
        let model = AppModel()
        let changed = Mutex(false)
        withObservationTracking {
            _ = model.sessions
        } onChange: {
            changed.withLock { $0 = true }
        }
        model.sessions = [summary(revision: 1)]
        #expect(changed.withLock { $0 })
        #expect(model.sessions.first?.id == "session")
    }

    private func summary(
        revision: Int,
        phase: SessionPhase = .idle
    ) -> SessionSummary {
        SessionSummary(
            id: "session",
            name: "Session",
            cwd: "/workspace",
            parentSessionId: nil,
            createdAt: "2026-01-01T00:00:00Z",
            updatedAt: "2026-01-01T00:00:00Z",
            messageCount: 1,
            firstMessage: "Hello",
            phase: phase,
            summaryRevision: revision
        )
    }

    private func update(
        revision: Int,
        phase: SessionPhase,
        activeSince: String? = nil,
        completionRevision: Int = 0,
        isUnread: Bool = false
    ) -> SessionSummaryUpdate {
        SessionSummaryUpdate(
            sessionId: "session",
            summaryRevision: revision,
            phase: phase,
            name: "Updated",
            updatedAt: "2026-01-01T00:00:01Z",
            activeSince: activeSince,
            messageCount: revision,
            firstMessage: "Updated",
            completionRevision: completionRevision,
            attentionRevision: revision,
            isUnread: isUnread
        )
    }
}

@MainActor
private final class DashboardPoolRecorder: DashboardGatewayConnectionPoolDelegate {
    struct Update {
        let sessions: [SessionSummary]
        let state: DashboardServerConnectionState
    }

    private(set) var updates: [Update] = []
    private(set) var notificationInvalidations: [String] = []

    func dashboardPoolNotificationInboxChanged(profileID: String) {
        notificationInvalidations.append(profileID)
    }

    func dashboardPoolDidUpdate(
        profileID: String,
        sessions: [SessionSummary],
        state: DashboardServerConnectionState
    ) {
        updates.append(Update(sessions: sessions, state: state))
    }
}
