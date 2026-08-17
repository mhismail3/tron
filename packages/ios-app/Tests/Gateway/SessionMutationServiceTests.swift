import Foundation
import Testing
@testable import TronMobile

@MainActor
@Suite("Session mutation owner")
struct SessionMutationServiceTests {
    @Test("commands preserve explicit identity and typed outcomes")
    func explicitIdentityAndOutcomes() async throws {
        try await withTestWatchdog {
            let harness = try await makeHarness()
            var frameIndex = 1

            let creating = Task { try await harness.service.createSession(cwd: "/workspace") }
            let create = try await request(in: harness.socket, frameIndex: frameIndex)
            frameIndex += 1
            #expect(create.method == "session.create")
            #expect(create.params?["cwd"] == .string("/workspace"))
            try expectCommandID(create)
            await harness.socket.enqueue(successResponse(
                id: create.id,
                result: .object(["sessionId": .string("created")])
            ))
            #expect(try await valueOfOwnedTask(creating) == "created")

            let prompting = Task {
                try await harness.service.prompt(
                    "hello",
                    sessionID: "session-a",
                    uploadIDs: ["upload-a"],
                    behavior: "steer"
                )
            }
            let prompt = try await request(in: harness.socket, frameIndex: frameIndex)
            frameIndex += 1
            #expect(prompt.method == "session.prompt")
            #expect(prompt.params?["sessionId"] == .string("session-a"))
            #expect(prompt.params?["text"] == .string("hello"))
            #expect(prompt.params?["uploadIds"] == .array([.string("upload-a")]))
            #expect(prompt.params?["behavior"] == .string("steer"))
            try expectCommandID(prompt)
            await harness.socket.enqueue(successResponse(
                id: prompt.id,
                result: .object(["operationId": .string("operation")])
            ))
            try await valueOfOwnedTask(prompting)

            let clearing = Task { try await harness.service.clearQueue(sessionID: "session-b") }
            let clear = try await request(in: harness.socket, frameIndex: frameIndex)
            frameIndex += 1
            #expect(clear.method == "session.clearQueue")
            #expect(clear.params?["sessionId"] == .string("session-b"))
            try expectCommandID(clear)
            await harness.socket.enqueue(successResponse(
                id: clear.id,
                result: .object([
                    "steering": .array([.string("queued")]),
                    "followUp": .array([.string("later")]),
                ])
            ))
            let queue = try await valueOfOwnedTask(clearing)
            #expect(queue.steering == ["queued"])
            #expect(queue.followUp == ["later"])

            let replacing = Task {
                try await harness.service.replaceQueue(
                    sessionID: "session-b",
                    expectedRevision: 7,
                    items: [SessionSnapshot.QueuedMessage(
                        id: "queued-id",
                        behavior: .followUp,
                        text: "edited",
                        attachmentCount: 3
                    )]
                )
            }
            let replace = try await request(in: harness.socket, frameIndex: frameIndex)
            frameIndex += 1
            #expect(replace.method == "session.queue.replace")
            #expect(replace.params?["sessionId"] == .string("session-b"))
            #expect(replace.params?["expectedRevision"] == .number(7))
            #expect(replace.params?["items"] == .array([.object([
                "id": .string("queued-id"),
                "behavior": .string("followUp"),
                "text": .string("edited"),
            ])]))
            try expectCommandID(replace)
            await harness.socket.enqueue(successResponse(
                id: replace.id,
                result: .object([
                    "queueRevision": .number(8),
                    "items": .array([.object([
                        "id": .string("queued-id"),
                        "behavior": .string("followUp"),
                        "text": .string("edited"),
                        "attachmentCount": .number(3),
                    ])]),
                ])
            ))
            try await valueOfOwnedTask(replacing)

            let forking = Task {
                try await harness.service.fork(
                    sessionID: "session-c",
                    entryID: "entry-c",
                    position: "at"
                )
            }
            let fork = try await request(in: harness.socket, frameIndex: frameIndex)
            frameIndex += 1
            #expect(fork.method == "session.fork")
            #expect(fork.params?["sessionId"] == .string("session-c"))
            #expect(fork.params?["entryId"] == .string("entry-c"))
            #expect(fork.params?["position"] == .string("at"))
            try expectCommandID(fork)
            await harness.socket.enqueue(successResponse(
                id: fork.id,
                result: .object([
                    "sessionId": .string("forked"),
                    "selectedText": .string("draft"),
                ])
            ))
            #expect(try await valueOfOwnedTask(forking) == SessionForkOutcome(
                sessionID: "forked",
                selectedText: "draft"
            ))

            let navigating = Task {
                try await harness.service.navigate(
                    sessionID: "session-d",
                    entryID: "entry-d",
                    summarize: true,
                    instructions: "summary",
                    replaceInstructions: true,
                    label: "checkpoint"
                )
            }
            let navigate = try await request(in: harness.socket, frameIndex: frameIndex)
            frameIndex += 1
            #expect(navigate.method == "session.navigate")
            #expect(navigate.params?["sessionId"] == .string("session-d"))
            #expect(navigate.params?["entryId"] == .string("entry-d"))
            #expect(navigate.params?["summarize"] == .bool(true))
            #expect(navigate.params?["replaceInstructions"] == .bool(true))
            try expectCommandID(navigate)
            await harness.socket.enqueue(successResponse(
                id: navigate.id,
                result: .object(["editorText": .string("restored")])
            ))
            #expect(try await valueOfOwnedTask(navigating) == "restored")

            let updatingEditor = Task {
                try await harness.service.updateExtensionEditor(
                    sessionID: "session-e",
                    hostEpoch: "host-e",
                    baseRevision: 3,
                    operationID: "editor-operation",
                    text: "native draft"
                )
            }
            let editorUpdate = try await request(in: harness.socket, frameIndex: frameIndex)
            frameIndex += 1
            #expect(editorUpdate.method == "extension.editor.update")
            #expect(editorUpdate.params?["sessionId"] == .string("session-e"))
            #expect(editorUpdate.params?["hostEpoch"] == .string("host-e"))
            #expect(editorUpdate.params?["baseRevision"] == .number(3))
            #expect(editorUpdate.params?["operationId"] == .string("editor-operation"))
            #expect(editorUpdate.params?["text"] == .string("native draft"))
            try expectCommandID(editorUpdate)
            await harness.socket.enqueue(successResponse(
                id: editorUpdate.id,
                result: .object(["revision": .number(4), "text": .string("native draft"), "applied": .bool(true)])
            ))
            #expect(try await valueOfOwnedTask(updatingEditor) == ExtensionEditorUpdateResult(
                revision: 4, text: "native draft", applied: true, operationID: "editor-operation"
            ))

            let answering = Task {
                try await harness.service.answerInteraction(
                    interactionID: "interaction",
                    hostEpoch: "host-e",
                    presentationRevision: 7,
                    sessionID: "session-e",
                    value: .string("answer"),
                    cancelled: false
                )
            }
            let answer = try await request(in: harness.socket, frameIndex: frameIndex)
            #expect(answer.method == "extension.respond")
            #expect(answer.params?["sessionId"] == .string("session-e"))
            #expect(answer.params?["interactionId"] == .string("interaction"))
            #expect(answer.params?["hostEpoch"] == .string("host-e"))
            #expect(answer.params?["presentationRevision"] == .number(7))
            #expect(answer.params?["value"] == .string("answer"))
            #expect(answer.params?["cancelled"] == .bool(false))
            try expectCommandID(answer)
            await harness.socket.enqueue(successResponse(
                id: answer.id,
                result: .object(["answered": .bool(true)])
            ))
            try await valueOfOwnedTask(answering)
            await harness.client.close()
        }
    }

    @Test("all session command construction stays in the owner")
    func remainingCommandMethods() async throws {
        try await withTestWatchdog {
            let harness = try await makeHarness()
            var frameIndex = 1

            let importing = Task {
                try await harness.service.importSession(uploadID: "upload-import", cwd: "/import")
            }
            let imported = try await complete(
                importing,
                socket: harness.socket,
                frameIndex: &frameIndex,
                method: "session.import",
                result: .object(["sessionId": .string("imported")]),
                requiresSessionID: false,
                expectedParams: [
                    "uploadId": .string("upload-import"),
                    "cwd": .string("/import"),
                ]
            )
            #expect(imported == "imported")

            let aborting = Task {
                try await harness.service.abort(sessionID: "abort-session", kind: "tool")
            }
            try await completeVoid(
                aborting, socket: harness.socket, frameIndex: &frameIndex,
                method: "session.abort", result: .object(["aborted": .bool(true)]),
                expectedParams: [
                    "sessionId": .string("abort-session"),
                    "kind": .string("tool"),
                ]
            )

            let bash = Task {
                try await harness.service.executeBash(
                    "pwd", sessionID: "bash-session", excludeFromContext: true
                )
            }
            try await completeVoid(
                bash, socket: harness.socket, frameIndex: &frameIndex,
                method: "session.bash", result: .object(["accepted": .bool(true)]),
                expectedParams: [
                    "sessionId": .string("bash-session"),
                    "command": .string("pwd"),
                    "excludeFromContext": .bool(true),
                ]
            )

            let model = Task {
                try await harness.service.setModel(
                    ModelRef(provider: "provider", id: "model"),
                    sessionID: "model-session"
                )
            }
            try await completeVoid(
                model, socket: harness.socket, frameIndex: &frameIndex,
                method: "session.setModel", result: .object(["updated": .bool(true)]),
                expectedParams: [
                    "sessionId": .string("model-session"),
                    "provider": .string("provider"),
                    "modelId": .string("model"),
                ]
            )

            let thinking = Task {
                try await harness.service.setThinking("high", sessionID: "thinking-session")
            }
            try await completeVoid(
                thinking, socket: harness.socket, frameIndex: &frameIndex,
                method: "session.setThinking", result: .object(["updated": .bool(true)]),
                expectedParams: [
                    "sessionId": .string("thinking-session"),
                    "level": .string("high"),
                ]
            )

            let rename = Task {
                try await harness.service.rename("rename-session", name: "renamed")
            }
            try await completeVoid(
                rename, socket: harness.socket, frameIndex: &frameIndex,
                method: "session.rename", result: .object(["updated": .bool(true)]),
                expectedParams: [
                    "sessionId": .string("rename-session"),
                    "name": .string("renamed"),
                ]
            )

            let compact = Task {
                try await harness.service.compact(sessionID: "compact-session", instructions: nil)
            }
            try await completeVoid(
                compact, socket: harness.socket, frameIndex: &frameIndex,
                method: "session.compact", result: .object(["compacted": .bool(true), "queued": .bool(true)]),
                expectedParams: ["sessionId": .string("compact-session")],
                absentParams: ["instructions"]
            )

            let tools = Task {
                try await harness.service.setTools(["read", "bash"], sessionID: "tools-session")
            }
            try await completeVoid(
                tools, socket: harness.socket, frameIndex: &frameIndex,
                method: "session.setTools", result: .object(["updated": .bool(true)]),
                expectedParams: [
                    "sessionId": .string("tools-session"),
                    "tools": .array([.string("read"), .string("bash")]),
                ]
            )

            let label = Task {
                try await harness.service.setLabel(
                    sessionID: "label-session", entryID: "entry", label: nil
                )
            }
            try await completeVoid(
                label, socket: harness.socket, frameIndex: &frameIndex,
                method: "session.label", result: .object(["updated": .bool(true)]),
                expectedParams: [
                    "sessionId": .string("label-session"),
                    "entryId": .string("entry"),
                ],
                absentParams: ["label"]
            )

            let deleting = Task {
                try await harness.service.delete(sessionID: "delete-session")
            }
            try await completeVoid(
                deleting, socket: harness.socket, frameIndex: &frameIndex,
                method: "session.delete", result: .object(["deleted": .bool(true)]),
                expectedParams: ["sessionId": .string("delete-session")]
            )

            let reloading = Task {
                try await harness.service.reloadResources(sessionID: "resources-session")
            }
            try await completeVoid(
                reloading, socket: harness.socket, frameIndex: &frameIndex,
                method: "session.reloadResources", result: .object(["reloaded": .bool(true)]),
                expectedParams: ["sessionId": .string("resources-session")]
            )
            await harness.client.close()
        }
    }

    @Test("updated mutations reject an unrelated boolean response field")
    func exactUpdatedResponse() async throws {
        try await withTestWatchdog {
            let harness = try await makeHarness()
            let mutation = Task {
                try await harness.service.setModel(
                    ModelRef(provider: "provider", id: "model"),
                    sessionID: "session"
                )
            }
            defer { mutation.cancel() }
            let request = try await request(in: harness.socket, frameIndex: 1)
            #expect(request.method == "session.setModel")
            await harness.socket.enqueue(successResponse(
                id: request.id,
                result: .object(["unrelated": .bool(true)])
            ))
            do {
                try await valueOfOwnedTask(mutation)
                Issue.record("unrelated boolean response unexpectedly decoded as updated")
            } catch is DecodingError {
            } catch {
                Issue.record("unexpected response error: \(error)")
            }
            await harness.client.close()
        }
    }

    @Test("confirmed missing replays the exact command ID once")
    func stableCommandIDReplay() async throws {
        try await withTestWatchdog {
            let harness = try await makeHarness()
            await harness.socket.failNextSend(GatewayFailure(
                code: "disconnected",
                message: "synthetic send failure",
                retryable: true,
                details: nil
            ))
            let mutation = Task {
                try await harness.service.setModel(
                    ModelRef(provider: "provider", id: "model"),
                    sessionID: "session"
                )
            }
            let status = try await request(in: harness.socket, frameIndex: 1)
            #expect(status.method == "command.status")
            let statusCommandID = try #require(status.params?["commandId"]?.stringValue)
            #expect(status.params?["method"] == .string("session.setModel"))
            await harness.socket.enqueue(successResponse(
                id: status.id,
                result: .object(["status": .string("missing")])
            ))
            let replay = try await request(in: harness.socket, frameIndex: 2)
            #expect(replay.method == "session.setModel")
            #expect(replay.params?["commandId"] == .string(statusCommandID))
            await harness.socket.enqueue(successResponse(
                id: replay.id,
                result: .object(["updated": .bool(true)])
            ))
            try await valueOfOwnedTask(mutation)
            #expect(harness.signposts.events() == [
                .begin(.receiptResolution),
                .end(.receiptResolution, .success, .none),
            ])
            await harness.client.close()
        }
    }

    @Test("cancellation at confirmed-missing replay cannot emit another wire command")
    func cancellationBeforeReplayEmission() async throws {
        try await withTestWatchdog {
            let harness = try await makeHarness()
            await harness.socket.failNextSend(GatewayFailure(
                code: "disconnected",
                message: "synthetic send failure",
                retryable: true,
                details: nil
            ))
            let mutation = Task {
                try await harness.service.setModel(
                    ModelRef(provider: "provider", id: "model"),
                    sessionID: "cancelled-session"
                )
            }
            defer { mutation.cancel() }

            let status = try await request(in: harness.socket, frameIndex: 1)
            #expect(status.method == "command.status")
            let stableCommandID = try #require(status.params?["commandId"]?.stringValue)
            await harness.socket.suspendSends()
            await harness.socket.enqueue(successResponse(
                id: status.id,
                result: .object(["status": .string("missing")])
            ))
            try await harness.socket.waitUntilSendInvoked(count: 4)
            mutation.cancel()

            do {
                try await valueOfOwnedTask(mutation)
                Issue.record("cancelled replay unexpectedly succeeded")
            } catch let failure as GatewayFailure {
                #expect(failure.code == "outcome_unknown")
                #expect(!failure.retryable)
                #expect(failure.details?.objectValue?["commandId"] == .string(stableCommandID))
                #expect(failure.details?.objectValue?["method"] == .string("session.setModel"))
            }
            #expect(await harness.socket.sentFrames().count == 2)
            #expect(harness.signposts.events() == [
                .begin(.receiptResolution),
                .end(.receiptResolution, .cancelled, .none),
            ])
            await harness.client.close()
        }
    }

    private struct Harness {
        let socket: ScriptedGatewaySocket
        let client: GatewayClient
        let service: SessionMutationService
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
        let client = GatewayClient(
            socketFactory: ScriptedGatewaySocketFactory(socket: socket).factory,
            performanceSignposts: signposts
        )
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        let lifecycle = GatewayLifecycleCoordinator(
            client: client,
            profiles: GatewayProfileStore(defaults: defaults),
            clock: .continuous,
            reconnectDelayPolicy: .standard,
            uuidSource: .random,
            pairer: GatewayPairer(),
            pairingCommit: { _, _ in },
            profileTokenLookup: { _ in nil }
        )
        let executor = ConfirmedMutationExecutor(
            client: client,
            lifecycle: lifecycle,
            clock: .continuous,
            performanceSignposts: signposts
        )
        let service = SessionMutationService(
            client: client,
            executor: executor,
            uuidSource: .random
        )
        await socket.enqueue(helloFrame())
        try await lifecycle.connectHosted(
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
        return Harness(socket: socket, client: client, service: service, signposts: signposts)
    }

    private func complete<Value>(
        _ task: Task<Value, Error>,
        socket: ScriptedGatewaySocket,
        frameIndex: inout Int,
        method: String,
        result: JSONValue,
        requiresSessionID: Bool = true,
        expectedParams: [String: JSONValue] = [:],
        absentParams: [String] = []
    ) async throws -> Value {
        let sent = try await request(in: socket, frameIndex: frameIndex)
        frameIndex += 1
        #expect(sent.method == method)
        if requiresSessionID { #expect(sent.params?["sessionId"] != nil) }
        for (key, value) in expectedParams {
            #expect(sent.params?[key] == value)
        }
        for key in absentParams {
            #expect(sent.params?[key] == nil)
        }
        try expectCommandID(sent)
        await socket.enqueue(successResponse(id: sent.id, result: result))
        return try await valueOfOwnedTask(task)
    }

    private func completeVoid(
        _ task: Task<Void, Error>,
        socket: ScriptedGatewaySocket,
        frameIndex: inout Int,
        method: String,
        result: JSONValue,
        expectedParams: [String: JSONValue] = [:],
        absentParams: [String] = []
    ) async throws {
        _ = try await complete(
            task,
            socket: socket,
            frameIndex: &frameIndex,
            method: method,
            result: result,
            expectedParams: expectedParams,
            absentParams: absentParams
        )
    }

    nonisolated private func expectCommandID(_ request: Request) throws {
        #expect(!(try #require(request.params?["commandId"]?.stringValue)).isEmpty)
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

    private func helloFrame() -> Data {
        Data(#"{"type":"hello","gatewayVersion":"1.0.0","piVersion":"1.0.0","protocolVersion":3,"minProtocolVersion":3,"machineId":"machine","machineName":"Mac","capabilities":["sessions.v1"]}"#.utf8)
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

private extension JSONValue {
    subscript(key: String) -> JSONValue? { objectValue?[key] }
}
