import Foundation
import Observation
import Synchronization
import Testing
import UIKit
@testable import TronMobile

@Suite("Dashboard state ownership")
struct DashboardStateOwnerTests {

    @Test("initial session loading is shown only while an empty catalog is converging")
    func sessionInitialLoadingPresentation() {
        #expect(SessionDashboardPresentationPolicy.showsInitialLoading(
            sessionCount: 0,
            selectedCatalogIsLoading: false,
            selectedConnectionState: .connecting,
            serverStates: []
        ))
        #expect(SessionDashboardPresentationPolicy.showsInitialLoading(
            sessionCount: 0,
            selectedCatalogIsLoading: false,
            selectedConnectionState: .connected,
            serverStates: [.connected, .reconnecting]
        ))
        #expect(!SessionDashboardPresentationPolicy.showsInitialLoading(
            sessionCount: 1,
            selectedCatalogIsLoading: true,
            selectedConnectionState: .reconnecting,
            serverStates: [.connecting]
        ))
        #expect(!SessionDashboardPresentationPolicy.showsInitialLoading(
            sessionCount: 0,
            selectedCatalogIsLoading: false,
            selectedConnectionState: .connected,
            serverStates: [.connected]
        ))
        #expect(!SessionDashboardPresentationPolicy.showsInitialLoading(
            sessionCount: 0,
            selectedCatalogIsLoading: false,
            selectedConnectionState: .offline("unavailable"),
            serverStates: [.offline]
        ))
    }

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

    @MainActor
    @Test("same-route delivery is a no-op that does not arm retirement")
    func sameRouteDeliveryPreservesMountedRoute() {
        var owner = SessionRouteReplacementOwner()
        let route = AppModel.SessionNavigationRoute(sessionID: "session", editorText: "draft")
        let token = PresentationSurfaceToken(id: "chat.session", generation: UUID())

        #expect(owner.request(
            current: route,
            currentToken: token,
            replacement: route
        ) == .present(route))
        #expect(owner.completeRetirement(routeID: route.id, token: token) == nil)
    }

    @MainActor
    @Test("session replacement pops the mounted route before admitting the fork")
    func sessionRouteReplacementWaitsForExactRetirement() throws {
        var owner = SessionRouteReplacementOwner()
        let source = AppModel.SessionNavigationRoute(sessionID: "source", editorText: nil)
        let fork = AppModel.SessionNavigationRoute(sessionID: "fork", editorText: "retained")
        let sourceToken = PresentationSurfaceToken(id: "chat.source", generation: UUID())
        let staleToken = PresentationSurfaceToken(id: "chat.source", generation: UUID())

        #expect(owner.request(
            current: source,
            currentToken: sourceToken,
            replacement: fork
        ) == .dismissCurrent)
        #expect(owner.completeRetirement(routeID: "stale", token: sourceToken) == nil)
        #expect(owner.completeRetirement(routeID: source.id, token: staleToken) == nil)
        let completed = owner.completeRetirement(routeID: source.id, token: sourceToken)
        let replacement = try #require(completed)
        #expect(replacement == fork)
        #expect(owner.completeRetirement(routeID: source.id, token: sourceToken) == nil)
    }

    @MainActor
    @Test("a newer replacement updates the pending fork without bypassing retirement")
    func sessionRouteReplacementCoalescesWhilePopping() throws {
        var owner = SessionRouteReplacementOwner()
        let source = AppModel.SessionNavigationRoute(sessionID: "source", editorText: nil)
        let first = AppModel.SessionNavigationRoute(sessionID: "first", editorText: nil)
        let newer = AppModel.SessionNavigationRoute(sessionID: "newer", editorText: nil)
        let sourceToken = PresentationSurfaceToken(id: "chat.source", generation: UUID())

        #expect(owner.request(
            current: source,
            currentToken: sourceToken,
            replacement: first
        ) == .dismissCurrent)
        #expect(owner.request(
            current: nil,
            currentToken: nil,
            replacement: newer
        ) == .waitForRetirement)
        let completed = owner.completeRetirement(routeID: source.id, token: sourceToken)
        let replacement = try #require(completed)
        #expect(replacement == newer)
    }

    @Test("retryable catalog failures retry only for the current owner")
    func catalogRetryPolicy() {
        #expect(DashboardCatalogRetryPolicy.shouldRetry(isRetryableFailure: true, isCurrent: true))
        #expect(!DashboardCatalogRetryPolicy.shouldRetry(isRetryableFailure: false, isCurrent: true))
        #expect(!DashboardCatalogRetryPolicy.shouldRetry(isRetryableFailure: true, isCurrent: false))
        #expect(DashboardCatalogRetryPolicy.isRetryableFailure(GatewayFailure(
            code: "timeout", message: "Read timed out.", retryable: true, details: nil
        )))
        #expect(!DashboardCatalogRetryPolicy.isRetryableFailure(GatewayFailure(
            code: "timeout", message: "Read is not retryable.", retryable: false, details: nil
        )))
        #expect(!DashboardCatalogRetryPolicy.isRetryableFailure(GatewayFailure(
            code: "unauthenticated", message: "Pair again.", retryable: true, details: nil
        )))
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
            gatewayVersion: "1", piVersion: "1", protocolVersion: 6, minProtocolVersion: 6,
            machineId: other.machineId, machineGroupID: other.machineGroupID,
            machineName: "Other", capabilities: []
        )
        #expect(DashboardGatewayConnectionPool.admitsIdentity(matchingInfo, for: other))
        #expect(!DashboardGatewayConnectionPool.admitsIdentity(
            GatewayInfo(
                gatewayVersion: "1", piVersion: "1", protocolVersion: 6, minProtocolVersion: 6,
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
            await socket.enqueue(Data(#"{"type":"hello","gatewayVersion":"1","piVersion":"1","protocolVersion":6,"minProtocolVersion":6,"machineId":"remote-runtime","machineGroupID":"remote-machine","machineName":"Remote","gatewayChannel":"stable","capabilities":[]}"#.utf8))

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
    @Test("secondary catalog retries past warning threshold without another invalidation")
    func secondaryCatalogRetryConvergesWithoutInvalidation() async throws {
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
            let recorder = DashboardPoolRecorder()
            let pool = DashboardGatewayConnectionPool(
                clientFactory: { GatewayClient(socketFactory: factory.factory, clock: clock.clock) },
                clock: clock.clock
            )
            pool.delegate = recorder
            await socket.enqueue(Data(#"{"type":"hello","gatewayVersion":"1","piVersion":"1","protocolVersion":6,"minProtocolVersion":6,"machineId":"remote-runtime","machineGroupID":"remote-machine","machineName":"Remote","gatewayChannel":"stable","capabilities":[]}"#.utf8))
            pool.reconcile(
                profiles: [selected, remote],
                selectedProfileID: selected.id,
                token: { $0.id == remote.id ? "token" : nil }
            )

            try await socket.waitUntilSent(count: 2)
            var catalog = try Self.requestFrame(await socket.sentFrames()[1])
            for attempt in 0..<3 {
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
                if attempt < 3 {
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
            }
            try await recorder.waitForState(.stale, profileID: remote.id)
            let retried = try Self.requestFrame(await socket.sentFrames()[4])
            #expect(retried.method == "session.list")
            await socket.enqueue(Self.catalogResponse(id: retried.id, sessions: [summary(revision: 2)], listRevision: 2))
            try await recorder.waitForState(.connected, profileID: remote.id)
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
            await socket.enqueue(Data(#"{"type":"hello","gatewayVersion":"1","piVersion":"1","protocolVersion":6,"minProtocolVersion":6,"machineId":"remote-runtime","machineGroupID":"remote-machine","machineName":"Remote","gatewayChannel":"stable","capabilities":[]}"#.utf8))
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
    @Test("a background catalog follows up when its final traversal is invalidated")
    func secondaryCatalogFollowsUpAfterInvalidatedFinalTraversal() async throws {
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
            await socket.enqueue(Data(#"{"type":"hello","gatewayVersion":"1","piVersion":"1","protocolVersion":6,"minProtocolVersion":6,"machineId":"remote-runtime","machineGroupID":"remote-machine","machineName":"Remote","gatewayChannel":"stable","capabilities":[]}"#.utf8))
            pool.reconcile(
                profiles: [selected, remote],
                selectedProfileID: selected.id,
                token: { $0.id == remote.id ? "token" : nil }
            )

            // The first traversal publishes, and a list change that arrives
            // during it leaves exactly one follow-up traversal owed.
            try await socket.waitUntilSent(count: 2)
            let first = try Self.requestFrame(await socket.sentFrames()[1])
            await socket.enqueue(Self.listChangedEvent())
            await socket.enqueue(Self.catalogResponse(
                id: first.id,
                sessions: [summary(revision: 1)],
                listRevision: 1,
                archivedCount: 0
            ))

            // The final traversal reads while another list change lands, and the
            // Gateway answers with a page this client rejects. Nothing in that
            // traversal can be published, so the newer count it was the only
            // reader of has to arrive through the deferred follow-up.
            try await socket.waitUntilSent(count: 3)
            let rejected = try Self.requestFrame(await socket.sentFrames()[2])
            await socket.enqueue(Self.listChangedEvent())
            await socket.enqueue(Self.catalogResponse(
                id: rejected.id,
                sessions: [summary(revision: 2), summary(revision: 3)],
                listRevision: 2,
                archivedCount: 1
            ))

            let followUpArrived = await socket.waitUntilSent(count: 4, within: .seconds(2))
            try #require(
                followUpArrived,
                "the deferred catalog follow-up was dropped after its final traversal was invalidated"
            )
            try await Task.sleep(for: .milliseconds(20))
            #expect((await socket.sentFrames()).count == 4)
            let followUp = try Self.requestFrame(await socket.sentFrames()[3])
            #expect(followUp.method == "session.list")
            await socket.enqueue(Self.catalogResponse(
                id: followUp.id,
                sessions: [summary(revision: 4)],
                listRevision: 3,
                archivedCount: 2
            ))
            try await Self.waitUntil { recorder.archivedCounts.last?.count == 2 }
            #expect(recorder.authoritativeCatalogPublications.contains(remote.id))
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
            let pool = DashboardGatewayConnectionPool(
                clientFactory: { GatewayClient(socketFactory: socketFactory.factory) }
            )
            pool.delegate = recorder
            let hello = Data(#"{"type":"hello","gatewayVersion":"1","piVersion":"1","protocolVersion":6,"minProtocolVersion":6,"machineId":"remote-runtime","machineGroupID":"remote-machine","machineName":"Remote","gatewayChannel":"stable","capabilities":[]}"#.utf8)
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
            await oldSocket.enqueue(Data(#"{"type":"event","topic":"transport.disconnected","payload":{"reason":"disconnected"}}"#.utf8))
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

    @MainActor
    @Test("a secondary reconnect answered unchanged republishes its catalog authority")
    func secondaryReconnectUnchangedRepublishesAuthority() async throws {
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
            let pool = DashboardGatewayConnectionPool(
                clientFactory: { GatewayClient(socketFactory: socketFactory.factory) }
            )
            pool.delegate = recorder
            let hello = Data(#"{"type":"hello","gatewayVersion":"1","piVersion":"1","protocolVersion":6,"minProtocolVersion":6,"machineId":"remote-runtime","machineGroupID":"remote-machine","machineName":"Remote","gatewayChannel":"stable","capabilities":[]}"#.utf8)
            await oldSocket.enqueue(hello)
            pool.reconcile(
                profiles: [selected, remote], selectedProfileID: selected.id,
                token: { $0.id == remote.id ? "token" : nil }
            )
            try await oldSocket.waitUntilSent(count: 2)
            let initial = try Self.requestFrame(await oldSocket.sentFrames()[1])
            await oldSocket.enqueue(Self.catalogResponse(
                id: initial.id, sessions: [summary(revision: 1)], listRevision: 1,
                projectionToken: "epoch-one:1"
            ))
            try await Self.waitUntil {
                recorder.updates.last?.sessions.first?.summaryRevision == 1
                    && recorder.updates.last?.state == .connected
            }

            // The epoch retires. The profile leaves the dashboard and the
            // container can no longer read its rows, which the pool reports as
            // an authoritative-catalog change.
            await replacement.enqueue(hello)
            await oldSocket.enqueue(Self.stoppingEvent())

            // The replacement connection names the retained token, and the
            // Gateway answers unchanged: no rows, no new membership. The rows
            // stay exactly as they were, but the state and the container's
            // authority must still be republished for this replacement epoch.
            try await replacement.waitUntilSent(count: 2)
            let publicationsAfterRetirement = recorder.authoritativeCatalogPublications.count
            let reconnectedFrame = try JSONDecoder.gateway.decode(
                JSONValue.self, from: await replacement.sentFrames()[1]
            ).objectValue
            #expect(reconnectedFrame?["method"]?.stringValue == "session.list")
            #expect(reconnectedFrame?["params"]?.objectValue?["projectionToken"]?.stringValue == "epoch-one:1")
            let reconnectedID = try #require(reconnectedFrame?["id"]?.stringValue)
            await replacement.enqueue(Self.catalogResponse(
                id: reconnectedID, sessions: [], listRevision: 1,
                projectionToken: "epoch-one:1", notModified: true
            ))
            try await Self.waitUntil {
                recorder.authoritativeCatalogPublications.count > publicationsAfterRetirement
                    && recorder.updates.last?.state == .connected
            }
            #expect(recorder.updates.last?.sessions.first?.summaryRevision == 1)

            pool.retire()
            await pool.waitForRetirement()
        }
    }

    @MainActor
    @Test("a dashboard connection retries transient failures past the removed attempt allowance")
    func secondaryReconnectHasNoAttemptBudget() async throws {
        try await withTestWatchdog { @MainActor in
            let remote = GatewayProfile(id: "remote", label: "Remote", host: "remote.test", port: 9847,
                machineId: "remote-runtime", machineGroupID: "remote-machine", deviceId: "device")
            let sockets = (0..<12).map { _ in ScriptedGatewaySocket() }
            let factory = ScriptedGatewaySocketFactory(sockets: sockets)
            let clock = ManualClock()
            let pool = DashboardGatewayConnectionPool(
                clientFactory: { GatewayClient(socketFactory: factory.factory, clock: clock.clock) },
                clock: clock.clock
            )
            let hello = Data(#"{"type":"hello","gatewayVersion":"1","piVersion":"1","protocolVersion":6,"minProtocolVersion":6,"machineId":"remote-runtime","machineGroupID":"remote-machine","machineName":"Remote","gatewayChannel":"stable","capabilities":[]}"#.utf8)
            await sockets[11].enqueue(hello)
            for socket in sockets[0...10] {
                await socket.failNextSend(GatewayFailure(
                    code: "timeout", message: "synthetic transport-open failure", retryable: true, details: nil
                ))
            }
            pool.reconcile(profiles: [remote], selectedProfileID: nil, token: { _ in "fixture" })
            // Twelve attempts, each served by the pump's clock: this profile is
            // unreachable after three of them, so the waits escalate to the
            // pool's five-minute cap, and the twelfth still connects. No attempt
            // allowance stops the retries.
            for attempt in 1...12 {
                _ = try await Self.secondsUntilRequest(
                    attempt, clock: clock, factory: factory, limit: 320
                )
            }
            try await sockets[11].waitUntilSent(count: 2)
            #expect(factory.requests.count == 12)
            pool.retire()
            await pool.waitForRetirement()
        }
    }

    @MainActor
    @Test("dashboard retry pauses off path and resumes immediately on path return")
    func dashboardRetryPausesForUnsatisfiedPath() async throws {
        try await withTestWatchdog { @MainActor in
            let profile = GatewayProfile(
                id: "remote", label: "Remote", host: "remote.test", port: 9_847,
                machineId: "remote-runtime", machineGroupID: "remote-machine", deviceId: "device"
            )
            let clock = ManualClock()
            let sockets = (0..<2).map { _ in ScriptedGatewaySocket() }
            let factory = ScriptedGatewaySocketFactory(sockets: sockets)
            let pool = DashboardGatewayConnectionPool(
                clientFactory: { GatewayClient(socketFactory: factory.factory, clock: clock.clock) },
                clock: clock.clock
            )
            defer { pool.retire() }
            await sockets[0].failNextSend(GatewayFailure(
                code: "timeout", message: "synthetic handshake timeout", retryable: true, details: nil
            ))
            pool.reconcile(profiles: [profile], selectedProfileID: nil, token: { _ in "token" })
            try await sockets[0].waitUntilClosed()
            try await clock.waitUntilSleeping(count: 1)

            pool.notePathHint(profileID: profile.id, satisfied: false)
            clock.advance(by: .seconds(60))
            for _ in 0..<20 { await Task.yield() }
            #expect(factory.requests.count == 1)

            pool.notePathHint(profileID: profile.id, satisfied: true)
            try await sockets[1].waitUntilSent(count: 1)
            #expect(factory.requests.count == 2)
            pool.retire()
            await pool.waitForRetirement()
        }
    }

    @MainActor
    @Test("an unreachable secondary profile backs off to one attempt per five minutes")
    func unreachableSecondaryProfileBacksOff() async throws {
        try await withTestWatchdog(timeout: .seconds(30)) { @MainActor in
            let profile = GatewayProfile(
                id: "remote", label: "Remote", host: "remote.test", port: 9_847,
                machineId: "remote-runtime", machineGroupID: "remote-machine", deviceId: "device"
            )
            // Every attempt gets a socket whose hello write fails: the shape of a
            // Mac that is not listening on that port.
            let sockets = (0..<12).map { _ in ScriptedGatewaySocket() }
            let factory = ScriptedGatewaySocketFactory(sockets: sockets)
            let clock = ManualClock()
            let recorder = DashboardPoolRecorder()
            let pool = DashboardGatewayConnectionPool(
                clientFactory: { GatewayClient(socketFactory: factory.factory, clock: clock.clock) },
                clock: clock.clock
            )
            pool.delegate = recorder
            for socket in sockets {
                await socket.failNextSend(GatewayFailure(
                    code: "timeout", message: "synthetic transport-open failure", retryable: true, details: nil
                ))
            }
            pool.reconcile(profiles: [profile], selectedProfileID: nil, token: { _ in "token" })

            // Attempt 1 is the initial connect. Each later attempt is one socket
            // from the factory, so the seconds the pump spends waiting for it are
            // the wait the entry served before that attempt.
            var waits: [Int] = []
            for attempt in 1...9 {
                waits.append(try await Self.secondsUntilRequest(
                    attempt, clock: clock, factory: factory, limit: 320
                ))
            }
            #expect(waits[0] <= 3, "waits: \(waits)")
            // Below the unreachable threshold the entry keeps the standard
            // progression (2 s, then ×1.7), so a blip is retried promptly
            // without the wait being pinned at the base interval.
            #expect(waits[1] <= 2, "waits: \(waits)")
            #expect(waits[2] > waits[1], "waits: \(waits)")
            #expect(waits[2] <= 6, "waits: \(waits)")
            // The third consecutive failed attempt marks the profile
            // unreachable: every wait after it is longer than the one before it,
            // until the curve reaches `POOL_MAX_RETRY`.
            for index in 3...6 {
                #expect(waits[index] > waits[index - 1], "waits: \(waits)")
            }
            // Backed off: one attempt per `POOL_MAX_RETRY`, never faster.
            for wait in waits[6...] {
                #expect(wait >= 300, "a backed-off wait was \(wait) s: \(waits)")
            }
            // Nine attempts over about twenty simulated minutes; the standard
            // 15-second curve would have made roughly seventy in that window.
            #expect(waits.reduce(0, +) > 1_000, "waits: \(waits)")

            // The profile the user sees is unreachable, not merely reconnecting.
            let states = recorder.updates.filter { $0.profileID == profile.id }.map(\.state)
            #expect(states.contains { $0.label.hasPrefix("No path to this Mac") })

            pool.retire()
            await pool.waitForRetirement()
        }
    }

    @MainActor
    @Test("a parked unreachable retry resumes on path return and a retired profile reconnects at once")
    func unreachableSecondaryProfileRetriesAtOnce() async throws {
        try await withTestWatchdog { @MainActor in
            let profile = GatewayProfile(
                id: "remote", label: "Remote", host: "remote.test", port: 9_847,
                machineId: "remote-runtime", machineGroupID: "remote-machine", deviceId: "device"
            )
            let sockets = (0..<8).map { _ in ScriptedGatewaySocket() }
            let factory = ScriptedGatewaySocketFactory(sockets: sockets)
            let clock = ManualClock()
            let pool = DashboardGatewayConnectionPool(
                clientFactory: { GatewayClient(socketFactory: factory.factory, clock: clock.clock) },
                clock: clock.clock
            )
            for socket in sockets {
                await socket.failNextSend(GatewayFailure(
                    code: "timeout", message: "synthetic transport-open failure", retryable: true, details: nil
                ))
            }
            pool.reconcile(profiles: [profile], selectedProfileID: nil, token: { _ in "token" })
            _ = try await Self.secondsUntilRequest(1, clock: clock, factory: factory, limit: 40)
            // Let the curve escalate, so the parked wait is a long one.
            for attempt in 1...4 {
                _ = try await Self.secondsUntilRequest(
                    attempt + 1, clock: clock, factory: factory, limit: 320
                )
            }
            #expect(factory.requests.count == 5)
            try await Task.sleep(for: .milliseconds(20))

            // The network goes away and comes back. The unsatisfied hint parks
            // the escalated wait; the return hint is a real path change, so it
            // starts the next attempt at once, without advancing the clock
            // through it.
            try await clock.waitUntilSleeping(count: 1)
            pool.notePathHint(profileID: profile.id, satisfied: false)
            pool.notePathHint(profileID: profile.id, satisfied: true)
            try await Self.waitUntil { factory.requests.count == 6 }
            try await Task.sleep(for: .milliseconds(20))

            // Scene retirement parks recovery and removes every entry, so the
            // next foreground reconcile starts them again and connects at once.
            pool.retire()
            await pool.waitForRetirement()
            pool.reconcile(profiles: [profile], selectedProfileID: nil, token: { _ in "token" })
            try await Self.waitUntil { factory.requests.count == 7 }

            pool.retire()
            await pool.waitForRetirement()
        }
    }

    @MainActor
    @Test("a lost network parks a pool retry and the path return resumes it")
    func lostNetworkParksPoolRetryUntilPathReturns() async throws {
        try await withTestWatchdog(timeout: .seconds(20)) { @MainActor in
            let profile = GatewayProfile(
                id: "remote", label: "Remote", host: "remote.test", port: 9_847,
                machineId: "remote-runtime", machineGroupID: "remote-machine", deviceId: "device"
            )
            let sockets = (0..<4).map { _ in ScriptedGatewaySocket() }
            let factory = ScriptedGatewaySocketFactory(sockets: sockets)
            let clock = ManualClock()
            let (log, cleanup) = Self.makeAppLog()
            defer { cleanup() }
            let pool = DashboardGatewayConnectionPool(
                clientFactory: { GatewayClient(socketFactory: factory.factory, clock: clock.clock) },
                clock: clock.clock,
                appLog: log
            )
            await sockets[0].failNextSend(GatewayFailure(
                code: "timeout", message: "synthetic transport-open failure", retryable: true, details: nil
            ))
            pool.reconcile(profiles: [profile], selectedProfileID: nil, token: { _ in "token" })
            _ = try await Self.waitForRecords(log, event: "gateway.attempt", count: 1)

            // Attempt 2 is in flight — its transport opened and its hello was
            // sent, so the entry holds no wait to cancel — when the network goes
            // away. Nothing cancels the retry attempt 2 is about to schedule.
            _ = try await Self.secondsUntilRequest(2, clock: clock, factory: factory, limit: 40)
            try await sockets[1].waitUntilSent(count: 1)
            pool.notePathHint(profileID: profile.id, satisfied: false)

            // Attempt 2 ends on the handshake deadline, and its wait runs out
            // while the network is still gone.
            var ticks = 0
            while await Self.recordCount(log, event: "gateway.attempt") < 2, ticks < 40 {
                clock.advance(by: .seconds(1))
                ticks += 1
                for _ in 0..<8 { await Task.yield() }
                try await Task.sleep(for: .milliseconds(1))
            }
            #expect(ticks < 40, "attempt 2 never finished")
            for _ in 0..<10 {
                clock.advance(by: .seconds(1))
                for _ in 0..<8 { await Task.yield() }
                try await Task.sleep(for: .milliseconds(1))
            }
            #expect(factory.requests.count == 2, "no attempt may start with the path gone")

            // The parked entry is named as such: the watchdog must not read a
            // returned loop's task as recovery still progressing.
            for _ in 0..<30 {
                clock.advance(by: GatewayConnectionEpisodeRecorder.watchdogInterval)
                for _ in 0..<8 { await Task.yield() }
                try await Task.sleep(for: .milliseconds(1))
            }
            let stalls = try await Self.waitForRecords(log, event: "reconnect.stalled", count: 1)
            #expect(stalls.count == 1, "the parked entry must be named once")
            #expect(
                stalls.first?.message.contains("guard=pathUnsatisfied") == true,
                "stalls: \(stalls.map(\.message))"
            )

            // A real path return retries at once, without advancing the clock.
            pool.notePathHint(profileID: profile.id, satisfied: true)
            try await Self.waitUntil { factory.requests.count == 3 }

            pool.retire()
            await pool.waitForRetirement()
        }
    }

    @MainActor
    @Test("a repeated satisfied path notice does not cut a pool profile's escalated backoff")
    func satisfiedPathNoticeDoesNotCutPoolBackoff() async throws {
        try await withTestWatchdog(timeout: .seconds(20)) { @MainActor in
            let profile = GatewayProfile(
                id: "remote", label: "Remote", host: "remote.test", port: 9_847,
                machineId: "remote-runtime", machineGroupID: "remote-machine", deviceId: "device"
            )
            let sockets = (0..<8).map { _ in ScriptedGatewaySocket() }
            let factory = ScriptedGatewaySocketFactory(sockets: sockets)
            let clock = ManualClock()
            let pool = DashboardGatewayConnectionPool(
                clientFactory: { GatewayClient(socketFactory: factory.factory, clock: clock.clock) },
                clock: clock.clock
            )
            for socket in sockets {
                await socket.failNextSend(GatewayFailure(
                    code: "timeout", message: "synthetic transport-open failure", retryable: true, details: nil
                ))
            }
            pool.reconcile(profiles: [profile], selectedProfileID: nil, token: { _ in "token" })
            _ = try await Self.secondsUntilRequest(1, clock: clock, factory: factory, limit: 40)
            for attempt in 1...4 {
                _ = try await Self.secondsUntilRequest(
                    attempt + 1, clock: clock, factory: factory, limit: 320
                )
            }
            #expect(factory.requests.count == 5)
            try await Task.sleep(for: .milliseconds(20))
            try await clock.waitUntilSleeping(count: 1)

            // A scene activation, and every network-monitor update while the
            // path is available, arrives as a satisfied notice on an unchanged
            // path. The escalated wait it did not change must stand: pumping the
            // clock through the next ten seconds may not produce an attempt.
            pool.notePathHint(profileID: profile.id, satisfied: true)
            for _ in 0..<10 {
                clock.advance(by: .seconds(1))
                for _ in 0..<8 { await Task.yield() }
                try await Task.sleep(for: .milliseconds(1))
            }
            #expect(factory.requests.count == 5, "the backoff was cut short")

            pool.retire()
            await pool.waitForRetirement()
        }
    }

    @MainActor
    @Test("a pool profile that dropped after connecting keeps backing off")
    func secondaryDropThenClosedPortKeepsBackingOff() async throws {
        try await withTestWatchdog(timeout: .seconds(30)) { @MainActor in
            let profile = GatewayProfile(
                id: "remote", label: "Remote", host: "remote.test", port: 9_847,
                machineId: "remote-runtime", machineGroupID: "remote-machine", deviceId: "device"
            )
            // The first socket completes a handshake, so the entry connects;
            // every socket after the drop is a closed port. The dashboard's
            // no-path classifier stops counting never-opened attempts as soon as
            // one attempt of the outage opened a transport, so the retry curve
            // may not read that counter.
            let sockets = (0..<9).map { _ in ScriptedGatewaySocket() }
            let factory = ScriptedGatewaySocketFactory(sockets: sockets)
            let clock = ManualClock()
            let pool = DashboardGatewayConnectionPool(
                clientFactory: { GatewayClient(socketFactory: factory.factory, clock: clock.clock) },
                clock: clock.clock
            )
            let hello = Data(#"{"type":"hello","gatewayVersion":"1","piVersion":"1","protocolVersion":6,"minProtocolVersion":6,"machineId":"remote-runtime","machineGroupID":"remote-machine","machineName":"Remote","gatewayChannel":"stable","capabilities":[]}"#.utf8)
            await sockets[0].enqueue(hello)
            for socket in sockets[1...] {
                await socket.failNextSend(GatewayFailure(
                    code: "timeout", message: "synthetic transport-open failure", retryable: true, details: nil
                ))
            }
            pool.reconcile(profiles: [profile], selectedProfileID: nil, token: { _ in "token" })
            try await sockets[0].waitUntilSent(count: 2)

            // The admitted connection drops — the client's own receive failure
            // creates the disconnect event, as a real transport loss does — and
            // the port stays closed.
            await sockets[0].failPendingReceivers(URLError(.networkConnectionLost))
            try await Self.waitUntil { pool.state(for: profile.id) == .reconnecting }
            #expect(factory.requests.count == 1)

            // Attempt 1 already happened; each later attempt is one socket from
            // the factory, so the seconds the pump spends waiting for it are the
            // wait the entry served before that attempt.
            var waits: [Int] = []
            for attempt in 2...9 {
                waits.append(try await Self.secondsUntilRequest(
                    attempt, clock: clock, factory: factory, limit: 320
                ))
            }
            // The standard progression runs up to the threshold, so the drop
            // itself never pins the wait at the base interval: only the first
            // retry may still be the base interval.
            #expect(waits.dropFirst().filter { $0 <= 3 }.count <= 1, "waits: \(waits)")
            // The wait grows past the standard cap and then escalates.
            for index in 3...5 {
                #expect(waits[index] > waits[index - 1], "waits: \(waits)")
            }
            #expect(waits.last! >= 300, "waits: \(waits)")
            // A Mac that went to sleep settles at one attempt per five minutes.
            for wait in waits[6...] {
                #expect(wait >= 300, "waits: \(waits)")
            }

            pool.retire()
            await pool.waitForRetirement()
        }
    }

    @MainActor
    @Test("a pool profile whose transports open but never answer hello keeps backing off")
    func handshakeFailuresBackOffWithoutPinning() async throws {
        try await withTestWatchdog(timeout: .seconds(30)) { @MainActor in
            let profile = GatewayProfile(
                id: "remote", label: "Remote", host: "remote.test", port: 9_847,
                machineId: "remote-runtime", machineGroupID: "remote-machine", deviceId: "device"
            )
            // Every socket opens and swallows the hello, so each attempt ends on
            // the shared 15-second handshake deadline. That diagnostic records an
            // opened transport, which is the other shape C-5 let wait two
            // seconds for ever.
            let sockets = (0..<6).map { _ in ScriptedGatewaySocket() }
            let factory = ScriptedGatewaySocketFactory(sockets: sockets)
            let clock = ManualClock()
            let pool = DashboardGatewayConnectionPool(
                clientFactory: { GatewayClient(socketFactory: factory.factory, clock: clock.clock) },
                clock: clock.clock
            )
            pool.reconcile(profiles: [profile], selectedProfileID: nil, token: { _ in "token" })

            var waits: [Int] = []
            for attempt in 1...6 {
                waits.append(try await Self.secondsUntilRequest(
                    attempt, clock: clock, factory: factory, limit: 320
                ))
            }
            #expect(waits[0] <= 2, "waits: \(waits)")
            // Each measurement starts when the previous attempt started, and
            // every entry costs the handshake deadline, so the wait the entry
            // served is the measured value minus that deadline. A two-second pin
            // would leave every one of them at two seconds.
            let servedWaits = waits.dropFirst().map { $0 - 15 }
            #expect(servedWaits.first! <= 3, "waits: \(waits)")
            for index in 2..<servedWaits.count {
                #expect(servedWaits[index] > servedWaits[index - 1], "waits: \(waits)")
            }
            #expect(servedWaits.last! >= 80, "waits: \(waits)")

            pool.retire()
            await pool.waitForRetirement()
        }
    }

    @MainActor
    @Test("a pool profile the Gateway answers with 503 keeps backing off")
    func busyUpgradeFailuresBackOffWithoutPinning() async throws {
        try await withTestWatchdog(timeout: .seconds(30)) { @MainActor in
            let profile = GatewayProfile(
                id: "remote", label: "Remote", host: "remote.test", port: 9_847,
                machineId: "remote-runtime", machineGroupID: "remote-machine", deviceId: "device"
            )
            // Every socket is admitted, sends its hello, and then answers the
            // upgrade with 503: the attempt fails as `busy` after the transport
            // opened, which is the third shape C-5 pinned at two seconds.
            let sockets = (0..<6).map { _ in
                ScriptedGatewaySocket(metadata: .init(closeCode: nil, httpStatusCode: 503))
            }
            let factory = ScriptedGatewaySocketFactory(sockets: sockets)
            let clock = ManualClock()
            let pool = DashboardGatewayConnectionPool(
                clientFactory: { GatewayClient(socketFactory: factory.factory, clock: clock.clock) },
                clock: clock.clock
            )
            for socket in sockets {
                await socket.failPendingReceivers(URLError(.badServerResponse))
            }
            pool.reconcile(profiles: [profile], selectedProfileID: nil, token: { _ in "token" })

            var waits: [Int] = []
            for attempt in 1...6 {
                waits.append(try await Self.secondsUntilRequest(
                    attempt, clock: clock, factory: factory, limit: 320
                ))
            }
            #expect(waits[0] <= 2, "waits: \(waits)")
            // A two-second pin would leave every later wait at the base
            // interval; the curve has to grow past it and escalate.
            #expect(waits.dropFirst().filter { $0 <= 3 }.count <= 1, "waits: \(waits)")
            #expect(waits.last! >= 80, "waits: \(waits)")

            pool.retire()
            await pool.waitForRetirement()
        }
    }

    @MainActor
    @Test("a pool profile's attempts and episodes are recorded once per outage")
    func poolAttemptsAndEpisodesAreRecorded() async throws {
        try await withTestWatchdog(timeout: .seconds(20)) { @MainActor in
            let profile = GatewayProfile(
                id: "remote", label: "Remote", host: "remote.test", port: 9_847,
                machineId: "remote-runtime", machineGroupID: "remote-machine", deviceId: "device"
            )
            let failing = ScriptedGatewaySocket()
            let connecting = ScriptedGatewaySocket()
            let factory = ScriptedGatewaySocketFactory(sockets: [failing, connecting])
            let clock = ManualClock()
            let (log, cleanup) = Self.makeAppLog()
            defer { cleanup() }
            let recorder = DashboardPoolRecorder()
            let pool = DashboardGatewayConnectionPool(
                clientFactory: { GatewayClient(socketFactory: factory.factory, clock: clock.clock) },
                clock: clock.clock,
                appLog: log
            )
            pool.delegate = recorder
            await failing.failNextSend(GatewayFailure(
                code: "timeout", message: "synthetic transport-open failure", retryable: true, details: nil
            ))
            await connecting.enqueue(Data(#"{"type":"hello","gatewayVersion":"1","piVersion":"1","protocolVersion":6,"minProtocolVersion":6,"machineId":"remote-runtime","machineGroupID":"remote-machine","machineName":"Remote","gatewayChannel":"stable","connectionId":"5bf6a9a2-0000-4000-8000-0000000000c5","capabilities":[]}"#.utf8))
            pool.reconcile(profiles: [profile], selectedProfileID: nil, token: { _ in "token" })

            let failed = try await Self.waitForRecords(log, event: "gateway.attempt", count: 1)
            #expect(failed[0].profileID == profile.id)
            #expect(failed[0].outcome == "failure")
            #expect(failed[0].message.contains("profile=\(profile.id)"))
            #expect(failed[0].message.contains("owner=pool"))
            #expect(failed[0].message.contains("attemptId=initial"))
            #expect(failed[0].message.contains("stageReached=transport-open"))
            #expect(failed[0].message.contains("reason=timeout"))
            #expect(failed[0].message.contains("foreground=true"))

            // The retry opens the replacement connection and closes the outage.
            clock.advance(by: .seconds(3))
            let attempts = try await Self.waitForRecords(log, event: "gateway.attempt", count: 2)
            #expect(attempts[1].outcome == "success")
            #expect(attempts[1].message.contains("stageReached=connected"))
            #expect(attempts[1].message.contains("delayBeforeMs=3000"))
            #expect(attempts[1].message.contains("gatewayConnectionId=5bf6a9a2-0000-4000-8000-0000000000c5"))
            let episodes = try await Self.waitForRecords(log, event: "connection.episode", count: 1)
            #expect(episodes[0].profileID == profile.id)
            #expect(episodes[0].outcome == "connected")
            #expect(episodes[0].message.contains("attempts=2"))
            #expect(episodes[0].message.contains("causes=timeout"))
            #expect(episodes[0].message.contains("endedBy=connected"))
            #expect(episodes[0].message.contains("foregroundMs=3000"))
            #expect(episodes[0].message.contains("maxGapBetweenAttemptsMs=3000"))

            // Answer the catalog read so the only remaining work is the drop.
            try await connecting.waitUntilSent(count: 2)
            let catalog = try Self.requestFrame(await connecting.sentFrames()[1])
            #expect(catalog.method == "session.list")
            await connecting.enqueue(Self.catalogResponse(
                id: catalog.id, sessions: [summary(revision: 1)], listRevision: 1
            ))
            for _ in 0..<200 where pool.state(for: profile.id) != .connected {
                try await Task.sleep(for: .milliseconds(5))
            }
            let state = pool.state(for: profile.id)
            let frames = await connecting.sentFrames().count
            #expect(state == .connected, "state was \(String(describing: state)) with \(frames) frames sent")
            #expect(await Self.recordCount(log, event: "connection.episode") == 1)

            pool.retire()
            await pool.waitForRetirement()
        }
    }

    @MainActor
    @Test(
        "retiring the pool names why the open episode ended",
        arguments: [(GatewayEpisodeEnd.background, "endedBy=background"), (.stopped, "endedBy=stopped")]
    )
    func retiringPoolNamesItsEndedBy(endedBy: GatewayEpisodeEnd, expected: String) async throws {
        try await withTestWatchdog(timeout: .seconds(20)) { @MainActor in
            let profile = GatewayProfile(
                id: "remote", label: "Remote", host: "remote.test", port: 9_847,
                machineId: "remote-runtime", machineGroupID: "remote-machine", deviceId: "device"
            )
            let failing = ScriptedGatewaySocket()
            let factory = ScriptedGatewaySocketFactory(sockets: [failing, ScriptedGatewaySocket()])
            let clock = ManualClock()
            let (log, cleanup) = Self.makeAppLog()
            defer { cleanup() }
            let pool = DashboardGatewayConnectionPool(
                clientFactory: { GatewayClient(socketFactory: factory.factory, clock: clock.clock) },
                clock: clock.clock,
                appLog: log
            )
            await failing.failNextSend(GatewayFailure(
                code: "timeout", message: "synthetic transport-open failure", retryable: true, details: nil
            ))
            pool.reconcile(profiles: [profile], selectedProfileID: nil, token: { _ in "token" })
            _ = try await Self.waitForRecords(log, event: "gateway.attempt", count: 1)

            // Scene retirement parks every pool entry while a projection
            // retirement (a profile switch, removal, pairing or teardown) stops
            // it; the episode it was explaining ends for that reason.
            pool.retire(endedBy: endedBy)
            await pool.waitForRetirement()
            let episodes = try await Self.waitForRecords(log, event: "connection.episode", count: 1)
            #expect(episodes[0].profileID == profile.id)
            #expect(episodes[0].outcome == endedBy.rawValue)
            #expect(episodes[0].message.contains(expected))
            #expect(episodes[0].message.contains("attempts=1"))
            #expect(episodes[0].message.contains("causes=timeout"))
        }
    }

    @MainActor
    @Test("a parked pool entry names the guard that is holding its recovery")
    func parkedPoolEntryNamesItsStallGuard() async throws {
        try await withTestWatchdog(timeout: .seconds(20)) { @MainActor in
            let profile = GatewayProfile(
                id: "remote", label: "Remote", host: "remote.test", port: 9_847,
                machineId: "remote-runtime", machineGroupID: "remote-machine", deviceId: "device"
            )
            let sockets = (0..<3).map { _ in ScriptedGatewaySocket() }
            let factory = ScriptedGatewaySocketFactory(sockets: sockets)
            let clock = ManualClock()
            let (log, cleanup) = Self.makeAppLog()
            defer { cleanup() }
            let pool = DashboardGatewayConnectionPool(
                clientFactory: { GatewayClient(socketFactory: factory.factory, clock: clock.clock) },
                clock: clock.clock,
                appLog: log
            )
            await sockets[0].failNextSend(GatewayFailure(
                code: "timeout", message: "synthetic transport-open failure", retryable: true, details: nil
            ))
            pool.reconcile(profiles: [profile], selectedProfileID: nil, token: { _ in "token" })
            _ = try await Self.waitForRecords(log, event: "gateway.attempt", count: 1)

            // The path is gone while the entry has an outage to explain: the
            // watchdog must name that, not report a generic silent gap.
            pool.notePathHint(profileID: profile.id, satisfied: false)
            for _ in 0..<30 {
                clock.advance(by: GatewayConnectionEpisodeRecorder.watchdogInterval)
                for _ in 0..<8 { await Task.yield() }
                _ = try? await Task.sleep(for: .milliseconds(1))
            }
            let stalls = try await Self.waitForRecords(log, event: "reconnect.stalled", count: 1)
            #expect(stalls[0].profileID == profile.id)
            #expect(stalls[0].message.contains("guard=pathUnsatisfied"))
            #expect(await Self.recordCount(log, event: "reconnect.stalled") == 1)

            pool.retire()
            await pool.waitForRetirement()
        }
    }

    @Test("dashboard authentication failure waits for explicit Retry")
    func dashboardAuthenticationFailureStopsUntilRetry() async throws {
        try await withTestWatchdog { @MainActor in
            let profile = GatewayProfile(
                id: "remote", label: "Remote", host: "remote.test", port: 9_847,
                machineId: "remote-runtime", machineGroupID: "remote-machine", deviceId: "device"
            )
            let sockets = [ScriptedGatewaySocket(), ScriptedGatewaySocket()]
            let factory = ScriptedGatewaySocketFactory(sockets: sockets)
            let pool = DashboardGatewayConnectionPool(
                clientFactory: { GatewayClient(socketFactory: factory.factory) }
            )
            await sockets[0].failNextSend(GatewayFailure(
                code: "unauthenticated", message: "Pair this Gateway again.", retryable: false, details: nil
            ))
            pool.reconcile(profiles: [profile], selectedProfileID: nil, token: { _ in "token" })
            try await sockets[0].waitUntilClosed()
            try await Self.waitUntil { pool.state(for: profile.id) == .offline }
            pool.notePathHint(profileID: profile.id, satisfied: true)
            for _ in 0..<20 { await Task.yield() }
            #expect(factory.requests.count == 1)

            pool.retry(profileID: profile.id)
            try await sockets[1].waitUntilSent(count: 1)
            #expect(factory.requests.count == 2)
            pool.retire()
            await pool.waitForRetirement()
        }
    }

    @Test("dashboard retirement barriers are per-profile across an A to B to A handoff")
    func dashboardRetirementIsPerProfile() async throws {
        try await withTestWatchdog { @MainActor in
            let profileA = GatewayProfile(
                id: "profile-a", label: "A", host: "a.test", port: 9_847,
                machineId: "machine-a", machineGroupID: "group-a", deviceId: "device-a"
            )
            let profileB = GatewayProfile(
                id: "profile-b", label: "B", host: "b.test", port: 9_847,
                machineId: "machine-b", machineGroupID: "group-b", deviceId: "device-b"
            )
            let aOld = ScriptedGatewaySocket(suspendsClose: true)
            let b = ScriptedGatewaySocket()
            let aNew = ScriptedGatewaySocket()
            let factory = ScriptedGatewaySocketFactory(sockets: [aOld, b, aNew])
            let pool = DashboardGatewayConnectionPool(clientFactory: {
                GatewayClient(socketFactory: factory.factory)
            })
            let helloA = Data(#"{"type":"hello","gatewayVersion":"1","piVersion":"1","protocolVersion":6,"minProtocolVersion":6,"machineId":"machine-a","machineGroupID":"group-a","machineName":"A","gatewayChannel":"stable","capabilities":[]}"#.utf8)
            let helloB = Data(#"{"type":"hello","gatewayVersion":"1","piVersion":"1","protocolVersion":6,"minProtocolVersion":6,"machineId":"machine-b","machineGroupID":"group-b","machineName":"B","gatewayChannel":"stable","capabilities":[]}"#.utf8)
            await aOld.enqueue(helloA)
            pool.reconcile(profiles: [profileA], selectedProfileID: nil, token: { _ in "token-a" })
            try await aOld.waitUntilSent(count: 2)

            await b.enqueue(helloB)
            pool.reconcile(profiles: [profileB], selectedProfileID: nil, token: { _ in "token-b" })
            try await b.waitUntilSent(count: 1)
            try await aOld.waitUntilCloseInvoked()
            #expect(await aOld.closeInvocationCount() == 1)
            #expect(!(await aOld.closed()))

            pool.reconcile(profiles: [profileA], selectedProfileID: nil, token: { _ in "token-a" })
            await aOld.releaseClose()
            try await aOld.waitUntilClosed()
            await aNew.enqueue(helloA)
            try await aNew.waitUntilSent(count: 1)
            #expect(factory.requests.count == 3)

            pool.retire()
            await pool.waitForRetirement()
        }
    }

    @MainActor
    @Test("a predecessor retirement cannot erase a same-profile successor close barrier")
    func chainedRetirementKeepsLatestBarrier() async throws {
        try await withTestWatchdog { @MainActor in
            let profile = GatewayProfile(id: "a", label: "A", host: "a.test", port: 9847,
                machineId: "machine-a", machineGroupID: "group-a", deviceId: "device-a")
            let other = GatewayProfile(id: "b", label: "B", host: "b.test", port: 9847,
                machineId: "machine-b", machineGroupID: "group-b", deviceId: "device-b")
            let first = ScriptedGatewaySocket(suspendsClose: true)
            let second = ScriptedGatewaySocket(suspendsClose: true)
            let third = ScriptedGatewaySocket()
            let unrelated = ScriptedGatewaySocket()
            let clock = ManualClock()
            var clients = [first, second, third, unrelated].map { socket in
                GatewayClient(socketFactory: ScriptedGatewaySocketFactory(socket: socket).factory, clock: clock.clock)
            }
            let ownedClients = clients
            let helloA = Data(#"{"type":"hello","gatewayVersion":"1","piVersion":"1","protocolVersion":6,"minProtocolVersion":6,"machineId":"machine-a","machineGroupID":"group-a","machineName":"A","gatewayChannel":"stable","capabilities":[]}"#.utf8)
            // Give the second injected client unsettled physical close work so
            // the two retirement boundaries can be released independently.
            await second.enqueue(helloA)
            _ = try await clients[1].connect(profile: profile, token: "fixture")
            let pool = DashboardGatewayConnectionPool(clientFactory: { clients.removeFirst() },
                clock: clock.clock)
            do {
                await first.enqueue(helloA)
                pool.reconcile(profiles: [profile], selectedProfileID: nil, token: { _ in "fixture" })
                try await first.waitUntilSent(count: 2)
                pool.retire()
                try await first.waitUntilCloseInvoked()
                pool.reconcile(profiles: [profile], selectedProfileID: nil, token: { _ in "fixture" })
                pool.retire()
                await first.releaseClose()
                try await second.waitUntilCloseInvoked()
                // R1 is complete, but R2 still owns the per-profile barrier.
                pool.reconcile(profiles: [profile, other], selectedProfileID: nil, token: { _ in "fixture" })
                try await unrelated.waitUntilSent(count: 1)
                #expect(await third.sentFrames().isEmpty)
                await third.enqueue(helloA)
                await second.releaseClose()
                try await third.waitUntilSent(count: 2)
            } catch {
                await first.releaseClose(); await second.releaseClose()
                pool.retire(); await pool.waitForRetirement()
                for client in ownedClients { await client.close() }
                throw error
            }
            pool.retire(); await pool.waitForRetirement()
            for client in ownedClients { await client.close() }
        }
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
        projectionToken: String? = nil,
        nextCursor: String? = nil,
        archivedCount: Int? = nil,
        notModified: Bool = false
    ) -> Data {
        let encoded = try! JSONEncoder.gateway.encode(sessions)
        let rawSessions = try! JSONSerialization.jsonObject(with: encoded)
        var result: [String: Any] = [
            "sessions": rawSessions,
            "listRevision": listRevision,
            "projectionToken": projectionToken ?? "epoch-1:\(listRevision)",
        ]
        if let nextCursor { result["nextCursor"] = nextCursor }
        if let archivedCount { result["archivedCount"] = archivedCount }
        if notModified { result["notModified"] = true }
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
            "type": "event", "topic": "notification.inbox.changed",
            "payload": ["revision": "revision-remote", "unreadCount": 2],
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

    /// Advances the pool's clock one second at a time until the factory has
    /// served `target` connections, returning how many seconds that took. Each
    /// pool attempt opens one socket, so the result is the wait the entry served
    /// before that attempt.
    @MainActor
    private static func secondsUntilRequest(
        _ target: Int,
        clock: ManualClock,
        factory: ScriptedGatewaySocketFactory,
        limit: Int
    ) async throws -> Int {
        var elapsed = 0
        while factory.requests.count < target {
            guard elapsed < limit else {
                throw GatewayFailure(
                    code: "timeout", message: "attempt \(target) never arrived",
                    retryable: true, details: nil
                )
            }
            clock.advance(by: .seconds(1))
            elapsed += 1
            for _ in 0..<8 { await Task.yield() }
            try await Task.sleep(for: .milliseconds(1))
        }
        return elapsed
    }

    private static func makeAppLog() -> (AppLog, () -> Void) {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "dashboard-pool-records-\(UUID().uuidString).jsonl")
        let cleanup = {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: url.appendingPathExtension("1"))
        }
        return (AppLog(fileURL: url), cleanup)
    }

    private static func recordCount(_ log: AppLog, event: String) async -> Int {
        await log.snapshot().filter { $0.event == event }.count
    }

    private static func waitForRecords(
        _ log: AppLog, event: String, count: Int
    ) async throws -> [AppLogRecord] {
        for _ in 0..<600 {
            let values = await log.snapshot().filter { $0.event == event }
            if values.count >= count { return values }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("timed out waiting for \(count) \(event) record(s)")
        return await log.snapshot().filter { $0.event == event }
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

    @Test("Automation view and filters persist and reconcile known Gateways")
    func automationPreferencePersistence() {
        let suiteName = "DashboardStateOwnerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var owner = AutomationDashboardPreferencesOwner(defaults: defaults)
        #expect(owner.value == AutomationDashboardViewPreferences())

        var stored = owner.value
        stored.mode = .all
        owner.set(stored)
        #expect(AutomationDashboardPreferencesOwner(defaults: defaults).value == stored)

        stored.inventoryFilter = .paused
        stored.actionFilter = .notification
        stored.selectedProfileID = "profile-one"
        owner.set(stored)

        var restored = AutomationDashboardPreferencesOwner(defaults: defaults).value
        #expect(restored == stored)
        #expect(restored.effectiveProfileID(eligibleProfileIDs: ["profile-one"]) == "profile-one")
        #expect(restored.effectiveProfileID(eligibleProfileIDs: []) == nil)
        restored.reconcile(knownProfileIDs: [])
        #expect(restored.selectedProfileID == "profile-one")
        restored.reconcile(knownProfileIDs: ["profile-two"])
        #expect(restored.selectedProfileID == nil)
    }

    @Test("malformed or oversized Automation preferences fail closed")
    func invalidAutomationPreferences() {
        let suiteName = "DashboardStateOwnerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(
            Data(#"{"version":1,"mode":"All","inventoryFilter":"Paused","actionFilter":"unknown"}"#.utf8),
            forKey: AutomationDashboardPreferences.documentKey
        )
        #expect(AutomationDashboardPreferences.load(from: defaults) == AutomationDashboardViewPreferences())
        defaults.set(
            Data(repeating: 0x41, count: 4 * 1024 + 1),
            forKey: AutomationDashboardPreferences.documentKey
        )
        #expect(AutomationDashboardPreferences.load(from: defaults) == AutomationDashboardViewPreferences())
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
        let firstPublished = owner.publishAuthoritative([summary(revision: 1)], admission: first, projectionToken: "epoch-1:1")
        let secondPublished = owner.publishAuthoritative([summary(revision: 2)], admission: second, projectionToken: "epoch-1:1")
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

    @Test("a retained projection token survives a reconnect and drops on a profile switch")
    func projectionTokenScope() {
        var owner = SessionCatalogCoordinator()
        let load = owner.beginLoad()
        let published = owner.publishAuthoritative(
            [summary(revision: 1)],
            admission: load,
            projectionToken: "gateway-epoch:4:0:user:exclude:0"
        )
        #expect(published)
        #expect(owner.projectionToken == "gateway-epoch:4:0:user:exclude:0")

        // The token carries the Gateway runtime epoch, so a replacement
        // connection can revalidate the held rows instead of reloading them.
        owner.markDisconnected()
        #expect(owner.projectionToken == "gateway-epoch:4:0:user:exclude:0")
        let reconnect = owner.beginLoad(key: SessionCatalogLoadKey(
            profileID: "remote", lifecycleGeneration: 2, connectionID: 9
        ))
        let confirmed = owner.confirmUnchanged(admission: reconnect)
        #expect(confirmed)
        #expect(owner.freshness == .live)
        #expect(owner.sessions.map(\.id) == ["session"])

        // A profile switch retires the projection, so its rows can never be
        // claimed against another Gateway's catalog.
        owner.invalidateLoads()
        #expect(owner.projectionToken == nil)
    }

    @Test("newer live summaries survive an older authoritative catalog page")
    func liveSummaryOverlay() {
        var owner = SessionCatalogCoordinator()
        let first = owner.beginLoad()
        let firstPublished = owner.publishAuthoritative([summary(revision: 1)], admission: first, projectionToken: "epoch-1:1")
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
        let refreshed = owner.publishAuthoritative([summary(revision: 2)], admission: refresh, projectionToken: "epoch-1:1")
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
        let published = owner.publishAuthoritative([summary(revision: 1)], admission: load, projectionToken: "epoch-1:1")
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
        let published = owner.publishAuthoritative([summary(revision: 1)], admission: load, projectionToken: "epoch-1:1")
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

    @Test("pending user interaction has a distinct live dashboard activity")
    func waitingForUserActivity() {
        var owner = SessionCatalogCoordinator()
        let load = owner.beginLoad()
        let published = owner.publishAuthoritative([
            summary(revision: 1, phase: .running, waitingForUser: true),
        ], admission: load, projectionToken: "epoch-1:1")
        #expect(published)
        #expect(owner.activity(for: "session") == .waitingForUser)

        let cleared = owner.apply(update(
            revision: 2,
            phase: .running,
            waitingForUser: false
        ))
        #expect(cleared == .updated)
        #expect(owner.activity(for: "session") == .active)

        let waitingAgain = owner.apply(update(
            revision: 3,
            phase: .running,
            waitingForUser: true
        ))
        #expect(waitingAgain == .updated)
        owner.markDisconnected()
        #expect(owner.activity(for: "session") == .resuming)
    }

    @Test("settled foreground with active subagents has distinct live activity")
    func activeSubagentActivity() {
        var owner = SessionCatalogCoordinator()
        let load = owner.beginLoad()
        let published = owner.publishAuthoritative([
            summary(
                revision: 1,
                phase: .running,
                foregroundPhase: .idle,
                hasActiveSubagents: true
            ),
        ], admission: load, projectionToken: "epoch-1:1")

        #expect(published)
        #expect(owner.activity(for: "session") == .subagentsWorking)

        let foregroundResumed = owner.apply(update(
            revision: 2,
            phase: .running,
            foregroundPhase: .running,
            hasActiveSubagents: true
        ))
        #expect(foregroundResumed == .updated)
        #expect(owner.activity(for: "session") == .active)

        let legacy = owner.apply(update(revision: 3, phase: .running))
        #expect(legacy == .updated)
        #expect(owner.activity(for: "session") == .active)
    }

    @Test("cached and disconnected phases retain provenance without fabricating interruption")
    func catalogFreshnessAndActivity() {
        var owner = SessionCatalogCoordinator()
        let load = owner.beginLoad()
        let published = owner.publishAuthoritative([
            summary(revision: 1, phase: .running),
        ], admission: load, projectionToken: "epoch-1:1")
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
            admission: pendingBeforeDisconnect,
            projectionToken: "epoch-1:1"
        )
        #expect(!disconnectedPublish)

        let pendingBeforeCache = owner.beginLoad()
        owner.installCached([summary(revision: 2, phase: .interrupted)])
        #expect(owner.sessions.first?.phase == .interrupted)
        #expect(owner.freshness == .cached)
        #expect(owner.activity(for: "session") == .resuming)
        let cachedPublish = owner.publishAuthoritative(
            [summary(revision: 3)],
            admission: pendingBeforeCache,
            projectionToken: "epoch-1:1"
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
        let published = owner.publishAuthoritative([summary(revision: 1)], admission: load, projectionToken: "epoch-1:1")
        let updated = owner.apply(update(revision: 2, phase: .running))
        #expect(published)
        #expect(updated == .updated)
        let pendingBeforeRemoval = owner.beginLoad()
        owner.remove("session")
        #expect(owner.sessions.isEmpty)
        let removedPublish = owner.publishAuthoritative(
            [summary(revision: 3)],
            admission: pendingBeforeRemoval,
            projectionToken: "epoch-1:1"
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
            admission: beforeReplacement,
            projectionToken: "epoch-1:1"
        )
        #expect(!replacedPublish)

        let beforeClear = owner.beginLoad()
        owner.clear()
        let clearedPublish = owner.publishAuthoritative(
            [summary(revision: 3)],
            admission: beforeClear,
            projectionToken: "epoch-1:1"
        )
        #expect(!clearedPublish)
        #expect(owner.sessions.isEmpty)
        #expect(owner.hasConsistentIndex())
    }

    @Test("catalog index stays exact across publication, update, removal, replacement, and clear")
    func catalogIndexIntegrity() {
        var owner = SessionCatalogCoordinator()
        let load = owner.beginLoad()
        let published = owner.publishAuthoritative([summary(revision: 1)], admission: load, projectionToken: "epoch-1:1")
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

    @Test("an archived row leaves the dashboard and only a page can return it")
    func archivedRowsLeaveUntilAPageReturnsThem() {
        var owner = SessionCatalogCoordinator()
        let load = owner.beginLoad()
        let published = owner.publishAuthoritative([summary(revision: 1)], admission: load, projectionToken: "epoch-1:1", archivedCount: 1)
        #expect(published)
        #expect(owner.archivedCount == 1)

        owner.markArchived(sessionID: "session")
        #expect(owner.sessions.isEmpty)
        // The Gateway's summary projection carries no archive field, so a late
        // update for the ID cannot re-materialize the row. The caller turns the
        // admission into a list read instead.
        let lateUpdate = owner.apply(update(revision: 2, phase: .idle))
        #expect(lateUpdate == .unknownSession)
        #expect(owner.sessions.isEmpty)

        // Only an authoritative exclude page proves the row is visible again.
        let refreshed = owner.beginLoad()
        let republished = owner.publishAuthoritative([summary(revision: 3)], admission: refreshed, projectionToken: "epoch-1:1", archivedCount: 0)
        #expect(republished)
        #expect(owner.sessions.map(\.id) == ["session"])
        let visibleUpdate = owner.apply(update(revision: 4, phase: .idle))
        #expect(visibleUpdate == .updated)
        #expect(owner.archivedCount == 0)
        #expect(owner.hasConsistentIndex())
    }

    @Test("the archived count survives an unavailable list and is restored from the cache")
    func archivedCountRetention() {
        var owner = SessionCatalogCoordinator()
        let load = owner.beginLoad()
        let published = owner.publishAuthoritative([], admission: load, projectionToken: "epoch-1:1", archivedCount: 3)
        #expect(published)
        #expect(owner.archivedCount == 3)

        // A failed list read must not make the count look unknown.
        owner.markLoadUnavailable()
        #expect(owner.freshness == .stale)
        #expect(owner.archivedCount == 3)

        owner.installCached([summary(revision: 1)], archivedCount: 2)
        #expect(owner.archivedCount == 2)
    }

    @Test("archive counts sum only across capable profiles and never fabricate zero")
    func archiveCountProjection() {
        #expect(SessionArchiveCountProjection.total(countsByProfile: [:], capableProfileIDs: []) == nil)
        // A capable profile whose count is not known yet is unknown, not zero.
        #expect(SessionArchiveCountProjection.total(countsByProfile: [:], capableProfileIDs: ["a"]) == nil)
        #expect(SessionArchiveCountProjection.total(countsByProfile: ["a": 2, "b": 3], capableProfileIDs: ["a", "b"]) == 5)
        // An incapable or offline profile contributes nothing even when a value
        // is still around for it.
        #expect(SessionArchiveCountProjection.total(countsByProfile: ["a": 2, "b": 3], capableProfileIDs: ["a"]) == 2)
        #expect(SessionArchiveCountProjection.total(countsByProfile: ["a": 2, "c": 4], capableProfileIDs: ["a"]) == 2)
        // A published zero is a real contribution, distinct from unknown.
        #expect(SessionArchiveCountProjection.total(countsByProfile: ["a": 0], capableProfileIDs: ["a"]) == 0)
        #expect(SessionArchiveCountProjection.total(countsByProfile: ["a": -1], capableProfileIDs: ["a"]) == nil)
    }

    @MainActor
    @Test("archived page admission rejects foreign rows and repeated cursors")
    func archivedPageAdmission() async {
        func response(_ sessions: [SessionSummary], nextCursor: String?) -> ArchivedSessionsLoader.PageResponse {
            // Decoding through the wire shape keeps the admission checked
            // against what the Gateway actually sends.
            let rawSessions = try! JSONSerialization.jsonObject(with: JSONEncoder.gateway.encode(sessions))
            var result: [String: Any] = ["sessions": rawSessions]
            if let nextCursor { result["nextCursor"] = nextCursor }
            let data = try! JSONSerialization.data(withJSONObject: result)
            return try! JSONDecoder.gateway.decode(ArchivedSessionsLoader.PageResponse.self, from: data)
        }
        let archived = summary(revision: 1, archivedAt: "2026-01-02T00:00:00Z")

        let admitted = await ArchivedSessionsLoader.admit(
            response([archived], nextCursor: "next"),
            requestedCursor: nil,
            admitsPublication: { true }
        )
        guard case let .loaded(page) = admitted else {
            Issue.record("an archived page was not admitted")
            return
        }
        #expect(page.sessions.map(\.id) == ["session"])
        #expect(page.sessions.first?.archivedAt == archived.archivedAt)
        #expect(page.nextCursor == "next")

        // A row without archive state cannot come from the `only` projection.
        let foreign = await ArchivedSessionsLoader.admit(
            response([summary(revision: 1)], nextCursor: nil),
            requestedCursor: nil,
            admitsPublication: { true }
        )
        guard case .invalid(_, let foreignReason) = foreign else {
            Issue.record("a non-archived row in the archived projection was admitted")
            return
        }
        #expect(foreignReason == "archived-session-page")

        let repeated = await ArchivedSessionsLoader.admit(
            response([archived], nextCursor: "cursor"),
            requestedCursor: "cursor",
            admitsPublication: { true }
        )
        guard case .invalid(_, let repeatedReason) = repeated else {
            Issue.record("a repeated cursor was admitted")
            return
        }
        #expect(repeatedReason == "repeated-cursor")

        // The caller's managed activity is rechecked after the read, so a
        // retired surface publishes nothing rather than a stale page.
        let retired = await ArchivedSessionsLoader.admit(
            response([archived], nextCursor: nil),
            requestedCursor: nil,
            admitsPublication: { false }
        )
        guard case .retired = retired else {
            Issue.record("a page was published for an inactive surface")
            return
        }
    }

    @MainActor
    @Test("a background page that leaks an archived row is rejected and its count is not published")
    func backgroundCatalogRejectsArchivedRow() async throws {
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
            await socket.enqueue(Data(#"{"type":"hello","gatewayVersion":"1","piVersion":"1","protocolVersion":6,"minProtocolVersion":6,"machineId":"remote-runtime","machineGroupID":"remote-machine","machineName":"Remote","gatewayChannel":"stable","capabilities":["session-archive.v1"]}"#.utf8))
            pool.reconcile(
                profiles: [selected, remote],
                selectedProfileID: selected.id,
                token: { $0.id == remote.id ? "token" : nil }
            )

            try await socket.waitUntilSent(count: 2)
            let leaked = try Self.requestFrame(await socket.sentFrames()[1])
            #expect(leaked.method == "session.list")
            // `exclude` hides archived sessions. A leaked row would put a hidden
            // session on the dashboard, so the whole traversal is discarded and
            // its count is never published.
            await socket.enqueue(Self.catalogResponse(
                id: leaked.id,
                sessions: [summary(revision: 1, archivedAt: "2026-01-02T00:00:00Z")],
                listRevision: 1,
                archivedCount: 1
            ))
            try await Task.sleep(for: .milliseconds(50))
            #expect((await socket.sentFrames()).count == 2)
            #expect(recorder.updates.allSatisfy { $0.sessions.isEmpty })
            // The rejected page's count never reaches the dashboard, and every
            // count the pool did publish is for the owning profile only.
            #expect(recorder.archivedCounts.count >= 2)
            #expect(recorder.archivedCounts.allSatisfy { $0.count == nil })
            #expect(recorder.archivedCounts.allSatisfy { $0.profileID == remote.id })

            await socket.enqueue(Self.listChangedEvent())
            try await socket.waitUntilSent(count: 3)
            let retried = try Self.requestFrame(await socket.sentFrames()[2])
            #expect(retried.method == "session.list")
            await socket.enqueue(Self.catalogResponse(
                id: retried.id,
                sessions: [summary(revision: 1)],
                listRevision: 2,
                archivedCount: 5
            ))
            try await Self.waitUntil { recorder.archivedCounts.last?.count == 5 }
            #expect(recorder.updates.last?.sessions.map(\.id) == ["session"])
            #expect(recorder.archivedCounts.last?.profileID == remote.id)
            #expect(!recorder.archivedCounts.contains { $0.count == 1 })

            // Rows can change while the archived count does not (one session
            // archived as another is unarchived, or a renamed archived
            // session). The container reads its rows from this page, not from
            // the count, so the page's own publication must be reported.
            let publicationsBefore = recorder.authoritativeCatalogPublications.count
            await socket.enqueue(Self.listChangedEvent())
            try await socket.waitUntilSent(count: 4)
            let republished = try Self.requestFrame(await socket.sentFrames()[3])
            #expect(republished.method == "session.list")
            await socket.enqueue(Self.catalogResponse(
                id: republished.id,
                sessions: [summary(revision: 1), summary(revision: 1, id: "second")],
                listRevision: 3,
                archivedCount: 5
            ))
            try await Self.waitUntil { recorder.updates.last?.sessions.count == 2 }
            // The count is unchanged, so only the page's own publication can
            // tell the container its rows moved.
            #expect(recorder.archivedCounts.last?.count == 5)
            #expect(recorder.authoritativeCatalogPublications.count > publicationsBefore)

            pool.retire()
            await pool.waitForRetirement()
        }
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
        let presentationRevision = model.dashboardPresentationRevision
        model.sessions = [summary(revision: 1)]
        #expect(changed.withLock { $0 })
        #expect(model.sessions.first?.id == "session")
        #expect(model.dashboardPresentationRevision > presentationRevision)
    }

    // MARK: Archived container

    @MainActor
    @Test("archived container publishes only current, admitted pages")
    func archivedContainerPublication() {
        var container = ArchivedSessionsContainerState()
        #expect(!container.isExpanded)
        container.expand()
        let generation = container.currentGeneration

        // A page from a superseded pass cannot reappear after a collapse.
        let collapsed = container.collapse()
        #expect(collapsed != generation)
        let stale = ArchivedSessionsPage(sessions: [archivedSummary(profileID: "a", archivedAt: "2026-01-02T00:00:00Z")], nextCursor: nil)
        let staleApplied = container.apply(
            .loaded(page: stale),
            profileID: "a",
            generation: generation,
            requestedCursor: nil
        )
        #expect(!staleApplied)
        #expect(container.rows.isEmpty)
        #expect(!container.isExpanded)

        // A retired read publishes nothing and is not presented as an
        // unavailable server.
        let current = container.collapse()
        container.expand()
        let retiredApplied = container.apply(
            .retired,
            profileID: "a",
            generation: current,
            requestedCursor: nil
        )
        #expect(!retiredApplied)
        #expect(container.rows.isEmpty)
        #expect(container.unavailableProfileIDs.isEmpty)

        // A malformed page is named as unavailable instead of publishing rows.
        let invalidApplied = container.apply(
            .invalid(code: "invalid_response", reason: "archived-session-page"),
            profileID: "a",
            generation: current,
            requestedCursor: nil
        )
        #expect(!invalidApplied)
        #expect(container.rows.isEmpty)
        #expect(container.unavailableProfileIDs == ["a"])

        // An admitted first page replaces the server's rows and clears its note.
        let page = ArchivedSessionsPage(
            sessions: [archivedSummary(profileID: "a", archivedAt: "2026-01-02T00:00:00Z")],
            nextCursor: "next"
        )
        let applied = container.apply(
            .loaded(page: page),
            profileID: "a",
            generation: current,
            requestedCursor: nil
        )
        #expect(applied)
        #expect(container.rows.map(\.id) == ["session"])
        #expect(container.hasMore)
        #expect(container.unavailableProfileIDs.isEmpty)

        // A continuation page extends the server's rows: "Show more" must not
        // discard the pages the user already saw.
        let continuation = ArchivedSessionsPage(
            sessions: [
                archivedSummary(profileID: "a", archivedAt: "2026-01-01T00:00:00Z"),
                archivedSummary(profileID: "a", id: "second", archivedAt: "2026-01-03T00:00:00Z"),
            ],
            nextCursor: nil
        )
        let extended = container.apply(
            .loaded(page: continuation),
            profileID: "a",
            generation: current,
            requestedCursor: "next"
        )
        #expect(extended)
        #expect(container.rows.map(\.id) == ["second", "session"])
        #expect(!container.hasMore)

        // A fresh first page is still the whole authority for the server.
        let refreshed = container.apply(
            .loaded(page: ArchivedSessionsPage(
                sessions: [archivedSummary(profileID: "a", id: "second", archivedAt: "2026-01-03T00:00:00Z")],
                nextCursor: nil
            )),
            profileID: "a",
            generation: current,
            requestedCursor: nil
        )
        #expect(refreshed)
        #expect(container.rows.map(\.id) == ["second"])
    }

    @MainActor
    @Test("a reload retires an in-flight pass instead of letting its page win")
    func archivedContainerReloadRetiresInFlightPass() {
        var container = ArchivedSessionsContainerState()
        container.expand()
        let inFlight = container.currentGeneration
        // A pass is in flight when a newer archive authority lands. Retiring it
        // must move the generation, because cancellation is cooperative.
        let fresh = container.retirePages()
        #expect(fresh != inFlight)
        #expect(!container.isCurrent(inFlight))

        // The retired pass's page is refused even though the container stays
        // expanded and holds no fabricated rows.
        let late = ArchivedSessionsPage(
            sessions: [archivedSummary(profileID: "a", archivedAt: "2026-01-02T00:00:00Z")],
            nextCursor: "next"
        )
        let lateApplied = container.apply(
            .loaded(page: late),
            profileID: "a",
            generation: inFlight,
            requestedCursor: nil
        )
        #expect(!lateApplied)
        #expect(container.rows.isEmpty)
        #expect(!container.hasMore)

        // The fresh pass publishes under the generation retirement installed.
        let freshApplied = container.apply(
            .loaded(page: late),
            profileID: "a",
            generation: fresh,
            requestedCursor: nil
        )
        #expect(freshApplied)
        #expect(container.rows.map(\.id) == ["session"])
    }

    @MainActor
    @Test("a refused continuation drops its cursor so the server restarts from its first page")
    func archivedContainerRestartsAfterRefusedCursor() {
        var container = ArchivedSessionsContainerState()
        let source = ArchivedSessionsProfileSource(profileID: "a", label: "A", isConnected: true)
        container.expand()
        let generation = container.currentGeneration
        _ = container.apply(
            .loaded(page: ArchivedSessionsPage(
                sessions: [archivedSummary(profileID: "a", archivedAt: "2026-01-02T00:00:00Z")],
                nextCursor: "next"
            )),
            profileID: "a",
            generation: generation,
            requestedCursor: nil
        )
        #expect(container.hasMore)

        // The Gateway refused the cursor, so retrying that exact continuation
        // could only fail again. Dropping it is what lets the caller re-read a
        // first page instead of offering a control that always fails.
        let dropped = container.discardCursor("a")
        #expect(dropped)
        #expect(!container.hasMore)
        let droppedAgain = container.discardCursor("a")
        #expect(!droppedAgain)
        #expect(container.pageRequests(for: [source], more: true).isEmpty)
        #expect(container.pageRequests(for: [source], more: false).first?.cursor == nil)
        // Rows the user already saw stay until the fresh first page replaces
        // them: a refusal is not evidence that the server is unreadable.
        #expect(container.rows.map(\.id) == ["session"])
        #expect(container.unavailableProfileIDs.isEmpty)
    }

    @MainActor
    @Test("a zero archive count closes the container and retires its pages")
    func archivedContainerClosesAtZero() {
        var container = ArchivedSessionsContainerState()
        container.expand()
        let generation = container.currentGeneration
        _ = container.apply(
            .loaded(page: ArchivedSessionsPage(
                sessions: [archivedSummary(profileID: "a", archivedAt: "2026-01-02T00:00:00Z")],
                nextCursor: "next"
            )),
            profileID: "a",
            generation: generation,
            requestedCursor: nil
        )
        #expect(container.rows.count == 1)

        // An unknown count is not zero: the container keeps what it has.
        let unknown = container.reconcileCount(nil)
        #expect(!unknown)
        #expect(container.isExpanded)
        let stillArchived = container.reconcileCount(2)
        #expect(!stillArchived)
        #expect(container.isExpanded)

        // Zero means no archived session exists on any capable server.
        let closed = container.reconcileCount(0)
        #expect(closed)
        #expect(!container.isExpanded)
        #expect(container.rows.isEmpty)
        #expect(!container.hasMore)
        #expect(container.currentGeneration != generation)
    }

    @MainActor
    @Test("archived container reads only capable connected servers")
    func archivedContainerReconciliation() {
        var container = ArchivedSessionsContainerState()
        let capable = ArchivedSessionsProfileSource(profileID: "a", label: "A", isConnected: true)
        let offline = ArchivedSessionsProfileSource(profileID: "b", label: "B", isConnected: false)
        container.expand()
        let generation = container.currentGeneration
        container.reconcile([capable, offline])
        #expect(container.unavailableProfileIDs == ["b"])
        let page = ArchivedSessionsPage(
            sessions: [archivedSummary(profileID: "a", archivedAt: "2026-01-02T00:00:00Z")],
            nextCursor: "next"
        )
        _ = container.apply(.loaded(page: page), profileID: "a", generation: generation, requestedCursor: nil)

        // The first pass reads every connected server and never a disconnected
        // one.
        let firstPages = container.pageRequests(for: [capable, offline], more: false)
        #expect(firstPages.count == 1)
        #expect(firstPages.first?.profileID == "a")
        #expect(firstPages.first?.cursor == nil)
        // "Show more" reads exactly the servers with an unpublished page.
        let morePages = container.pageRequests(for: [capable, offline], more: true)
        #expect(morePages.count == 1)
        #expect(morePages.first?.cursor == "next")

        // A server that stops being connected (or capable) loses its rows and
        // cursors: a page read is their only authority.
        container.reconcile([offline])
        #expect(container.rows.isEmpty)
        #expect(!container.hasMore)
        #expect(container.pageRequests(for: [offline], more: false).isEmpty)
        container.reconcile([])
        #expect(container.unavailableProfileIDs.isEmpty)
    }

    @MainActor
    @Test("archived rows keep server identity through ordering")
    func archivedRowIdentityAndOrder() {
        var container = ArchivedSessionsContainerState()
        let source = ArchivedSessionsProfileSource(profileID: "a", label: "A", isConnected: true)
        let second = ArchivedSessionsProfileSource(profileID: "b", label: "B", isConnected: true)
        container.expand()
        let generation = container.currentGeneration
        container.reconcile([source, second])
        let older = archivedSummary(profileID: "a", archivedAt: "2026-01-01T00:00:00Z")
        let newer = archivedSummary(profileID: "b", archivedAt: "2026-01-03T00:00:00Z")
        _ = container.apply(
            .loaded(page: ArchivedSessionsPage(sessions: [older], nextCursor: nil)),
            profileID: "a",
            generation: generation,
            requestedCursor: nil
        )
        _ = container.apply(
            .loaded(page: ArchivedSessionsPage(sessions: [newer], nextCursor: nil)),
            profileID: "b",
            generation: generation,
            requestedCursor: nil
        )

        // Newest archived first, qualification-safe when two servers own equal
        // session IDs.
        #expect(container.rows.map(\.dashboardID) == [newer.dashboardID, older.dashboardID])
    }

    private func archivedSummary(profileID: String, id: String = "session", archivedAt: String) -> SessionSummary {
        summary(revision: 1, id: id, archivedAt: archivedAt)
            .withGatewaySource(id: profileID, label: profileID.uppercased())
    }

    private func summary(
        revision: Int,
        id: String = "session",
        phase: SessionPhase = .idle,
        foregroundPhase: SessionPhase? = nil,
        hasActiveSubagents: Bool = false,
        waitingForUser: Bool = false,
        archivedAt: String? = nil
    ) -> SessionSummary {
        SessionSummary(
            id: id,
            name: "Session",
            cwd: "/workspace",
            parentSessionId: nil,
            createdAt: "2026-01-01T00:00:00Z",
            updatedAt: "2026-01-01T00:00:00Z",
            messageCount: 1,
            firstMessage: "Hello",
            phase: phase,
            foregroundPhase: foregroundPhase,
            hasActiveSubagents: hasActiveSubagents,
            waitingForUser: waitingForUser,
            summaryRevision: revision,
            archivedAt: archivedAt
        )
    }

    private func update(
        revision: Int,
        phase: SessionPhase,
        foregroundPhase: SessionPhase? = nil,
        hasActiveSubagents: Bool = false,
        waitingForUser: Bool = false,
        activeSince: String? = nil,
        completionRevision: Int = 0,
        isUnread: Bool = false
    ) -> SessionSummaryUpdate {
        SessionSummaryUpdate(
            sessionId: "session",
            summaryRevision: revision,
            phase: phase,
            foregroundPhase: foregroundPhase,
            hasActiveSubagents: hasActiveSubagents,
            waitingForUser: waitingForUser,
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
    struct Update: Sendable {
        let profileID: String
        let sessions: [SessionSummary]
        let state: DashboardServerConnectionState
    }

    private let changes = AsyncStream<Update>.makeStream(bufferingPolicy: .bufferingNewest(1))
    private(set) var updates: [Update] = []

    func waitForState(_ state: DashboardServerConnectionState, profileID: String) async throws {
        if updates.last?.profileID == profileID, updates.last?.state == state { return }
        try await withTestWatchdog { @MainActor in
            for await update in self.changes.stream {
                if update.profileID == profileID, update.state == state { return }
            }
            throw CancellationError()
        }
    }
    private(set) var notificationInvalidations: [String] = []
    private(set) var archivedCounts: [ArchivedCount] = []
    private(set) var authoritativeCatalogPublications: [String] = []

    struct ArchivedCount: Sendable {
        let profileID: String
        let count: Int?
    }

    func dashboardPoolNotificationInboxChanged(profileID: String, change: NotificationInboxChanged?) {
        notificationInvalidations.append(profileID)
    }

    func dashboardPoolDidPublishAuthoritativeCatalog(profileID: String) {
        authoritativeCatalogPublications.append(profileID)
    }

    func dashboardPoolDidUpdateArchivedCount(profileID: String, count: Int?) {
        archivedCounts.append(ArchivedCount(profileID: profileID, count: count))
    }

    func dashboardPoolDidUpdate(
        profileID: String,
        sessions: [SessionSummary],
        state: DashboardServerConnectionState
    ) {
        let update = Update(profileID: profileID, sessions: sessions, state: state)
        updates.append(update)
        changes.continuation.yield(update)
    }
}
