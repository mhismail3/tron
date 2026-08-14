import Foundation
import Testing
@testable import TronMobile

@MainActor
@Suite("AppModel terminal lifecycle ownership", .serialized)
struct AppModelTerminalLifecycleTests {
    @Test("a successful attach after presentation revocation is rejected and detached")
    func staleAttachIsCompensated() async throws {
        try await withHarness { harness in
            let target = harness.model.beginTerminalPresentation(sessionID: "session")
            let intent = try #require(harness.model.beginTerminalIntent(for: target))
            let attaching = Task {
                try await harness.model.attachTerminal("terminal", after: 0, intent: intent)
            }
            defer { attaching.cancel() }
            let attach = try await request(in: harness.socket, frameIndex: 1)
            #expect(attach.method == "terminal.attach")

            harness.model.closeTerminalPresentation(target)
            await harness.socket.enqueue(successResponse(
                id: attach.id,
                result: terminalReplayResult(sequence: 1, data: "stale")
            ))
            await expectCancellation(attaching)

            let detach = try await request(in: harness.socket, frameIndex: 2)
            #expect(detach.method == "terminal.detach")
            #expect(detach.params?.objectValue?["terminalId"] == .string("terminal"))
            await harness.socket.enqueue(successResponse(
                id: detach.id,
                result: .object(["detached": .bool(true)])
            ))
            #expect(harness.model.terminalReplay(for: "terminal") == .empty)
        }
    }

    @Test("an older reset response cannot overwrite a newer terminal intent")
    func olderResetCannotOverwriteNewerIntent() async throws {
        try await withHarness { harness in
            let target = harness.model.beginTerminalPresentation(sessionID: "session")
            let firstIntent = try #require(harness.model.beginTerminalIntent(for: target))
            let older = Task {
                try await harness.model.attachTerminal("terminal", after: 0, intent: firstIntent)
            }
            defer { older.cancel() }
            let olderRequest = try await request(in: harness.socket, frameIndex: 1)

            let secondIntent = try #require(harness.model.beginTerminalIntent(for: target))
            let newer = Task {
                try await harness.model.attachTerminal("terminal", after: 0, intent: secondIntent)
            }
            defer { newer.cancel() }
            let newerRequest = try await request(in: harness.socket, frameIndex: 2)

            await harness.socket.enqueue(successResponse(
                id: newerRequest.id,
                result: terminalReplayResult(sequence: 5, data: "newer", reset: true)
            ))
            _ = try await newer.value
            await harness.socket.enqueue(successResponse(
                id: olderRequest.id,
                result: terminalReplayResult(sequence: 1, data: "older", reset: true)
            ))
            await expectCancellation(older)

            let replay = harness.model.terminalReplay(for: "terminal")
            #expect(replay.chunks == [TerminalChunk(sequence: 5, data: "newer")])
            #expect(replay.revision == 1)
            #expect(await harness.socket.sentFrames().count == 3)
        }
    }

    @Test("events delivered before an open response join its admitted replay")
    func pendingOpenEventsAreQuarantined() async throws {
        try await withHarness { harness in
            let target = harness.model.beginTerminalPresentation(sessionID: "session")
            let intent = try #require(harness.model.beginTerminalIntent(for: target))
            let opening = Task {
                try await harness.model.openTerminal(intent: intent, columns: 80, rows: 24)
            }
            defer { opening.cancel() }
            let open = try await request(in: harness.socket, frameIndex: 1)
            #expect(open.method == "terminal.open")

            await harness.model.handle(outputEvent(sequence: 2, data: "during open"))
            let replay = terminalReplayResult(sequence: 1, data: "open replay")
            await harness.socket.enqueue(successResponse(
                id: open.id,
                result: .object([
                    "terminal": replay.objectValue!["terminal"]!,
                    "replay": replay,
                ])
            ))
            _ = try await opening.value

            #expect(harness.model.terminalReplay(for: "terminal").chunks.map(\.data) == [
                "open replay", "during open",
            ])
        }
    }

    @Test("events delivered while attach is pending join the admitted replay")
    func pendingAttachEventsAreQuarantined() async throws {
        try await withHarness { harness in
            let target = harness.model.beginTerminalPresentation(sessionID: "session")
            let intent = try #require(harness.model.beginTerminalIntent(for: target))
            let attaching = Task {
                try await harness.model.attachTerminal("terminal", after: 0, intent: intent)
            }
            defer { attaching.cancel() }
            let attach = try await request(in: harness.socket, frameIndex: 1)

            await harness.model.handle(outputEvent(sequence: 2, data: "during attach"))
            await harness.model.handle(exitEvent(sequence: 2))
            await harness.socket.enqueue(successResponse(
                id: attach.id,
                result: terminalReplayResult(sequence: 1, data: "replay")
            ))
            _ = try await attaching.value

            #expect(harness.model.terminalReplay(for: "terminal").chunks.map(\.data) == [
                "replay", "during attach",
            ])
            #expect(harness.model.terminalHasExited("terminal"))
        }
    }

    @Test("two presentations share one terminal attachment until the final owner closes")
    func multiplePresentationsRetainAttachment() async throws {
        try await withHarness { harness in
            let firstTarget = harness.model.beginTerminalPresentation(sessionID: "session")
            let firstIntent = try #require(harness.model.beginTerminalIntent(for: firstTarget))
            let firstAttach = Task {
                try await harness.model.attachTerminal("terminal", after: 0, intent: firstIntent)
            }
            defer { firstAttach.cancel() }
            let firstRequest = try await request(in: harness.socket, frameIndex: 1)
            await harness.socket.enqueue(successResponse(
                id: firstRequest.id,
                result: terminalReplayResult(sequence: 1, data: "one")
            ))
            _ = try await firstAttach.value

            let secondTarget = harness.model.beginTerminalPresentation(sessionID: "session")
            let secondIntent = try #require(harness.model.beginTerminalIntent(for: secondTarget))
            let secondAttach = Task {
                try await harness.model.attachTerminal("terminal", after: 1, intent: secondIntent)
            }
            defer { secondAttach.cancel() }
            let secondRequest = try await request(in: harness.socket, frameIndex: 2)
            await harness.socket.enqueue(successResponse(
                id: secondRequest.id,
                result: terminalReplayResult(sequence: 2, data: "two")
            ))
            _ = try await secondAttach.value

            harness.model.closeTerminalPresentation(secondTarget)
            await harness.model.handle(outputEvent(sequence: 3, data: "three"))
            #expect(harness.model.terminalReplay(for: "terminal").chunks.map(\.data) == [
                "one", "two", "three",
            ])
            #expect(await harness.socket.sentFrames().count == 3)

            harness.model.closeTerminalPresentation(firstTarget)
            let detach = try await request(in: harness.socket, frameIndex: 3)
            #expect(detach.method == "terminal.detach")
            await harness.socket.enqueue(successResponse(
                id: detach.id,
                result: .object(["detached": .bool(true)])
            ))
        }
    }

    @Test("an unrelated pending open cannot suppress final-owner detach")
    func pendingOpenDoesNotSuppressDetach() async throws {
        try await withHarness { harness in
            let attachedTarget = harness.model.beginTerminalPresentation(sessionID: "session")
            let attachedIntent = try #require(harness.model.beginTerminalIntent(for: attachedTarget))
            let attaching = Task {
                try await harness.model.attachTerminal("terminal", after: 0, intent: attachedIntent)
            }
            defer { attaching.cancel() }
            let attach = try await request(in: harness.socket, frameIndex: 1)
            await harness.socket.enqueue(successResponse(
                id: attach.id,
                result: terminalReplayResult(sequence: 1, data: "one")
            ))
            _ = try await attaching.value

            let openingTarget = harness.model.beginTerminalPresentation(sessionID: "session")
            let openingIntent = try #require(harness.model.beginTerminalIntent(for: openingTarget))
            let opening = Task {
                try await harness.model.openTerminal(intent: openingIntent, columns: 80, rows: 24)
            }
            defer { opening.cancel() }
            let open = try await request(in: harness.socket, frameIndex: 2)

            harness.model.closeTerminalPresentation(attachedTarget)
            let detach = try await request(in: harness.socket, frameIndex: 3)
            #expect(detach.method == "terminal.detach")
            #expect(detach.params?.objectValue?["terminalId"] == .string("terminal"))
            await harness.socket.enqueue(successResponse(
                id: detach.id,
                result: .object(["detached": .bool(true)])
            ))

            let openedReplay = terminalReplayResult(
                sequence: 1,
                data: "opened",
                terminalID: "opened-terminal"
            )
            await harness.socket.enqueue(successResponse(
                id: open.id,
                result: .object([
                    "terminal": openedReplay.objectValue!["terminal"]!,
                    "replay": openedReplay,
                ])
            ))
            _ = try await opening.value
            #expect(harness.model.terminalReplay(for: "opened-terminal").chunks.map(\.data) == ["opened"])
        }
    }

    @Test("output and exit buffered after detach cannot recreate terminal state")
    func eventsAfterDetachAreIgnored() async throws {
        try await withHarness { harness in
            let target = harness.model.beginTerminalPresentation(sessionID: "session")
            let intent = try #require(harness.model.beginTerminalIntent(for: target))
            let attaching = Task {
                try await harness.model.attachTerminal("terminal", after: 0, intent: intent)
            }
            defer { attaching.cancel() }
            let attach = try await request(in: harness.socket, frameIndex: 1)
            await harness.socket.enqueue(successResponse(
                id: attach.id,
                result: terminalReplayResult(sequence: 1, data: "owned")
            ))
            _ = try await attaching.value
            await harness.model.handle(outputEvent(sequence: 2, data: "owned next"))
            await harness.model.handle(outputEvent(sequence: 2, data: "duplicate"))

            harness.model.closeTerminalPresentation(target)
            await harness.model.handle(outputEvent(sequence: 3, data: "late"))
            await harness.model.handle(exitEvent(sequence: 4))

            let detach = try await request(in: harness.socket, frameIndex: 2)
            await harness.socket.enqueue(successResponse(
                id: detach.id,
                result: .object(["detached": .bool(true)])
            ))
            #expect(harness.model.terminalReplay(for: "terminal").chunks == [
                TerminalChunk(sequence: 1, data: "owned"),
                TerminalChunk(sequence: 2, data: "owned next"),
            ])
            #expect(!harness.model.terminalHasExited("terminal"))
            #expect(await harness.socket.sentFrames().count == 3)
        }
    }

    @Test("a reset replay preserves output and exit delivered during reconciliation")
    func resetReconciliationDrainsPendingEvents() async throws {
        try await withHarness { harness in
            let target = harness.model.beginTerminalPresentation(sessionID: "session")
            let intent = try #require(harness.model.beginTerminalIntent(for: target))
            let attaching = Task {
                try await harness.model.attachTerminal("terminal", after: 0, intent: intent)
            }
            defer { attaching.cancel() }
            let attach = try await request(in: harness.socket, frameIndex: 1)
            await harness.socket.enqueue(successResponse(
                id: attach.id,
                result: terminalReplayResult(sequence: 1, data: "initial")
            ))
            _ = try await attaching.value

            await harness.model.handle(outputEvent(sequence: 3, data: "three"))
            let reconcile = try await request(in: harness.socket, frameIndex: 2)
            await harness.model.handle(outputEvent(sequence: 2, data: "two during replay"))
            await harness.model.handle(exitEvent(sequence: 3))
            await harness.socket.enqueue(successResponse(
                id: reconcile.id,
                result: terminalReplayResult(sequence: 1, data: "reset base", reset: true)
            ))

            try await eventually {
                harness.model.terminalReplay(for: "terminal").chunks.count == 3
            }
            #expect(harness.model.terminalReplay(for: "terminal").chunks.map(\.data) == [
                "reset base", "two during replay", "three",
            ])
            #expect(harness.model.terminalHasExited("terminal"))
        }
    }

    @Test("concurrent output gaps share one reconciliation attach")
    func outputGapsCoalesce() async throws {
        try await withHarness { harness in
            let target = harness.model.beginTerminalPresentation(sessionID: "session")
            let intent = try #require(harness.model.beginTerminalIntent(for: target))
            let attaching = Task {
                try await harness.model.attachTerminal("terminal", after: 0, intent: intent)
            }
            defer { attaching.cancel() }
            let attach = try await request(in: harness.socket, frameIndex: 1)
            await harness.socket.enqueue(successResponse(
                id: attach.id,
                result: terminalReplayResult(sequence: 1, data: "one")
            ))
            _ = try await attaching.value

            await harness.model.handle(outputEvent(sequence: 3, data: "three"))
            let reconcile = try await request(in: harness.socket, frameIndex: 2)
            #expect(reconcile.method == "terminal.attach")
            #expect(reconcile.params?.objectValue?["afterSequence"] == .number(1))
            await harness.model.handle(outputEvent(sequence: 4, data: "four"))
            #expect(await harness.socket.sentFrames().count == 3)

            await harness.socket.enqueue(successResponse(
                id: reconcile.id,
                result: terminalReplayResult(
                    chunks: [
                        TerminalChunk(sequence: 2, data: "two"),
                        TerminalChunk(sequence: 3, data: "three"),
                        TerminalChunk(sequence: 3, data: "duplicate"),
                    ]
                )
            ))
            try await eventually {
                harness.model.terminalReplay(for: "terminal").chunks.count == 4
            }
            #expect(harness.model.terminalReplay(for: "terminal").chunks.map(\.data) == [
                "one", "two", "three", "four",
            ])
        }
    }

    @Test("a replay that leaves a gap schedules one owned follow-up")
    func unresolvedGapSchedulesFollowUp() async throws {
        try await withHarness { harness in
            let target = harness.model.beginTerminalPresentation(sessionID: "session")
            let intent = try #require(harness.model.beginTerminalIntent(for: target))
            let attaching = Task {
                try await harness.model.attachTerminal("terminal", after: 0, intent: intent)
            }
            defer { attaching.cancel() }
            let attach = try await request(in: harness.socket, frameIndex: 1)
            await harness.socket.enqueue(successResponse(
                id: attach.id,
                result: terminalReplayResult(sequence: 1, data: "one")
            ))
            _ = try await attaching.value

            await harness.model.handle(outputEvent(sequence: 4, data: "four"))
            let firstRecovery = try await request(in: harness.socket, frameIndex: 2)
            await harness.socket.enqueue(successResponse(
                id: firstRecovery.id,
                result: terminalReplayResult(sequence: 2, data: "two")
            ))

            let followUp = try await request(in: harness.socket, frameIndex: 3)
            #expect(followUp.method == "terminal.attach")
            #expect(followUp.params?.objectValue?["afterSequence"] == .number(2))
            await harness.socket.enqueue(successResponse(
                id: followUp.id,
                result: terminalReplayResult(chunks: [
                    TerminalChunk(sequence: 3, data: "three"),
                    TerminalChunk(sequence: 4, data: "four"),
                ])
            ))
            try await eventually {
                harness.model.terminalReplay(for: "terminal").chunks.count == 4
            }
            #expect(harness.model.terminalReplay(for: "terminal").chunks.map(\.data) == [
                "one", "two", "three", "four",
            ])
            #expect(await harness.socket.sentFrames().count == 4)
        }
    }

    @Test("incomplete replay responses stop after three immediate recovery attempts")
    func recoveryAttemptCeiling() async throws {
        try await withHarness { harness in
            let target = harness.model.beginTerminalPresentation(sessionID: "session")
            let intent = try #require(harness.model.beginTerminalIntent(for: target))
            let attaching = Task {
                try await harness.model.attachTerminal("terminal", after: 0, intent: intent)
            }
            defer { attaching.cancel() }
            let attach = try await request(in: harness.socket, frameIndex: 1)
            await harness.socket.enqueue(successResponse(
                id: attach.id,
                result: terminalReplayResult(sequence: 1, data: "one")
            ))
            _ = try await attaching.value

            await harness.model.handle(outputEvent(sequence: 5, data: "five"))
            let first = try await request(in: harness.socket, frameIndex: 2)
            await harness.socket.enqueue(successResponse(
                id: first.id,
                result: terminalReplayResult(sequence: 2, data: "two")
            ))
            let second = try await request(in: harness.socket, frameIndex: 3)
            await harness.socket.enqueue(successResponse(
                id: second.id,
                result: terminalReplayResult(sequence: 3, data: "three")
            ))
            let third = try await request(in: harness.socket, frameIndex: 4)
            await harness.socket.enqueue(successResponse(
                id: third.id,
                result: terminalReplayResult(
                    chunks: [TerminalChunk(sequence: 1, data: "third reset")],
                    reset: true,
                    terminalSequence: 5
                )
            ))
            try await eventually {
                harness.model.terminalReplay(for: "terminal").chunks.first?.data == "third reset"
            }
            for _ in 0..<20 { await Task.yield() }
            #expect(await harness.socket.sentFrames().count == 5)
        }
    }

    @Test("final teardown invalidates a suspended terminal attach")
    func teardownRejectsSuspendedAttach() async throws {
        try await withHarness { harness in
            let target = harness.model.beginTerminalPresentation(sessionID: "session")
            let intent = try #require(harness.model.beginTerminalIntent(for: target))
            let attaching = Task {
                try await harness.model.attachTerminal("terminal", after: 0, intent: intent)
            }
            defer { attaching.cancel() }
            _ = try await request(in: harness.socket, frameIndex: 1)

            await harness.model.teardown()
            do {
                _ = try await attaching.value
                Issue.record("terminal attach unexpectedly survived teardown")
            } catch {
                #expect(error is GatewayPossiblySentError || error is CancellationError || error is GatewayFailure)
            }
            #expect(harness.model.terminalReplay(for: "terminal") == .empty)
            #expect(!harness.model.ownsTerminalIntent(intent))
        }
    }

    private func withHarness(
        operation: @escaping @MainActor (Harness) async throws -> Void
    ) async throws {
        let harness = try await makeHarness()
        do {
            try await withTestWatchdog { try await operation(harness) }
        } catch {
            await harness.client.close()
            throw error
        }
        await harness.client.close()
    }

    private struct Harness {
        let socket: ScriptedGatewaySocket
        let client: GatewayClient
        let model: AppModel
    }

    private struct Request {
        let id: String
        let method: String
        let params: JSONValue?
    }

    private func makeHarness() async throws -> Harness {
        let socket = ScriptedGatewaySocket()
        let gatewayIDs = (1...24).map {
            UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", $0))!
        }
        let client = GatewayClient(
            socketFactory: ScriptedGatewaySocketFactory(socket: socket).factory,
            uuidSource: SequenceUUIDSource(gatewayIDs).source
        )
        let model = AppModel(
            client: client,
            cache: SnapshotCache(
                root: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            )
        )
        await socket.enqueue(helloFrame())
        try await model.connectHostedGateway(
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
        return Harness(socket: socket, client: client, model: model)
    }

    private func request(in socket: ScriptedGatewaySocket, frameIndex: Int) async throws -> Request {
        try await socket.waitUntilSent(count: frameIndex + 1)
        let data = await socket.sentFrames()[frameIndex]
        let frame = try JSONDecoder.gateway.decode(JSONValue.self, from: data)
        let object = try #require(frame.objectValue)
        return Request(
            id: try #require(object["id"]?.stringValue),
            method: try #require(object["method"]?.stringValue),
            params: object["params"]
        )
    }

    private func expectCancellation(_ task: Task<TerminalSummary, Error>) async {
        do {
            _ = try await task.value
            Issue.record("stale terminal task unexpectedly completed")
        } catch {
            #expect(error is CancellationError)
        }
    }

    private func eventually(_ predicate: @escaping @MainActor () -> Bool) async throws {
        for _ in 0..<100 {
            if predicate() { return }
            await Task.yield()
        }
        Issue.record("condition did not become true")
    }

    private func terminalReplayResult(
        sequence: Int,
        data: String,
        reset: Bool = false,
        terminalID: String = "terminal"
    ) -> JSONValue {
        terminalReplayResult(
            chunks: [TerminalChunk(sequence: sequence, data: data)],
            reset: reset,
            terminalSequence: sequence,
            terminalID: terminalID
        )
    }

    private func terminalReplayResult(
        chunks: [TerminalChunk],
        reset: Bool = false,
        terminalSequence: Int? = nil,
        terminalID: String = "terminal"
    ) -> JSONValue {
        let sequence = terminalSequence ?? chunks.last?.sequence ?? 0
        let terminal = TerminalSummary(
            id: terminalID,
            sessionId: "session",
            cwd: "/workspace",
            createdAt: "2026-01-01T00:00:00Z",
            exitedAt: nil,
            exitCode: nil,
            sequence: sequence
        )
        return .object([
            "terminal": try! JSONValue.encode(terminal),
            "chunks": try! JSONValue.encode(chunks),
            "reset": .bool(reset),
        ])
    }

    private func outputEvent(sequence: Int, data: String) -> GatewayEvent {
        GatewayEvent(
            type: "event",
            topic: "terminal.output",
            sessionId: nil,
            payload: .object([
                "terminalId": .string("terminal"),
                "sequence": .number(Double(sequence)),
                "data": .string(data),
            ])
        )
    }

    private func exitEvent(sequence: Int) -> GatewayEvent {
        GatewayEvent(
            type: "event",
            topic: "terminal.exit",
            sessionId: nil,
            payload: .object([
                "terminalId": .string("terminal"),
                "sequence": .number(Double(sequence)),
                "exitCode": .number(0),
            ])
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
}
