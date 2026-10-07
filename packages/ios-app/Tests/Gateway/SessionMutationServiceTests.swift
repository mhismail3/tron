import Foundation
import Testing
import Synchronization
@testable import TronMobileCore
@testable import TronMobile

@MainActor
@Suite("Session mutation owner")
struct SessionMutationServiceTests {
    @Test("configuration send rechecks original intent after a transport wait without transmitting", arguments: ["model", "thinking", "context"])
    func configurationSendAdmission(kind: String) async throws {
        try await withTestWatchdog {
            let clock = ManualClock()
            let harness = try await makeHarness(lifecycleClock: clock.clock)
            let connection = try #require(await harness.client.activeConnectionID())
            await harness.lifecycle.noteDisconnected(connectionID: connection)
            let admitted = await ConfigurationAdmissionProbe()
            let command = Task {
                switch kind {
                case "model":
                    try await harness.service.setModel(ModelRef(provider: "fixture", id: "next"), sessionID: "original",
                        expectedRuntimeGeneration: "original-runtime", expectedModel: nil, sendAdmission: { admitted.value })
                case "thinking":
                    try await harness.service.setThinking("high", sessionID: "original",
                        expectedRuntimeGeneration: "original-runtime", expectedModel: nil, sendAdmission: { admitted.value })
                default:
                    try await harness.service.setContextWindow(nil, for: ModelRef(provider: "fixture", id: "original"), sessionID: "original",
                        expectedRevision: 1, expectedRuntimeGeneration: "original-runtime", sendAdmission: { admitted.value })
                }
            }
            defer { command.cancel() }
            // Exact lifecycle wait entry, not a yield/delay: moving the send
            // check before executor.perform must let a stale frame escape.
            try await clock.waitUntilSleeping(count: 1, duration: .milliseconds(100))
            await MainActor.run { admitted.value = false }
            await harness.replacement.enqueue(helloFrame())
            try await harness.lifecycle.connectHosted(profile: harness.profile, token: "token")
            clock.advance(by: .milliseconds(100))
            do { try await valueOfOwnedTask(command); Issue.record("retired intent was sent") }
            catch let failure as GatewayFailure { #expect(failure.code == "conflict") }
            #expect(await harness.replacement.sentFrames().count == 1)
            await harness.client.close()
        }
    }

    @Test("accepted configuration outcome survives revoked presentation while missing receipt cannot replay", arguments: [false, true])
    func configurationReceiptAdmission(missing: Bool) async throws {
        try await withTestWatchdog {
            let harness = try await makeHarness()
            let admitted = await ConfigurationAdmissionProbe()
            await harness.socket.failNextSend(GatewayFailure(code: "disconnected", message: "synthetic uncertain send", retryable: true, details: nil))
            let command = Task { try await harness.service.setThinking("high", sessionID: "original",
                expectedRuntimeGeneration: "original-runtime", expectedModel: nil, sendAdmission: { admitted.value }) }
            defer { command.cancel() }
            try await reconnect(harness)
            let status = try await request(in: harness.replacement, frameIndex: 1)
            #expect(status.method == "command.status")
            await MainActor.run { admitted.value = false }
            await harness.replacement.enqueue(successResponse(id: status.id, result: .object([
                "status": .string(missing ? "missing" : "completed"), "result": .object(["updated": .bool(true), "revision": .number(11)])
            ])))
            if missing {
                do { try await valueOfOwnedTask(command); Issue.record("retired intent replayed") }
                catch is CancellationError { }
            } else { try await valueOfOwnedTask(command) }
            #expect(await harness.replacement.sentFrames().count == 2)
            await harness.client.close()
        }
    }

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

            let worktreeCreating = Task {
                try await harness.service.createSession(
                    cwd: "/workspace",
                    sourceControl: SessionSourceControlSelection(
                        mode: .newBranchWorktree,
                        branch: "feature/tron",
                        base: "main"
                    )
                )
            }
            let worktreeCreate = try await request(in: harness.socket, frameIndex: frameIndex)
            frameIndex += 1
            #expect(worktreeCreate.method == "session.create")
            #expect(worktreeCreate.params?["cwd"] == .string("/workspace"))
            #expect(worktreeCreate.params?["sourceControl"] == .object([
                "mode": .string("newBranchWorktree"),
                "branch": .string("feature/tron"),
                "base": .string("main"),
            ]))
            try expectCommandID(worktreeCreate)
            await harness.socket.enqueue(successResponse(
                id: worktreeCreate.id,
                result: .object(["sessionId": .string("worktree-created")])
            ))
            #expect(try await valueOfOwnedTask(worktreeCreating) == "worktree-created")

            let prompting = Task {
                try await harness.service.prompt(
                    "hello",
                    sessionID: "session-a",
                    uploadIDs: ["upload-a"],
                    behavior: "steer",
                    resourceInvocation: ComposerResourceInvocation(source: .skill, name: "review", arguments: "")
                )
            }
            let prompt = try await request(in: harness.socket, frameIndex: frameIndex)
            frameIndex += 1
            #expect(prompt.method == "session.prompt")
            #expect(prompt.params?["sessionId"] == .string("session-a"))
            #expect(prompt.params?["text"] == .string("hello"))
            #expect(prompt.params?["uploadIds"] == .array([.string("upload-a")]))
            #expect(prompt.params?["behavior"] == .string("steer"))
            #expect(prompt.params?["resourceInvocation"] == .object([
                "source": .string("skill"), "name": .string("review"), "arguments": .string("")
            ]))
            try expectCommandID(prompt)
            await harness.socket.enqueue(successResponse(
                id: prompt.id,
                result: .object(["operationId": .string("operation")])
            ))
            _ = try await valueOfOwnedTask(prompting)

            let clearing = Task { try await harness.service.clearQueue(sessionID: "session-b") }
            let clear = try await request(in: harness.socket, frameIndex: frameIndex)
            frameIndex += 1
            #expect(clear.method == "session.clearQueue")
            #expect(clear.params?["sessionId"] == .string("session-b"))
            try expectCommandID(clear)
            await harness.socket.enqueue(successResponse(
                id: clear.id,
                result: .object(["cleared": .bool(true)])
            ))
            try await valueOfOwnedTask(clearing)

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
                    value: .object([
                        "version": .number(1),
                        "answers": .array([.object([
                            "questionId": .string("db"),
                            "optionIds": .array([.string("postgres")]),
                        ])]),
                    ]),
                    cancelled: false
                )
            }
            let answer = try await request(in: harness.socket, frameIndex: frameIndex)
            frameIndex += 1
            #expect(answer.method == "extension.respond")
            #expect(answer.params?["sessionId"] == .string("session-e"))
            #expect(answer.params?["interactionId"] == .string("interaction"))
            #expect(answer.params?["hostEpoch"] == .string("host-e"))
            #expect(answer.params?["presentationRevision"] == .number(7))
            #expect(answer.params?["value"] == .object([
                "version": .number(1),
                "answers": .array([.object([
                    "questionId": .string("db"),
                    "optionIds": .array([.string("postgres")]),
                ])]),
            ]))
            #expect(answer.params?["cancelled"] == .bool(false))
            try expectCommandID(answer)
            await harness.socket.enqueue(successResponse(
                id: answer.id,
                result: .object(["answered": .bool(true)])
            ))
            try await valueOfOwnedTask(answering)

            let cancelling = Task {
                try await harness.service.answerInteraction(
                    interactionID: "cancel-interaction",
                    hostEpoch: "host-c",
                    presentationRevision: 11,
                    sessionID: "session-c",
                    value: nil,
                    cancelled: true
                )
            }
            let cancellation = try await request(in: harness.socket, frameIndex: frameIndex)
            frameIndex += 1
            #expect(cancellation.method == "extension.respond")
            #expect(cancellation.params?["sessionId"] == .string("session-c"))
            #expect(cancellation.params?["interactionId"] == .string("cancel-interaction"))
            #expect(cancellation.params?["hostEpoch"] == .string("host-c"))
            #expect(cancellation.params?["presentationRevision"] == .number(11))
            // Params.value is Optional and synthesized Codable omits nil; the
            // Gateway's extension.respond contract treats omitted value as the
            // valid cancellation payload.
            #expect(cancellation.params?["value"] == nil)
            #expect(cancellation.params?["cancelled"] == .bool(true))
            try expectCommandID(cancellation)
            await harness.socket.enqueue(successResponse(
                id: cancellation.id,
                result: .object(["answered": .bool(true)])
            ))
            try await valueOfOwnedTask(cancelling)
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

            let subagentAbort = Task {
                try await harness.service.abortSubagent(leaseID: "subagent-lease")
            }
            _ = try await complete(
                subagentAbort, socket: harness.socket, frameIndex: &frameIndex,
                method: "session.processTranscript.abort",
                result: .object(["aborted": .bool(true)]),
                requiresSessionID: false,
                expectedParams: ["leaseId": .string("subagent-lease")]
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
                , expectedRuntimeGeneration: "fixture-runtime", expectedModel: nil, sendAdmission: { true })
            }
            try await completeVoid(
                model, socket: harness.socket, frameIndex: &frameIndex,
                method: "session.setModel", result: .object(["updated": .bool(true), "revision": .number(11)]),
                expectedParams: [
                    "sessionId": .string("model-session"),
                    "provider": .string("provider"),
                    "modelId": .string("model"),
                ]
            )

            let contextWindow = Task {
                try await harness.service.setContextWindow(
                    1_050_000,
                    for: ModelRef(provider: "openai-codex", id: "gpt-6-astra"),
                    sessionID: "context-session", expectedRevision: 7, expectedRuntimeGeneration: "runtime-1"
                , sendAdmission: { true })
            }
            try await completeVoid(
                contextWindow, socket: harness.socket, frameIndex: &frameIndex,
                method: "session.setContextWindow", result: .object(["updated": .bool(true), "revision": .number(11)]),
                expectedParams: [
                    "sessionId": .string("context-session"),
                    "provider": .string("openai-codex"),
                    "modelId": .string("gpt-6-astra"),
                    "contextWindow": .number(1_050_000),
                    "expectedRevision": .number(7),
                    "expectedRuntimeGeneration": .string("runtime-1"),
                ]
            )

            let contextWindowReset = Task {
                try await harness.service.setContextWindow(
                    nil,
                    for: ModelRef(provider: "openai-codex", id: "gpt-6-astra"),
                    sessionID: "context-session", expectedRevision: 8, expectedRuntimeGeneration: "runtime-1"
                , sendAdmission: { true })
            }
            try await completeVoid(
                contextWindowReset, socket: harness.socket, frameIndex: &frameIndex,
                method: "session.setContextWindow", result: .object(["updated": .bool(true), "revision": .number(11)]),
                expectedParams: [
                    "sessionId": .string("context-session"),
                    "provider": .string("openai-codex"),
                    "modelId": .string("gpt-6-astra"),
                    "contextWindow": .null,
                    "expectedRevision": .number(8),
                    "expectedRuntimeGeneration": .string("runtime-1"),
                ]
            )

            let thinking = Task {
                try await harness.service.setThinking("high", sessionID: "thinking-session", expectedRuntimeGeneration: "fixture-runtime", expectedModel: nil, sendAdmission: { true })
            }
            try await completeVoid(
                thinking, socket: harness.socket, frameIndex: &frameIndex,
                method: "session.setThinking", result: .object(["updated": .bool(true), "revision": .number(11)]),
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
                , expectedRuntimeGeneration: "fixture-runtime", expectedModel: nil, sendAdmission: { true })
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
            } catch let failure as GatewayFailure {
                #expect(failure.code == "invalid_response")
            } catch {
                Issue.record("unexpected response error: \(error)")
            }
            await harness.client.close()
        }
    }

    @Test("wire disconnected response is definitive and never authorizes retry")
    func wireDisconnectedIsNotDefinitelyUnsent() async throws {
        try await withTestWatchdog {
            let harness = try await makeHarness()
            let mutation = Task {
                try await harness.service.setModel(
                    ModelRef(provider: "provider", id: "model"),
                    sessionID: "session"
                , expectedRuntimeGeneration: "fixture-runtime", expectedModel: nil, sendAdmission: { true })
            }
            let request = try await request(in: harness.socket, frameIndex: 1)
            await harness.socket.enqueue(try JSONEncoder.gateway.encode(JSONValue.object([
                "type": .string("response"),
                "id": .string(request.id),
                "ok": .bool(false),
                "error": .object([
                    "code": .string("disconnected"),
                    "message": .string("runtime projection unavailable"),
                    "retryable": .bool(true),
                    "details": .null,
                ]),
            ])))

            do {
                try await valueOfOwnedTask(mutation)
                Issue.record("wire failure unexpectedly succeeded")
            } catch let failure as GatewayFailure {
                #expect(failure.code == "disconnected")
                #expect(failure.message == "runtime projection unavailable")
            }
            #expect(await harness.socket.sentFrames().count == 2)
            await harness.client.close()
        }
    }

    @Test("an oversized mutation or receipt response preserves uncertainty without replay", arguments: [false, true])
    func projectionRejectionIsNotCommandRejection(duringReceiptResolution: Bool) async throws {
        try await withTestWatchdog {
            let harness = try await makeHarness()
            if duringReceiptResolution {
                await harness.socket.failNextSend(GatewayFailure(code: "disconnected", message: "synthetic loss", retryable: true, details: nil))
            }
            let mutation = Task {
                try await harness.service.setModel(ModelRef(provider: "provider", id: "model"), sessionID: "session", expectedRuntimeGeneration: "fixture-runtime", expectedModel: nil, sendAdmission: { true })
            }
            defer { mutation.cancel() }
            if duringReceiptResolution { try await reconnect(harness) }
            let socket = duringReceiptResolution ? harness.replacement : harness.socket
            let request = try await request(in: socket, frameIndex: 1)
            #expect(request.method == (duringReceiptResolution ? "command.status" : "session.setModel"))
            await socket.enqueue(try JSONEncoder.gateway.encode(JSONValue.object([
                "type": .string("response"), "id": .string(request.id), "ok": .bool(false),
                "error": .object([
                    "code": .string("response_too_large"), "message": .string("Projection exceeds node limit"),
                    "retryable": .bool(false), "details": .object(["maximumNodes": .number(32_768)]),
                ]),
            ])))
            do {
                try await valueOfOwnedTask(mutation)
                Issue.record("projection failure unexpectedly succeeded")
            } catch let failure as GatewayFailure {
                #expect(failure.code == "outcome_unknown")
                #expect(failure.details?.objectValue?["commandId"] == request.params?["commandId"])
            }
            #expect(await socket.sentFrames().count == 2)
            await harness.client.close()
        }
    }

    @Test("a terminal unpaired recovery stops receipt polling rather than spinning the main actor")
    func terminalReceiptRecoveryStops() async throws {
        try await withTestWatchdog {
            let probe = ReceiptRecoveryClockProbe()
            let harness = try await makeHarness(executorClock: probe.clock, selectProfile: true)
            await harness.socket.failNextSend(GatewayFailure(code: "disconnected", message: "Synthetic loss", retryable: true, details: nil))
            let mutation = Task { try await harness.service.setModel(ModelRef(provider: "provider", id: "model"), sessionID: "session", expectedRuntimeGeneration: "fixture-runtime", expectedModel: nil, sendAdmission: { true }) }
            defer { mutation.cancel() }
            try await harness.socket.waitUntilClosed()
            probe.startCounting()
            var events = harness.client.events.makeAsyncIterator()
            let delivery = try #require(await events.next())
            await harness.lifecycle.noteDisconnected(connectionID: delivery.connectionID)
            await harness.lifecycle.requestReconnect()
            do { try await valueOfOwnedTask(mutation); Issue.record("Unknown command unexpectedly succeeded") }
            catch let failure as GatewayFailure { #expect(failure.code == "outcome_unknown") }
            #expect(probe.readCount < 10, "A stopped credential state must exit rather than poll until the 90-second deadline")
            #expect(await harness.lifecycle.connectionState == .unpaired)
            await harness.client.close()
        }
    }

    @Test("a retired receipt reply is discarded and the same command is resolved on its successor socket")
    func retiredReceiptReplyIsRequeried() async throws {
        try await withTestWatchdog {
            let harness = try await makeHarness()
            await harness.socket.failNextSend(GatewayFailure(code: "disconnected", message: "Synthetic loss", retryable: true, details: nil))
            let mutation = Task { try await harness.service.setModel(ModelRef(provider: "provider", id: "model"), sessionID: "session", expectedRuntimeGeneration: "fixture-runtime", expectedModel: nil, sendAdmission: { true }) }
            defer { mutation.cancel() }
            try await reconnect(harness)
            let stale = try await request(in: harness.replacement, frameIndex: 1)
            let retiredID = try #require(await harness.client.activeConnectionID())
            await harness.lifecycle.noteDisconnected(connectionID: retiredID)
            await harness.replacement.enqueue(successResponse(id: stale.id,
                result: .object(["status": .string("completed"), "result": .object(["updated": .bool(false)])])))
            await harness.successor.enqueue(helloFrame())
            try await harness.lifecycle.connectHosted(profile: harness.profile, token: "token")
            let fresh = try await request(in: harness.successor, frameIndex: 1)
            #expect(fresh.method == "command.status")
            #expect(fresh.params?["commandId"] == stale.params?["commandId"])
            await harness.successor.enqueue(successResponse(id: fresh.id,
                result: .object(["status": .string("completed"), "result": .object(["updated": .bool(true), "revision": .number(11)])])))
            try await valueOfOwnedTask(mutation)
            #expect(await harness.successor.sentFrames().count == 2)
            await harness.client.close()
        }
    }

    @Test("background interruption resolves the original receipt on foreground without redispatch")
    func backgroundReceiptResolution() async throws {
        try await withTestWatchdog {
            let harness = try await makeHarness()
            let mutation = Task { try await harness.service.setModel(ModelRef(provider: "provider", id: "model"), sessionID: "session", expectedRuntimeGeneration: "fixture-runtime", expectedModel: nil, sendAdmission: { true }) }
            defer { mutation.cancel() }
            let sent = try await request(in: harness.socket, frameIndex: 1)
            await harness.lifecycle.enteredBackground()
            try await harness.socket.waitUntilClosed()
            await harness.lifecycle.becameActive()
            await harness.replacement.enqueue(helloFrame())
            try await harness.lifecycle.connectHosted(profile: harness.profile, token: "token")
            let status = try await request(in: harness.replacement, frameIndex: 1)
            #expect(status.method == "command.status")
            #expect(status.params?["commandId"] == sent.params?["commandId"])
            await harness.replacement.enqueue(successResponse(id: status.id,
                result: .object(["status": .string("completed"), "result": .object(["updated": .bool(true), "revision": .number(11)])])))
            try await valueOfOwnedTask(mutation)
            #expect(await harness.socket.sentFrames().count == 2)
            #expect(await harness.replacement.sentFrames().count == 2)
            await harness.client.close()
        }
    }

    @Test("definite terminal send success survives same-authority background equally for initial send and permitted replay", arguments: [false, true])
    func terminalSendSuccessAcrossBackground(replay: Bool) async throws {
        try await withTestWatchdog {
            let harness = try await makeHarness()
            if replay { await harness.socket.failNextSend(GatewayFailure(code: "disconnected", message: "Fixture loss", retryable: true, details: nil)) }
            let command = "terminal-background-command"
            let mutation = Task {
                try await harness.executor.performValue(method: "session.setModel", commandID: command) {
                    let terminal: JSONValue = try await harness.client.request("session.setModel", JSONValue.object(["commandId": .string(command)]))
                    // The typed terminal result is already owned before the
                    // scene transition retires transport publication admission.
                    await harness.lifecycle.enteredBackground()
                    return terminal
                }
            }
            defer { mutation.cancel() }
            let socket: ScriptedGatewaySocket
            let index: Int
            if replay {
                try await reconnect(harness)
                let status = try await request(in: harness.replacement, frameIndex: 1)
                #expect(status.params?["commandId"] == .string(command))
                await harness.replacement.enqueue(successResponse(id: status.id, result: .object(["status": .string("missing")])))
                socket = harness.replacement; index = 2
            } else { socket = harness.socket; index = 1 }
            let sent = try await request(in: socket, frameIndex: index)
            #expect(sent.params?["commandId"] == .string(command))
            await socket.enqueue(successResponse(id: sent.id, result: .object(["updated": .bool(true)])))
            #expect(try await valueOfOwnedTask(mutation) == .object(["updated": .bool(true)]))
            #expect(await socket.sentFrames().count == index + 1)
            await harness.lifecycle.teardown()
        }
    }

    @Test("authority retirement while original receipt read is held cannot replay or publish the old command")
    func retiredAuthorityCannotReplayHeldReceipt() async throws {
        try await withTestWatchdog {
            let harness = try await makeHarness()
            await harness.socket.failNextSend(GatewayFailure(code: "disconnected", message: "Fixture loss", retryable: true, details: nil))
            let mutation = Task { try await harness.service.setModel(ModelRef(provider: "fixture", id: "fixture"), sessionID: "original-session", expectedRuntimeGeneration: "fixture-runtime", expectedModel: nil, sendAdmission: { true }) }
            defer { mutation.cancel() }
            try await reconnect(harness)
            let status = try await request(in: harness.replacement, frameIndex: 1)
            let command = try #require(status.params?["commandId"]?.stringValue)
            // Real lifecycle replacement revokes the command namespace even
            // when the replacement lacks a token and cannot connect.
            await harness.lifecycle.switchGateway(GatewayProfile(id: "replacement-authority", label: "Replacement", host: "replacement.example.test", port: 9847, machineId: "replacement-authority"))
            await harness.replacement.enqueue(successResponse(id: status.id, result: .object(["status": .string("missing")])))
            do { try await valueOfOwnedTask(mutation); Issue.record("retired authority published the old command") }
            catch let failure as GatewayFailure {
                #expect(failure.code == "outcome_unknown")
                #expect(failure.details?.objectValue?["commandId"] == .string(command))
            }
            #expect(await harness.replacement.sentFrames().count == 2)
            #expect(await harness.successor.sentFrames().isEmpty)
            await harness.lifecycle.teardown()
        }
    }

    @Test("definitely-unsent Home attempt permits a later new command ID")
    func definitelyUnsentHomeAttemptCanBeRetried() async throws {
        try await withTestWatchdog {
            let harness = try await makeHarness()
            let localFailure = GatewayDefinitelyNotSentError(failure: GatewayFailure(
                code: "disconnected", message: "The Home command was not sent.", retryable: true, details: nil
            ))
            var unsentAttempts = 0
            do {
                _ = try await harness.executor.performValue(
                    method: "home.designate", commandID: "definitely-unsent-command", replayMissingReceipt: false
                ) {
                    unsentAttempts += 1
                    throw localFailure
                }
                Issue.record("definitely-unsent Home attempt unexpectedly succeeded")
            } catch let failure as GatewayDefinitelyNotSentError {
                #expect(failure.failure.code == "disconnected")
            }
            #expect(unsentAttempts == 2)
            let initialFrames = await harness.socket.sentFrames()
            let initialRequests = try initialFrames.compactMap { frame -> String? in
                let value = try JSONDecoder.gateway.decode(JSONValue.self, from: frame)
                return value.objectValue?["method"]?.stringValue
            }
            #expect(!initialRequests.contains("home.designate"))

            let retry = Task {
                try await harness.executor.performValue(method: "home.designate", commandID: "new-home-command") {
                    try await harness.client.request(
                        "home.designate",
                        JSONValue.object(["commandId": .string("new-home-command")])
                    )
                }
            }
            let sent = try await request(in: harness.socket, frameIndex: 1)
            #expect(sent.method == "home.designate")
            #expect(sent.params?["commandId"] == .string("new-home-command"))
            await harness.socket.enqueue(successResponse(id: sent.id, result: .object([
                "homeId": .string("home"), "sessionId": .string("home-session"), "generation": .number(1),
            ])))
            let result = try await retry.value
            #expect(result.objectValue?["sessionId"] == .string("home-session"))
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
                , expectedRuntimeGeneration: "fixture-runtime", expectedModel: nil, sendAdmission: { true })
            }
            defer { mutation.cancel() }
            try await reconnect(harness)
            let status = try await request(in: harness.replacement, frameIndex: 1)
            #expect(status.method == "command.status")
            let statusCommandID = try #require(status.params?["commandId"]?.stringValue)
            #expect(status.params?["method"] == .string("session.setModel"))
            await harness.replacement.enqueue(successResponse(
                id: status.id,
                result: .object(["status": .string("missing")])
            ))
            let replay = try await request(in: harness.replacement, frameIndex: 2)
            #expect(replay.method == "session.setModel")
            #expect(replay.params?["commandId"] == .string(statusCommandID))
            await harness.replacement.enqueue(successResponse(
                id: replay.id,
                result: .object(["updated": .bool(true), "revision": .number(11)])
            ))
            try await valueOfOwnedTask(mutation)
            #expect(receiptEvents(harness) == [
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
                , expectedRuntimeGeneration: "fixture-runtime", expectedModel: nil, sendAdmission: { true })
            }
            defer { mutation.cancel() }

            try await reconnect(harness)
            let status = try await request(in: harness.replacement, frameIndex: 1)
            #expect(status.method == "command.status")
            let stableCommandID = try #require(status.params?["commandId"]?.stringValue)
            await harness.replacement.suspendSends()
            await harness.replacement.enqueue(successResponse(
                id: status.id,
                result: .object(["status": .string("missing")])
            ))
            try await harness.replacement.waitUntilSendInvoked(count: 3)
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
            await harness.replacement.releaseSend()
            #expect(await harness.socket.sentFrames().count == 1)
            #expect(await harness.replacement.sentFrames().count == 2)
            #expect(await harness.client.activeConnectionID() != nil)
            #expect(receiptEvents(harness) == [
                .begin(.receiptResolution),
                .end(.receiptResolution, .cancelled, .none),
            ])
            await harness.client.close()
        }
    }

    @Test("attention mutation carries absolute rendered completion revision")
    func attentionMutation() async throws {
        try await withTestWatchdog {
            let harness = try await makeHarness()
            let mutation = Task {
                try await harness.service.setAttention(
                    sessionID: "session-a",
                    unread: false,
                    throughCompletionRevision: 7
                )
            }
            let request = try await request(in: harness.socket, frameIndex: 1)
            #expect(request.method == "session.attention.set")
            #expect(request.params?["sessionId"] == .string("session-a"))
            #expect(request.params?["unread"] == .bool(false))
            #expect(request.params?["throughCompletionRevision"] == .number(7))
            try expectCommandID(request)
            await harness.socket.enqueue(successResponse(
                id: request.id,
                result: .object([
                    "completionRevision": .number(7),
                    "attentionRevision": .number(3),
                    "isUnread": .bool(false),
                ])
            ))
            let projection = try await valueOfOwnedTask(mutation)
            #expect(projection.completionRevision == 7)
            #expect(projection.attentionRevision == 3)
            #expect(!projection.isUnread)
            await harness.client.close()
        }
    }

    @Test("archive mutation carries the intent and keeps the Gateway's exact refusal")
    func archiveMutation() async throws {
        try await withTestWatchdog {
            let harness = try await makeHarness()
            var frameIndex = 1

            let archiving = Task {
                try await harness.service.setArchived(sessionID: "session-a", archived: true)
            }
            let archived: SessionArchiveState = try await complete(
                archiving,
                socket: harness.socket,
                frameIndex: &frameIndex,
                method: "session.archive.set",
                result: .object(["archived": .bool(true), "archivedAt": .string("2026-01-02T00:00:00Z")]),
                expectedParams: ["archived": .bool(true)]
            )
            #expect(archived.archived)
            #expect(archived.archivedAt == "2026-01-02T00:00:00Z")

            // Unarchive is the same command with the opposite intent, and its
            // response carries no archive timestamp.
            let unarchiving = Task {
                try await harness.service.setArchived(sessionID: "session-a", archived: false)
            }
            let unarchived: SessionArchiveState = try await complete(
                unarchiving,
                socket: harness.socket,
                frameIndex: &frameIndex,
                method: "session.archive.set",
                result: .object(["archived": .bool(false)]),
                expectedParams: ["archived": .bool(false)]
            )
            #expect(!unarchived.archived)
            #expect(unarchived.archivedAt == nil)

            // A running session refuses the archive. The refusal is the
            // Gateway's own wire shape: `session_operation_busy` is only the
            // internal diagnostic reason, so the caller sees a plain
            // non-retryable `busy`.
            let refused = Task {
                try await harness.service.setArchived(sessionID: "session-a", archived: true)
            }
            let refusal = try await request(in: harness.socket, frameIndex: frameIndex)
            frameIndex += 1
            await harness.socket.enqueue(try JSONEncoder.gateway.encode(JSONValue.object([
                "type": .string("response"),
                "id": .string(refusal.id),
                "ok": .bool(false),
                "error": .object([
                    "code": .string("busy"),
                    "message": .string("Stop the session before archiving it"),
                    "retryable": .bool(false),
                    "details": .null,
                ]),
            ])))
            do {
                _ = try await valueOfOwnedTask(refused)
                Issue.record("a busy archive unexpectedly succeeded")
            } catch let failure as GatewayFailure {
                #expect(failure.code == "busy")
                #expect(!failure.retryable)
            }
            await harness.client.close()
        }
    }

    @Test("OAuth deadline exhaustion preserves the original command for status-only reconciliation")
    func oauthReceiptDeadlineRetainsOriginalStatusOnlyCommand() async throws {
        try await withTestWatchdog {
            let clock = ReceiptRecoveryClockProbe()
            let harness = try await makeHarness(executorClock: clock.clock)
            let integrations = await IntegrationsRPCClient(request: { method, params in
                try await harness.client.requestValue(method, params)
            }, mutationExecutor: harness.executor)
            await harness.socket.failNextSend(GatewayFailure(code: "disconnected", message: "lost begin response", retryable: true, details: nil))
            let begin = Task { try await integrations.beginXOAuth(instanceID: "x-original", clientID: "fixture-client", redirectURI: "https://example.test/callback", policy: IntegrationPolicy(enabled: true, allowWrites: false, paidAccessApproved: true, paidBudgetCents: 100, recurringApproved: false)) }
            defer { begin.cancel() }
            try await reconnect(harness)
            let status = try await request(in: harness.replacement, frameIndex: 1)
            let command = try #require(status.params?["commandId"]?.stringValue)
            #expect(status.params?["method"] == .string("knowledge.x.oauth.begin"))
            clock.setElapsedTime(.seconds(100))
            await harness.replacement.enqueue(successResponse(id: status.id, result: .object(["status": .string("pending")])))
            do { _ = try await valueOfOwnedTask(begin); Issue.record("a pending receipt must exhaust honestly") }
            catch let failure as GatewayFailure {
                #expect(failure.code == "outcome_unknown" && !failure.retryable)
                #expect(failure.details?["commandId"] == .string(command))
                #expect(failure.details?["method"] == .string("knowledge.x.oauth.begin"))
            }
            let checking = Task { try await integrations.resumeXOAuthBegin(commandID: command) }
            defer { checking.cancel() }
            let resumed = try await request(in: harness.replacement, frameIndex: 2)
            #expect(resumed.method == "command.status")
            #expect(resumed.params?["commandId"] == .string(command))
            await harness.replacement.enqueue(successResponse(id: resumed.id, result: .object([
                "status": .string("completed"), "result": .object([
                    "operationId": .string("original-operation"), "instanceId": .string("x-original"),
                    "authorizationUrl": .string("https://twitter.com/i/oauth2/authorize?state=fixture"), "state": .string("fixture")])
            ])))
            let result = try await valueOfOwnedTask(checking)
            #expect(result.instanceId == "x-original" && result.operationId == "original-operation")
            #expect(await harness.replacement.sentFrames().count == 3, "hello and two status reads only")
            await harness.client.close()
        }
    }

    private struct Harness {
        let socket: ScriptedGatewaySocket
        let replacement: ScriptedGatewaySocket
        let successor: ScriptedGatewaySocket
        let lifecycle: GatewayLifecycleCoordinator
        let profile: GatewayProfile
        let client: GatewayClient
        let service: SessionMutationService
        let executor: ConfirmedMutationExecutor
        let signposts: RecordingPerformanceSignposts
    }

    private struct Request {
        let id: String
        let method: String
        let params: JSONValue?
    }

    private func makeHarness(executorClock: MonotonicClock = .continuous, lifecycleClock: MonotonicClock = .continuous, selectProfile: Bool = false) async throws -> Harness {
        let socket = ScriptedGatewaySocket()
        let replacement = ScriptedGatewaySocket()
        let successor = ScriptedGatewaySocket()
        let signposts = RecordingPerformanceSignposts()
        let client = GatewayClient(
            socketFactory: ScriptedGatewaySocketFactory(sockets: [socket, replacement, successor]).factory,
            performanceSignposts: signposts
        )
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        let store = AutomationFixtureProfileStore()
        let profiles = selectProfile ? GatewayProfileStore(metadata: store, tokens: store) : GatewayProfileStore(defaults: defaults)
        let lifecycle = GatewayLifecycleCoordinator(
            client: client,
            profiles: profiles,
            clock: lifecycleClock,
            reconnectDelayPolicy: .standard,
            uuidSource: .random,
            pairer: GatewayPairer(),
            pairingCommit: { _, _ in },
            profileTokenLookup: { _ in nil }
        )
        let executor = ConfirmedMutationExecutor(
            client: client,
            lifecycle: lifecycle,
            clock: executorClock,
            performanceSignposts: signposts
        )
        let service = SessionMutationService(
            client: client,
            executor: executor,
            uuidSource: .random
        )
        let profile = GatewayProfile(
            id: "machine", label: "Mac", host: "gateway.test", port: 9_847,
            machineId: "machine", deviceId: "device"
        )
        if selectProfile { try profiles.save(profile, token: "fixture-token") }
        await socket.enqueue(helloFrame())
        try await lifecycle.connectHosted(profile: profile, token: "token")
        signposts.reset()
        return Harness(
            socket: socket, replacement: replacement, successor: successor, lifecycle: lifecycle, profile: profile,
            client: client, service: service, executor: executor, signposts: signposts
        )
    }

    private func reconnect(_ harness: Harness) async throws {
        try await harness.socket.waitUntilClosed()
        var events = harness.client.events.makeAsyncIterator()
        let delivery = try #require(await events.next())
        #expect(delivery.event.topic == "transport.disconnected")
        await harness.lifecycle.noteDisconnected(connectionID: delivery.connectionID)
        await harness.replacement.enqueue(helloFrame())
        try await harness.lifecycle.connectHosted(profile: harness.profile, token: "token")
    }

    private nonisolated func receiptEvents(_ harness: Harness) -> [RecordingPerformanceSignposts.Event] {
        harness.signposts.events().filter { $0.operation == .receiptResolution }
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

    private func completeVoid<Value: Sendable>(
        _ task: Task<Value, Error>,
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
        Data(#"{"type":"hello","gatewayVersion":"1.0.0","piVersion":"1.0.0","protocolVersion":7,"minProtocolVersion":7,"machineId":"machine","machineName":"Mac","gatewayChannel":"stable","capabilities":["sessions.v1"]}"#.utf8)
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

/// Advance virtual deadline reads only after transport loss. This bounds the
/// known-bad busy loop without a wall-clock threshold or starving the test runner.
private final class ReceiptRecoveryClockProbe: Sendable {
    private struct State { var counting = false; var reads = 0; var elapsed: Duration?; let origin = ContinuousClock().now }
    private let state = Mutex(State())
    var clock: MonotonicClock {
        MonotonicClock(now: {
            self.state.withLock { state in
                if let elapsed = state.elapsed { return state.origin + elapsed }
                guard state.counting else { return ContinuousClock().now }
                state.reads += 1
                return state.origin + .seconds(state.reads)
            }
        }, sleep: { try await ContinuousClock().sleep(for: $0) }, gridOrigin: ContinuousClock().now)
    }
    func setElapsedTime(_ elapsed: Duration) { state.withLock { $0.elapsed = elapsed } }
    func startCounting() { state.withLock { $0.counting = true } }
    var readCount: Int { state.withLock { $0.reads } }
}

@MainActor
private final class ConfigurationAdmissionProbe { var value = true }
