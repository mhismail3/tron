import Foundation
import Testing
@testable import TronMobile

@MainActor
@Suite("AppModel performance boundaries")
struct AppModelPerformanceSignpostTests {
    @Test("presentation open and authoritative resync close distinct intervals")
    func sessionOpenAndResync() async throws {
        try await withTestWatchdog {
            let harness = try await makeHarness()
            let snapshot = try SessionScenarioBuilder(seed: 41).openingTail(targetEncodedBytes: 8_192)
            let openResponder = Task {
                try await respondToSessionSynchronization(
                    socket: harness.socket,
                    firstFrameIndex: 1,
                    snapshot: snapshot
                )
                try await respondToPresentationRefreshes(socket: harness.socket, firstFrameIndex: 3)
            }
            defer { openResponder.cancel() }

            _ = try await harness.model.openSessionPresentation(snapshot.sessionId)
            try await valueOfOwnedTask(openResponder)
            #expect(harness.signposts.events() == [
                .begin(.sessionOpen),
                .begin(.sessionSync),
                .end(.sessionSync, .success, .none),
                .end(.sessionOpen, .success, .none),
            ])

            harness.signposts.reset()
            let resyncResponder = Task {
                try await respondToSessionSynchronization(
                    socket: harness.socket,
                    firstFrameIndex: 6,
                    snapshot: snapshot
                )
                try await respondToSessionSynchronization(
                    socket: harness.socket,
                    firstFrameIndex: 8,
                    snapshot: snapshot
                )
            }
            defer { resyncResponder.cancel() }
            await harness.model.handle(GatewayEvent(
                type: "event",
                topic: "transport.resyncRequired",
                sessionId: snapshot.sessionId,
                payload: .object([:])
            ))
            try await valueOfOwnedTask(resyncResponder)
            #expect(harness.signposts.events() == [
                .begin(.sessionResync),
                .begin(.sessionResync),
                .end(.sessionResync, .success, .none),
                .end(.sessionResync, .discarded, .none),
            ])
            await harness.client.close()
        }
    }

    @Test("cancelled presentation closes both open and sync intervals")
    func cancelledSessionOpen() async throws {
        try await withTestWatchdog {
            let harness = try await makeHarness()
            let opening = Task {
                try await harness.model.openSessionPresentation("session")
            }
            defer { opening.cancel() }
            try await harness.socket.waitUntilSent(count: 2)
            opening.cancel()
            do {
                _ = try await valueOfOwnedTask(opening)
                Issue.record("cancelled presentation unexpectedly opened")
            } catch {}
            #expect(harness.signposts.events() == [
                .begin(.sessionOpen),
                .begin(.sessionSync),
                .end(.sessionSync, .cancelled, .none),
                .end(.sessionOpen, .cancelled, .none),
            ])
            await harness.client.close()
        }
    }

    @Test("receipt interval starts only after an uncertain mutation response")
    func receiptResolution() async throws {
        try await withTestWatchdog {
            let harness = try await makeHarness()
            await MainActor.run { harness.model.selectedSessionID = "session" }
            let responder = Task {
                let mutation = try await request(in: harness.socket, frameIndex: 1)
                await harness.socket.enqueue(errorResponse(
                    id: mutation.id,
                    code: "disconnected",
                    retryable: true
                ))
                let status = try await request(in: harness.socket, frameIndex: 2)
                #expect(status.method == "command.status")
                await harness.socket.enqueue(successResponse(
                    id: status.id,
                    result: .object([
                        "status": .string("completed"),
                        "result": .object(["updated": .bool(true)]),
                    ])
                ))
            }
            defer { responder.cancel() }

            try await harness.model.setModel(ModelRef(provider: "test", id: "model"))
            try await valueOfOwnedTask(responder)
            #expect(harness.signposts.events() == [
                .begin(.receiptResolution),
                .end(.receiptResolution, .success, .none),
            ])
            await harness.client.close()
        }
    }

    @Test("terminal attach interval includes deduplicated replay installation")
    func terminalAttachReplay() async throws {
        try await withTestWatchdog {
            let harness = try await makeHarness()
            let terminal = TerminalSummary(
                id: "terminal",
                sessionId: "session",
                cwd: "/workspace",
                createdAt: "2026-01-01T00:00:00Z",
                exitedAt: nil,
                exitCode: nil,
                sequence: 2
            )
            let chunks = [
                TerminalChunk(sequence: 1, data: "one"),
                TerminalChunk(sequence: 2, data: "two"),
                TerminalChunk(sequence: 2, data: "duplicate"),
            ]
            let resetChunks = [
                TerminalChunk(sequence: 3, data: "replacement"),
                TerminalChunk(sequence: 3, data: "duplicate replacement"),
            ]
            let responder = Task {
                let attach = try await request(in: harness.socket, frameIndex: 1)
                #expect(attach.method == "terminal.attach")
                await harness.socket.enqueue(successResponse(
                    id: attach.id,
                    result: .object([
                        "terminal": try JSONValue.encode(terminal),
                        "chunks": try JSONValue.encode(chunks),
                        "reset": .bool(false),
                    ])
                ))
                let reset = try await request(in: harness.socket, frameIndex: 2)
                #expect(reset.method == "terminal.attach")
                await harness.socket.enqueue(successResponse(
                    id: reset.id,
                    result: .object([
                        "terminal": try JSONValue.encode(terminal),
                        "chunks": try JSONValue.encode(resetChunks),
                        "reset": .bool(true),
                    ])
                ))
            }
            defer { responder.cancel() }

            _ = try await harness.model.attachTerminal(terminal.id, after: 0)
            let appendedChunks = await MainActor.run { harness.model.terminalChunks[terminal.id] }
            #expect(appendedChunks == Array(chunks.prefix(2)))
            _ = try await harness.model.attachTerminal(terminal.id, after: 2)
            try await valueOfOwnedTask(responder)
            let resetResult = await MainActor.run { harness.model.terminalChunks[terminal.id] }
            #expect(resetResult == Array(resetChunks.prefix(1)))
            #expect(harness.signposts.events() == [
                .begin(.terminalAttachReplay),
                .end(.terminalAttachReplay, .success, PerformanceMetrics(itemCount: 2)),
                .begin(.terminalAttachReplay),
                .end(.terminalAttachReplay, .success, PerformanceMetrics(itemCount: 1)),
            ])
            await harness.client.close()
        }
    }

    private struct Harness {
        let socket: ScriptedGatewaySocket
        let client: GatewayClient
        let model: AppModel
        let signposts: RecordingPerformanceSignposts
    }

    private struct Request {
        let id: String
        let method: String
    }

    private func makeHarness() async throws -> Harness {
        let socket = ScriptedGatewaySocket()
        let signposts = RecordingPerformanceSignposts()
        let gatewayIDs = (1...16).map {
            UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", $0))!
        }
        let client = GatewayClient(
            socketFactory: ScriptedGatewaySocketFactory(socket: socket).factory,
            uuidSource: SequenceUUIDSource(gatewayIDs).source,
            performanceSignposts: signposts
        )
        await socket.enqueue(helloFrame())
        _ = try await client.connect(
            profile: GatewayProfile(
                id: "machine",
                label: "Mac",
                host: "gateway.test",
                port: 9_847,
                machineId: "machine",
                deviceId: "device"
            ),
            token: "token"
        )
        signposts.reset()
        let model = AppModel(
            client: client,
            cache: SnapshotCache(
                root: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            ),
            uuidSource: SequenceUUIDSource([
                UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
                UUID(uuidString: "10000000-0000-0000-0000-000000000002")!,
            ]).source,
            performanceSignposts: signposts
        )
        model.connectionState = .connected
        return Harness(socket: socket, client: client, model: model, signposts: signposts)
    }

    private func respondToSessionSynchronization(
        socket: ScriptedGatewaySocket,
        firstFrameIndex: Int,
        snapshot: SessionSnapshot
    ) async throws {
        let open = try await request(in: socket, frameIndex: firstFrameIndex)
        #expect(open.method == "session.open")
        await socket.enqueue(successResponse(
            id: open.id,
            result: .object([
                "session": try JSONValue.encode(snapshot),
                "syncToken": .string("sync-token"),
                "subscriptionToken": .string("subscription-token"),
            ])
        ))
        let sync = try await request(in: socket, frameIndex: firstFrameIndex + 1)
        #expect(sync.method == "session.sync")
        await socket.enqueue(successResponse(
            id: sync.id,
            result: .object(["synchronized": .bool(true)])
        ))
    }

    private func respondToPresentationRefreshes(
        socket: ScriptedGatewaySocket,
        firstFrameIndex: Int
    ) async throws {
        var pending = Set(["provider.list", "model.list", "session.commands"])
        for index in firstFrameIndex..<(firstFrameIndex + pending.count) {
            let next = try await request(in: socket, frameIndex: index)
            #expect(pending.remove(next.method) != nil)
            let result: JSONValue
            switch next.method {
            case "provider.list":
                result = .object(["providers": .array([])])
            case "model.list":
                result = .object(["models": .array([]), "nextCursor": .null])
            case "session.commands":
                result = .object(["commands": .array([])])
            default:
                Issue.record("unexpected presentation refresh: \(next.method)")
                return
            }
            await socket.enqueue(successResponse(id: next.id, result: result))
        }
        #expect(pending.isEmpty)
    }

    private func request(in socket: ScriptedGatewaySocket, frameIndex: Int) async throws -> Request {
        try await socket.waitUntilSent(count: frameIndex + 1)
        let frame = try JSONDecoder.gateway.decode(JSONValue.self, from: await socket.sentFrames()[frameIndex])
        let object = try #require(frame.objectValue)
        return Request(
            id: try #require(object["id"]?.stringValue),
            method: try #require(object["method"]?.stringValue)
        )
    }

    private func helloFrame() -> Data {
        Data(#"{"type":"hello","gatewayVersion":"1.0.0","piVersion":"1.0.0","protocolVersion":2,"minProtocolVersion":2,"machineId":"machine","machineName":"Mac","capabilities":["sessions.v1"]}"#.utf8)
    }

    private func successResponse(id: String, result: JSONValue) -> Data {
        try! JSONEncoder.gateway.encode(JSONValue.object([
            "type": .string("response"),
            "id": .string(id),
            "ok": .bool(true),
            "result": result,
        ]))
    }

    private func errorResponse(id: String, code: String, retryable: Bool) -> Data {
        try! JSONEncoder.gateway.encode(JSONValue.object([
            "type": .string("response"),
            "id": .string(id),
            "ok": .bool(false),
            "error": .object([
                "code": .string(code),
                "message": .string("synthetic failure"),
                "retryable": .bool(retryable),
            ]),
        ]))
    }
}
