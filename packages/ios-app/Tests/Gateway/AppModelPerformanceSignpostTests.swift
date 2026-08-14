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
                .end(.sessionResync, .success, .none),
            ])
            await harness.client.close()
        }
    }

    @Test("session open remains provisional until sync acknowledgement")
    func provisionalOpenIsNotPublished() async throws {
        try await withTestWatchdog {
            let harness = try await makeHarness()
            let snapshot = try SessionScenarioBuilder(seed: 42).openingTail(targetEncodedBytes: 8_192)
            let opening = Task { try await harness.model.openSessionPresentation(snapshot.sessionId) }
            defer { opening.cancel() }

            let open = try await request(in: harness.socket, frameIndex: 1)
            await harness.socket.enqueue(successResponse(
                id: open.id,
                result: .object([
                    "session": try JSONValue.encode(snapshot),
                    "syncToken": .string("sync-token"),
                    "subscriptionToken": .string("subscription-token"),
                ])
            ))
            let sync = try await request(in: harness.socket, frameIndex: 2)
            #expect(sync.method == "session.sync")
            #expect(await MainActor.run { harness.model.snapshots[snapshot.sessionId] } == nil)
            #expect(await MainActor.run {
                harness.model.authoritativeSnapshot(for: snapshot.sessionId)
            } == nil)

            await harness.socket.enqueue(successResponse(
                id: sync.id,
                result: .object(["synchronized": .bool(true)])
            ))
            _ = try await valueOfOwnedTask(opening)
            #expect(await MainActor.run {
                harness.model.authoritativeSnapshot(for: snapshot.sessionId)?.sessionId
            } == snapshot.sessionId)
            let refreshResponder = Task {
                try await respondToPresentationRefreshes(socket: harness.socket, firstFrameIndex: 3)
            }
            defer { refreshResponder.cancel() }
            try await valueOfOwnedTask(refreshResponder)
            await harness.client.close()
        }
    }

    @Test("route change before sync acknowledgement discards and closes the provisional token")
    func staleProvisionalOpenIsClosed() async throws {
        try await withTestWatchdog {
            let harness = try await makeHarness()
            let snapshot = try SessionScenarioBuilder(seed: 44).openingTail(targetEncodedBytes: 8_192)
            let opening = Task { try await harness.model.openSessionPresentation(snapshot.sessionId) }
            defer { opening.cancel() }

            let open = try await request(in: harness.socket, frameIndex: 1)
            await harness.socket.enqueue(successResponse(
                id: open.id,
                result: .object([
                    "session": try JSONValue.encode(snapshot),
                    "syncToken": .string("sync-token"),
                    "subscriptionToken": .string("provisional-token"),
                ])
            ))
            let sync = try await request(in: harness.socket, frameIndex: 2)
            await MainActor.run { harness.model.selectedSessionID = "replacement-route" }
            await harness.socket.enqueue(successResponse(
                id: sync.id,
                result: .object(["synchronized": .bool(true)])
            ))
            let close = try await request(in: harness.socket, frameIndex: 3)
            #expect(close.method == "session.close")
            #expect(close.params?.objectValue?["subscriptionToken"] == .string("provisional-token"))
            await harness.socket.enqueue(successResponse(
                id: close.id,
                result: .object(["closed": .bool(true)])
            ))

            do {
                _ = try await valueOfOwnedTask(opening)
                Issue.record("stale route unexpectedly installed its provisional open")
            } catch let failure as GatewayFailure {
                #expect(failure.code == "sync_failed")
            }
            #expect(await MainActor.run { harness.model.snapshots[snapshot.sessionId] } == nil)
            await harness.client.close()
        }
    }

    @Test("failed sync acknowledgement cannot replace an existing snapshot")
    func failedAcknowledgementPreservesSnapshot() async throws {
        try await withTestWatchdog {
            let harness = try await makeHarness()
            let cached = try SessionScenarioBuilder(seed: 45).openingTail(targetEncodedBytes: 8_192)
            var proposed = cached
            proposed.eventSequence += 10
            await MainActor.run { harness.model.snapshots[cached.sessionId] = cached }
            let opening = Task { try await harness.model.openSessionPresentation(cached.sessionId) }
            defer { opening.cancel() }

            let open = try await request(in: harness.socket, frameIndex: 1)
            await harness.socket.enqueue(successResponse(
                id: open.id,
                result: .object([
                    "session": try JSONValue.encode(proposed),
                    "syncToken": .string("sync-token"),
                    "subscriptionToken": .string("provisional-token"),
                ])
            ))
            let sync = try await request(in: harness.socket, frameIndex: 2)
            await harness.socket.enqueue(errorResponse(
                id: sync.id,
                code: "sync_failed",
                retryable: true
            ))
            let close = try await request(in: harness.socket, frameIndex: 3)
            #expect(close.method == "session.close")
            await harness.socket.enqueue(successResponse(
                id: close.id,
                result: .object(["closed": .bool(true)])
            ))

            do {
                _ = try await valueOfOwnedTask(opening)
                Issue.record("failed acknowledgement unexpectedly installed")
            } catch {}
            #expect(await MainActor.run {
                harness.model.snapshots[cached.sessionId]?.eventSequence
            } == cached.eventSequence)
            #expect(await MainActor.run {
                harness.model.authoritativeSnapshot(for: cached.sessionId)
            } == nil)
            await harness.client.close()
        }
    }

    @Test("reconnect restoration opens only the still-mounted presentation")
    func reconnectRestoresMountedPresentation() async throws {
        try await withTestWatchdog {
            let harness = try await makeHarness()
            let snapshot = try SessionScenarioBuilder(seed: 43).openingTail(targetEncodedBytes: 8_192)
            let openingResponder = Task {
                try await respondToSessionSynchronization(
                    socket: harness.socket,
                    firstFrameIndex: 1,
                    snapshot: snapshot
                )
                try await respondToPresentationRefreshes(socket: harness.socket, firstFrameIndex: 3)
            }
            defer { openingResponder.cancel() }

            _ = try await harness.model.openSessionPresentation(snapshot.sessionId)
            try await valueOfOwnedTask(openingResponder)
            let expandedCount = await MainActor.run { () -> Int in
                var expanded = snapshot
                if let first = snapshot.transcript.first {
                    expanded.transcript.insert(.label(LabelTranscriptItem(
                        id: "loaded-prefix",
                        parentId: nil,
                        timestamp: first.timestamp,
                        kind: .label,
                        targetId: first.id,
                        label: "Loaded"
                    )), at: 0)
                    expanded.transcriptStart = max(0, (snapshot.transcriptStart ?? 1) - 1)
                    expanded.transcriptTotal = max(snapshot.transcriptTotal ?? 0, expanded.transcript.count)
                }
                harness.model.snapshots[snapshot.sessionId] = expanded
                harness.model.selectedSessionID = "divergent-dashboard-selection"
                return expanded.transcript.count
            }
            let reconnectResponder = Task {
                try await respondToSessionSynchronization(
                    socket: harness.socket,
                    firstFrameIndex: 6,
                    snapshot: snapshot
                )
            }
            defer { reconnectResponder.cancel() }
            await harness.model.restoreMountedPresentationAfterReconnect()
            try await valueOfOwnedTask(reconnectResponder)
            #expect(await MainActor.run { harness.model.selectedSessionID } == snapshot.sessionId)
            #expect(await MainActor.run {
                harness.model.snapshots[snapshot.sessionId]?.transcript.count
            } == expandedCount)
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
            await MainActor.run { harness.model.selectedSessionID = "dashboard-selection" }
            await harness.socket.failNextSend(GatewayFailure(
                code: "disconnected",
                message: "synthetic send failure",
                retryable: true,
                details: nil
            ))
            let responder = Task {
                let status = try await request(in: harness.socket, frameIndex: 1)
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

            try await harness.model.setModel(
                ModelRef(provider: "test", id: "model"),
                sessionID: "mounted-route"
            )
            try await valueOfOwnedTask(responder)
            #expect(harness.signposts.events() == [
                .begin(.receiptResolution),
                .end(.receiptResolution, .success, .none),
            ])
            await harness.client.close()
        }
    }

    @Test("possibly-sent mutation cancellation never replays automatically")
    func possiblySentCancellationDoesNotReplay() async throws {
        try await withTestWatchdog {
            let harness = try await makeHarness()
            await harness.socket.suspendSends()
            let mutation = Task {
                try await harness.model.setModel(
                    ModelRef(provider: "test", id: "model"),
                    sessionID: "mounted-route"
                )
            }
            try await harness.socket.waitUntilSendInvoked(count: 2)
            mutation.cancel()
            do {
                try await valueOfOwnedTask(mutation)
                Issue.record("cancelled possibly-sent mutation unexpectedly succeeded")
            } catch let failure as GatewayFailure {
                #expect(failure.code == "outcome_unknown")
                #expect(!failure.retryable)
            }
            await harness.socket.releaseSend()
            #expect(await harness.socket.sentFrames().count == 1)
            #expect(harness.signposts.events().isEmpty)
            await harness.client.close()
        }
    }

    @Test("wire errors cannot forge local possibly-sent transport provenance")
    func wirePossiblySentCodeIsDefinitive() async throws {
        try await withTestWatchdog {
            let harness = try await makeHarness()
            let mutation = Task {
                try await harness.model.setModel(
                    ModelRef(provider: "test", id: "model"),
                    sessionID: "mounted-route"
                )
            }
            defer { mutation.cancel() }
            let request = try await request(in: harness.socket, frameIndex: 1)
            await harness.socket.enqueue(errorResponse(
                id: request.id,
                code: "possibly_sent",
                retryable: true
            ))
            do {
                try await valueOfOwnedTask(mutation)
                Issue.record("wire possibly-sent error unexpectedly succeeded")
            } catch let failure as GatewayFailure {
                #expect(failure.code == "possibly_sent")
            }
            #expect(await harness.socket.sentFrames().count == 2)
            #expect(harness.signposts.events().isEmpty)
            await harness.client.close()
        }
    }

    @Test("definitive retryable application errors do not enter receipt polling")
    func retryableApplicationErrorIsDefinitive() async throws {
        try await withTestWatchdog {
            let harness = try await makeHarness()
            let mutation = Task {
                try await harness.model.setModel(
                    ModelRef(provider: "test", id: "model"),
                    sessionID: "mounted-route"
                )
            }
            defer { mutation.cancel() }
            let request = try await request(in: harness.socket, frameIndex: 1)
            await harness.socket.enqueue(errorResponse(
                id: request.id,
                code: "busy",
                retryable: true
            ))
            do {
                try await valueOfOwnedTask(mutation)
                Issue.record("retryable application rejection unexpectedly succeeded")
            } catch let failure as GatewayFailure {
                #expect(failure.code == "busy")
            }
            #expect(await harness.socket.sentFrames().count == 2)
            #expect(harness.signposts.events().isEmpty)
            await harness.client.close()
        }
    }

    @Test("dashboard refresh cannot open or infer a transcript subscription")
    func dashboardRefreshHasNoSessionOpen() async throws {
        try await withTestWatchdog {
            let harness = try await makeHarness()
            await MainActor.run { harness.model.selectedSessionID = "stale-dashboard-selection" }
            let refreshing = Task { await harness.model.refreshAll() }
            defer { refreshing.cancel() }

            let list = try await request(in: harness.socket, frameIndex: 1)
            #expect(list.method == "session.list")
            await harness.socket.enqueue(successResponse(
                id: list.id,
                result: .object([
                    "sessions": .array([]),
                    "nextCursor": .null,
                    "listRevision": .number(1),
                ])
            ))

            var expected = Set(["provider.list", "model.list", "settings.get", "device.list"])
            for index in 2...5 {
                let next = try await request(in: harness.socket, frameIndex: index)
                #expect(expected.remove(next.method) != nil)
                let result: JSONValue
                switch next.method {
                case "provider.list": result = .object(["providers": .array([])])
                case "model.list": result = .object(["models": .array([]), "nextCursor": .null])
                case "settings.get": result = .object(["effective": .object([:])])
                case "device.list": result = .object(["devices": .array([])])
                default:
                    Issue.record("unexpected dashboard refresh: \(next.method)")
                    return
                }
                await harness.socket.enqueue(successResponse(id: next.id, result: result))
            }
            await refreshing.value
            #expect(expected.isEmpty)
            #expect(await harness.socket.sentFrames().count == 6)
            #expect(await MainActor.run { harness.model.selectedSessionID } == nil)
            await harness.client.close()
        }
    }

    @Test("secondary reads cannot open a hidden subscription")
    func secondaryReadRequiresOwnedSubscription() async throws {
        try await withTestWatchdog {
            let harness = try await makeHarness()
            await harness.model.loadContext(sessionID: "unmounted-route")
            #expect(await harness.socket.sentFrames().count == 1)
            await harness.client.close()
        }
    }

    @Test("create returns navigation identity without opening it implicitly")
    func createRouteIdentity() async throws {
        try await withTestWatchdog {
            let harness = try await makeHarness()
            await MainActor.run { harness.model.selectedSessionID = "dashboard-selection" }
            let creating = Task { try await harness.model.createSession(cwd: "/workspace") }
            defer { creating.cancel() }

            let mutation = try await request(in: harness.socket, frameIndex: 1)
            #expect(mutation.method == "session.create")
            await harness.socket.enqueue(successResponse(
                id: mutation.id,
                result: .object(["sessionId": .string("created-route")])
            ))
            let refresh = try await request(in: harness.socket, frameIndex: 2)
            #expect(refresh.method == "session.list")
            await harness.socket.enqueue(errorResponse(
                id: refresh.id,
                code: "synthetic_refresh_failure",
                retryable: false
            ))

            #expect(try await valueOfOwnedTask(creating) == "created-route")
            let selectedAfterCreate = await MainActor.run { harness.model.selectedSessionID }
            #expect(selectedAfterCreate == "dashboard-selection")
            await harness.client.close()
        }
    }

    @Test("fork returns navigation identity without replacing dashboard selection")
    func forkRouteIdentity() async throws {
        try await withTestWatchdog {
            let harness = try await makeHarness()
            await MainActor.run { harness.model.selectedSessionID = "dashboard-selection" }
            let forking = Task {
                try await harness.model.fork(
                    sessionID: "mounted-route",
                    entryID: "entry",
                    position: "before"
                )
            }
            defer { forking.cancel() }

            let mutation = try await request(in: harness.socket, frameIndex: 1)
            #expect(mutation.method == "session.fork")
            #expect(mutation.params?.objectValue?["sessionId"] == .string("mounted-route"))
            await harness.socket.enqueue(successResponse(
                id: mutation.id,
                result: .object([
                    "sessionId": .string("forked-route"),
                    "selectedText": .string("restored draft"),
                ])
            ))
            let refresh = try await request(in: harness.socket, frameIndex: 2)
            #expect(refresh.method == "session.list")
            await harness.socket.enqueue(errorResponse(
                id: refresh.id,
                code: "synthetic_refresh_failure",
                retryable: false
            ))

            let route = try await valueOfOwnedTask(forking)
            #expect(route.sessionID == "forked-route")
            #expect(route.editorText == "restored draft")
            let selectedAfterFork = await MainActor.run { harness.model.selectedSessionID }
            #expect(selectedAfterFork == "dashboard-selection")
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
        let params: JSONValue?
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
            method: try #require(object["method"]?.stringValue),
            params: object["params"]
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
