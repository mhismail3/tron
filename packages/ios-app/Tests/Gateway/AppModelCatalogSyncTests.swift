import Foundation
import Testing
@testable import TronMobile

@MainActor
@Suite("Dashboard catalog synchronization", .serialized)
struct AppModelCatalogSyncTests {
    @Test("known summary overlays synchronously without scheduling a catalog reload")
    func knownSummaryNeedsNoReload() async throws {
        try await withHarness { harness in
            harness.model.sessions = [summary(id: "known", revision: 0)]
            await harness.model.handle(summaryEvent(id: "known", revision: 1, phase: .running))

            #expect(harness.model.sessions.first?.phase == .running)
            #expect(harness.model.dashboardActivity(for: "known") == .active)
            #expect(await harness.socket.sentFrames().count == 1)
            #expect(harness.model.latestNotice == nil)
            #expect(harness.model.lastError == nil)
        }
    }

    @Test("unknown summary triggers immediate user-scoped discovery and preserves its newer overlay")
    func unknownSummaryDiscovery() async throws {
        try await withHarness { harness in
            await harness.model.handle(summaryEvent(id: "new", revision: 2, phase: .running))
            let request = try await request(harness.socket, index: 1)
            #expect(request.method == "session.list")
            #expect(request.params?["scope"] == .string("user"))
            #expect(request.params?["limit"] == .number(500))
            async let completion = harness.model.refreshSessions()
            await harness.socket.enqueue(response(
                id: request.id,
                sessions: [summary(id: "new", revision: 1)],
                listRevision: 7
            ))
            #expect(await completion == .published)

            #expect(harness.model.sessions.first?.phase == .running)
            #expect(harness.model.sessions.first?.summaryRevision == 2)
            #expect(harness.model.latestNotice == nil)
            #expect(harness.model.lastError == nil)
        }
    }

    @Test("concurrent callers share one traversal and a dirty event receives one follow-up traversal")
    func singleFlightDirtyFollowUp() async throws {
        try await withHarness { harness in
            let firstCaller = Task { await harness.model.refreshSessions() }
            let secondCaller = Task { await harness.model.refreshSessions() }
            let first = try await request(harness.socket, index: 1)
            #expect(await harness.socket.sentFrames().count == 2)

            await harness.model.handle(GatewayEvent(
                type: "event",
                topic: "session.listChanged",
                sessionId: nil,
                payload: .object(["listRevision": .number(2)])
            ))
            #expect(await harness.socket.sentFrames().count == 2)
            await harness.socket.enqueue(response(
                id: first.id,
                sessions: [summary(id: "first", revision: 1)],
                listRevision: 1
            ))

            let followUp = try await request(harness.socket, index: 2)
            await harness.socket.enqueue(response(
                id: followUp.id,
                sessions: [summary(id: "second", revision: 1)],
                listRevision: 2
            ))

            #expect(await firstCaller.value == .published)
            #expect(await secondCaller.value == .published)
            #expect(harness.model.sessions.map(\.id) == ["second"])
            #expect(await harness.socket.sentFrames().count == 3)
            #expect(harness.model.latestNotice == nil)
            #expect(harness.model.lastError == nil)
        }
    }

    @Test("mixed list revisions restart once without partial publication or a user notice")
    func mixedRevisionRetriesSilently() async throws {
        try await withHarness { harness in
            harness.model.sessions = [summary(id: "retained", revision: 1)]
            let loading = Task { await harness.model.refreshSessions() }
            let first = try await request(harness.socket, index: 1)
            await harness.socket.enqueue(response(
                id: first.id,
                sessions: [summary(id: "partial-a", revision: 1)],
                listRevision: 10,
                nextCursor: "cursor-a"
            ))
            let second = try await request(harness.socket, index: 2)
            await harness.socket.enqueue(response(
                id: second.id,
                sessions: [summary(id: "partial-b", revision: 1)],
                listRevision: 11
            ))
            let retry = try await request(harness.socket, index: 3)
            #expect(retry.params?["cursor"] == nil)
            #expect(harness.model.sessions.map(\.id) == ["retained"])
            await harness.socket.enqueue(response(
                id: retry.id,
                sessions: [summary(id: "authoritative", revision: 1)],
                listRevision: 12
            ))

            #expect(await loading.value == .published)
            #expect(harness.model.sessions.map(\.id) == ["authoritative"])
            #expect(harness.model.latestNotice == nil)
            #expect(harness.model.lastError == nil)
        }
    }

    @Test("an expired continuation cursor restarts once from the first page without a notice")
    func expiredCursorRetriesSilently() async throws {
        try await withHarness { harness in
            harness.model.sessions = [summary(id: "retained", revision: 1)]
            let loading = Task { await harness.model.refreshSessions() }
            let first = try await request(harness.socket, index: 1)
            await harness.socket.enqueue(response(
                id: first.id,
                sessions: [summary(id: "partial", revision: 1)],
                listRevision: 10,
                nextCursor: "expired-cursor"
            ))
            let continuation = try await request(harness.socket, index: 2)
            await harness.socket.enqueue(errorResponse(id: continuation.id, code: "invalid_request"))
            let retry = try await request(harness.socket, index: 3)
            #expect(retry.params?["cursor"] == nil)
            await harness.socket.enqueue(response(
                id: retry.id,
                sessions: [summary(id: "authoritative", revision: 2)],
                listRevision: 11
            ))

            #expect(await loading.value == .published)
            #expect(harness.model.sessions.map(\.id) == ["authoritative"])
            #expect(harness.model.latestNotice == nil)
            #expect(harness.model.lastError == nil)
        }
    }

    @Test("catalog traversal rejects oversized pages and duplicate identities without publication")
    func traversalBounds() async throws {
        try await withHarness { harness in
            harness.model.sessions = [summary(id: "retained", revision: 1)]
            let oversizedLoad = Task { await harness.model.refreshSessions() }
            let oversizedRequest = try await request(harness.socket, index: 1)
            await harness.socket.enqueue(response(
                id: oversizedRequest.id,
                sessions: (0...500).map { summary(id: "oversized-\($0)", revision: 1) },
                listRevision: 1
            ))
            #expect(await oversizedLoad.value == .retained)
            #expect(harness.model.sessions.map(\.id) == ["retained"])

            let duplicateLoad = Task { await harness.model.refreshSessions() }
            let duplicateRequest = try await request(harness.socket, index: 2)
            await harness.socket.enqueue(response(
                id: duplicateRequest.id,
                sessions: [summary(id: "duplicate", revision: 1), summary(id: "duplicate", revision: 1)],
                listRevision: 2
            ))
            #expect(await duplicateLoad.value == .retained)
            #expect(harness.model.sessions.map(\.id) == ["retained"])
            #expect(harness.model.latestNotice == nil)
            #expect(harness.model.lastError == nil)
        }
    }

    @Test("catalog errors distinguish retained state from transport failure without alerts")
    func typedFailureOutcomes() async throws {
        try await withHarness { harness in
            let retained = Task { await harness.model.refreshSessions() }
            let invalid = try await request(harness.socket, index: 1)
            await harness.socket.enqueue(errorResponse(id: invalid.id, code: "invalid_request"))
            #expect(await retained.value == .retained)

            let transport = Task { await harness.model.refreshSessions() }
            let disconnected = try await request(harness.socket, index: 2)
            await harness.socket.enqueue(errorResponse(id: disconnected.id, code: "disconnected"))
            #expect(await transport.value == .transportFailure)
            #expect(harness.model.latestNotice == nil)
            #expect(harness.model.lastError == nil)
        }
    }

    @Test("background retirement closes the socket and foreground owns one fresh catalog pass")
    func backgroundForegroundConvergesOnOneSocket() async throws {
        try await withHarness(sockets: [ScriptedGatewaySocket(), ScriptedGatewaySocket()]) { harness in
            let backgrounded = harness.model.becameActive()
            let stale = try await request(harness.socket, index: 1)
            #expect(stale.method == "session.list")

            harness.model.enteredBackground()
            await backgrounded?.value
            #expect(await harness.socket.closed())
            await harness.model.handle(GatewayEvent(
                type: "event",
                topic: "session.listChanged",
                sessionId: nil,
                payload: .object(["listRevision": .number(2)])
            ))
            #expect(await harness.socket.sentFrames().count == 2)

            let foreground = harness.model.becameActive()
            let replacement = try #require(harness.sockets.dropFirst().first)
            await replacement.enqueue(helloFrame())
            let current = try await request(replacement, index: 0)
            #expect(current.method == "session.list")
            await replacement.enqueue(response(
                id: current.id,
                sessions: [summary(id: "foreground", revision: 1, phase: .running)],
                listRevision: 2
            ))
            await foreground?.value

            #expect(harness.model.sessions.map(\.id) == ["foreground"])
            #expect(harness.model.dashboardActivity(for: "foreground") == .active)
            #expect(harness.model.connectionState == .connected)
            #expect(harness.model.latestNotice == nil)
            #expect(harness.model.lastError == nil)
        }
    }

    @Test("foreground catalog transport failure does not replace a responsive socket")
    func responsiveSocketSurvivesCatalogFailure() async throws {
        let socket = ScriptedGatewaySocket()
        let replacement = ScriptedGatewaySocket()
        let factory = ScriptedGatewaySocketFactory(sockets: [socket, replacement])
        let client = GatewayClient(socketFactory: factory.factory)
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let model = AppModel(client: client, cache: SnapshotCache(root: root))
        let profile = GatewayProfile(
            id: "profile", label: "Mac", host: "gateway.test", port: 9_847,
            machineId: "machine", deviceId: "device"
        )
        await socket.enqueue(helloFrame())
        try await model.connectHostedGateway(profile: profile, token: "token")
        defer { try? FileManager.default.removeItem(at: root) }

        let reconciliation = model.becameActive()
        let catalog = try await request(socket, index: 1)
        #expect(catalog.method == "session.list")
        await socket.enqueue(errorResponse(id: catalog.id, code: "disconnected"))
        await reconciliation?.value

        #expect(model.connectionState == .connected)
        #expect(factory.requests.count == 1)
        #expect(model.latestNotice == nil)
        #expect(model.lastError == nil)
        await model.teardown()
        await client.close()
    }

    private func withHarness(
        sockets: [ScriptedGatewaySocket] = [ScriptedGatewaySocket()],
        operation: @escaping @MainActor @Sendable (Harness) async throws -> Void
    ) async throws {
        let socket = try #require(sockets.first)
        let client = GatewayClient(socketFactory: ScriptedGatewaySocketFactory(sockets: sockets).factory)
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let model = AppModel(client: client, cache: SnapshotCache(root: root))
        let profile = GatewayProfile(
            id: "profile", label: "Mac", host: "gateway.test", port: 9_847,
            machineId: "machine", deviceId: "device"
        )
        await socket.enqueue(helloFrame())
        try await model.connectHostedGateway(profile: profile, token: "token")
        let harness = Harness(socket: socket, sockets: sockets, client: client, model: model, root: root)
        do {
            try await withTestWatchdog {
                try await operation(harness)
            }
        } catch {
            await harness.cleanup()
            throw error
        }
        await harness.cleanup()
    }

    private func request(_ socket: ScriptedGatewaySocket, index: Int) async throws -> Request {
        try await socket.waitUntilSent(count: index + 1)
        return try JSONDecoder.gateway.decode(Request.self, from: await socket.sentFrames()[index])
    }

    private func summary(
        id: String,
        revision: Int,
        phase: SessionPhase = .idle
    ) -> SessionSummary {
        SessionSummary(
            id: id, name: id, cwd: "/workspace", parentSessionId: nil,
            createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:01Z",
            messageCount: revision, firstMessage: id, phase: phase, summaryRevision: revision
        )
    }

    private func summaryEvent(id: String, revision: Int, phase: SessionPhase) -> GatewayEvent {
        GatewayEvent(
            type: "event", topic: "session.summary", sessionId: nil,
            payload: .object([
                "sessionId": .string(id),
                "summaryRevision": .number(Double(revision)),
                "phase": .string(phase.rawValue),
                "name": .string(id),
                "updatedAt": .string("2026-01-01T00:00:02Z"),
                "messageCount": .number(Double(revision)),
                "firstMessage": .string(id),
            ])
        )
    }

    private func response(
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

    private func errorResponse(id: String, code: String) -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "type": "response", "id": id, "ok": false,
            "error": ["code": code, "message": "synthetic \(code)", "retryable": true],
        ])
    }

    private func helloFrame() -> Data {
        Data(#"{"type":"hello","gatewayVersion":"1.0.0","piVersion":"1.0.0","protocolVersion":3,"minProtocolVersion":3,"machineId":"machine","machineName":"Mac","capabilities":["sessions.v1"]}"#.utf8)
    }

    private struct Request: Decodable {
        let id: String
        let method: String
        let params: [String: JSONValue]?
    }

    private struct Harness {
        let socket: ScriptedGatewaySocket
        let sockets: [ScriptedGatewaySocket]
        let client: GatewayClient
        let model: AppModel
        let root: URL

        func cleanup() async {
            await model.teardown()
            await client.close()
            try? FileManager.default.removeItem(at: root)
        }
    }
}
