import Foundation
import Synchronization
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

    @Test("a completed open after presentation revocation is compensated")
    func staleOpenIsCompensated() async throws {
        try await withHarness { harness in
            try installHostedTerminalSession(on: harness.model)
            let target = harness.model.beginTerminalPresentation(sessionID: "session")
            let intent = try #require(harness.model.beginTerminalIntent(for: target))
            let opening = Task {
                try await harness.model.openTerminal(intent: intent, columns: 80, rows: 24)
            }
            let open = try await request(in: harness.socket, frameIndex: 1)
            harness.model.closeTerminalPresentation(target)
            let replay = terminalReplayResult(chunks: [], terminalID: "opened-terminal")
            await harness.socket.enqueue(successResponse(
                id: open.id,
                result: .object([
                    "terminal": replay.objectValue!["terminal"]!,
                    "replay": replay,
                ])
            ))
            await expectCancellation(opening)

            let detach = try await request(in: harness.socket, frameIndex: 2)
            #expect(detach.method == "terminal.detach")
            #expect(detach.params?.objectValue?["terminalId"] == .string("opened-terminal"))
            await harness.socket.enqueue(successResponse(
                id: detach.id,
                result: .object(["detached": .bool(true)])
            ))
        }
    }

    @Test("events delivered before an open response join its admitted replay")
    func pendingOpenEventsAreQuarantined() async throws {
        try await withHarness { harness in
            try installHostedTerminalSession(on: harness.model)
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
            try installHostedTerminalSession(on: harness.model)
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

    @Test("a newer attachment cancels and joins an unsent matching detach")
    func newerAttachmentCancelsPendingDetach() async throws {
        try await withHarness { harness in
            let firstTarget = harness.model.beginTerminalPresentation(sessionID: "session")
            let firstIntent = try #require(harness.model.beginTerminalIntent(for: firstTarget))
            let firstAttach = Task {
                try await harness.model.attachTerminal("terminal", after: 0, intent: firstIntent)
            }
            let firstRequest = try await request(in: harness.socket, frameIndex: 1)
            await harness.socket.enqueue(successResponse(
                id: firstRequest.id,
                result: terminalReplayResult(sequence: 1, data: "one")
            ))
            _ = try await firstAttach.value

            await harness.socket.suspendSends()
            harness.model.closeTerminalPresentation(firstTarget)
            try await harness.socket.waitUntilSendInvoked(count: 3)

            let secondTarget = harness.model.beginTerminalPresentation(sessionID: "session")
            let secondIntent = try #require(harness.model.beginTerminalIntent(for: secondTarget))
            let secondAttach = Task {
                try await harness.model.attachTerminal("terminal", after: 1, intent: secondIntent)
            }
            try await harness.socket.waitUntilSendInvoked(count: 4)
            await harness.socket.releaseSend()

            let secondRequest = try await request(in: harness.socket, frameIndex: 2)
            #expect(secondRequest.method == "terminal.attach")
            #expect(secondRequest.params?.objectValue?["afterSequence"] == .number(1))
            await harness.socket.enqueue(successResponse(
                id: secondRequest.id,
                result: terminalReplayResult(sequence: 2, data: "two")
            ))
            _ = try await secondAttach.value
            #expect(await harness.socket.sentFrames().count == 3)
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

    @Test("terminal presentation lifecycle cancels a superseded read before connection work")
    func presentationLifecycleCancelsSupersededRead() async throws {
        try await withHarness { harness in
            try installHostedTerminalSession(on: harness.model)
            let controller = TerminalController()
            await harness.socket.suspendSends()
            controller.start(sessionID: "session", model: harness.model)
            try await harness.socket.waitUntilSendInvoked(count: 2)
            controller.show(terminalSummary(id: "terminal-b"), model: harness.model)
            try await harness.socket.waitUntilSendInvoked(count: 3)
            await harness.socket.releaseSend()

            let attach = try await request(in: harness.socket, frameIndex: 1)
            #expect(attach.method == "terminal.attach")
            #expect(attach.params?.objectValue?["terminalId"] == .string("terminal-b"))
            await harness.socket.enqueue(successResponse(
                id: attach.id,
                result: terminalReplayResult(chunks: [], terminalID: "terminal-b")
            ))
            try await eventually { controller.terminal?.id == "terminal-b" }
            #expect(await harness.socket.sentFrames().count == 2)
            controller.stop(model: harness.model)
        }
    }

    @Test("revoked terminal open never replays a confirmed-missing command")
    func revokedOpenDoesNotReplayMissingCommand() async throws {
        try await withHarness { harness in
            try installHostedTerminalSession(on: harness.model)
            let controller = TerminalController()
            controller.start(sessionID: "session", model: harness.model)
            let list = try await request(in: harness.socket, frameIndex: 1)
            await harness.socket.failNextSend(GatewayFailure(
                code: "disconnected",
                message: "synthetic",
                retryable: true,
                details: nil
            ))
            await harness.socket.enqueue(successResponse(
                id: list.id,
                result: .object(["terminals": .array([])])
            ))
            let status = try await request(in: harness.socket, frameIndex: 2)
            #expect(status.method == "command.status")
            #expect(status.params?.objectValue?["method"] == .string("terminal.open"))

            controller.show(terminalSummary(id: "terminal-b"), model: harness.model)
            await harness.socket.enqueue(successResponse(
                id: status.id,
                result: .object(["status": .string("missing")])
            ))
            let attach = try await request(in: harness.socket, frameIndex: 3)
            #expect(attach.method == "terminal.attach")
            #expect(attach.params?.objectValue?["terminalId"] == .string("terminal-b"))
            await harness.socket.enqueue(successResponse(
                id: attach.id,
                result: terminalReplayResult(chunks: [], terminalID: "terminal-b")
            ))
            try await eventually { controller.terminal?.id == "terminal-b" }

            let methods = try await harness.socket.sentFrames().dropFirst().map { data in
                try JSONDecoder.gateway.decode(JSONValue.self, from: data)
                    .objectValue?["method"]?.stringValue
            }
            #expect(!methods.compactMap { $0 }.contains("terminal.open"))
            controller.stop(model: harness.model)
        }
    }

    @Test("terminal presentation lifecycle preserves in-flight cleanup and coalesces navigation")
    func presentationLifecycleCoalescesNavigation() async throws {
        try await withHarness { harness in
            try installHostedTerminalSession(on: harness.model)
            let controller = TerminalController()
            let existing = terminalSummary(id: "terminal-a")
            controller.start(sessionID: "session", model: harness.model)

            let list = try await request(in: harness.socket, frameIndex: 1)
            #expect(list.method == "terminal.list")
            await harness.socket.enqueue(successResponse(
                id: list.id,
                result: .object(["terminals": try JSONValue.encode([existing])])
            ))
            let initialAttach = try await request(in: harness.socket, frameIndex: 2)
            #expect(initialAttach.method == "terminal.attach")
            await harness.socket.enqueue(successResponse(
                id: initialAttach.id,
                result: terminalReplayResult(chunks: [], terminalID: existing.id)
            ))
            try await eventually { controller.terminal?.id == existing.id }

            await harness.socket.suspendSends()
            controller.show(terminalSummary(id: "terminal-b"), model: harness.model)
            try await harness.socket.waitUntilSendInvoked(count: 5)
            controller.show(terminalSummary(id: "terminal-c"), model: harness.model)
            controller.show(terminalSummary(id: "terminal-d"), model: harness.model)
            #expect(await harness.socket.sentFrames().count == 3)
            await harness.socket.releaseSend()

            let firstWave = [
                try await request(in: harness.socket, frameIndex: 3),
                try await request(in: harness.socket, frameIndex: 4),
            ]
            for request in firstWave {
                switch request.method {
                case "terminal.detach":
                    #expect(request.params?.objectValue?["terminalId"] == .string(existing.id))
                    await harness.socket.enqueue(successResponse(
                        id: request.id,
                        result: .object(["detached": .bool(true)])
                    ))
                case "terminal.attach":
                    #expect(request.params?.objectValue?["terminalId"] == .string("terminal-b"))
                    await harness.socket.enqueue(successResponse(
                        id: request.id,
                        result: terminalReplayResult(chunks: [], terminalID: "terminal-b")
                    ))
                default:
                    Issue.record("unexpected request: \(request.method)")
                }
            }

            let secondWave = [
                try await request(in: harness.socket, frameIndex: 5),
                try await request(in: harness.socket, frameIndex: 6),
            ]
            for request in secondWave {
                switch request.method {
                case "terminal.detach":
                    #expect(request.params?.objectValue?["terminalId"] == .string("terminal-b"))
                    await harness.socket.enqueue(successResponse(
                        id: request.id,
                        result: .object(["detached": .bool(true)])
                    ))
                case "terminal.attach":
                    #expect(request.params?.objectValue?["terminalId"] == .string("terminal-d"))
                    await harness.socket.enqueue(successResponse(
                        id: request.id,
                        result: terminalReplayResult(chunks: [], terminalID: "terminal-d")
                    ))
                default:
                    Issue.record("unexpected request: \(request.method)")
                }
            }
            try await eventually { controller.terminal?.id == "terminal-d" }
            let sent = try await harness.socket.sentFrames().dropFirst().map { data in
                try JSONDecoder.gateway.decode(JSONValue.self, from: data)
            }
            let attachedIDs = sent.compactMap { frame -> String? in
                guard frame.objectValue?["method"] == .string("terminal.attach") else { return nil }
                return frame.objectValue?["params"]?.objectValue?["terminalId"]?.stringValue
            }
            #expect(attachedIDs == ["terminal-a", "terminal-b", "terminal-d"])
            controller.stop(model: harness.model)
        }
    }

    @Test("terminal action failures remain visible while the renderer stays installed")
    func terminalActionFailureIsVisible() async throws {
        try await withHarness { harness in
            try installHostedTerminalSession(on: harness.model)
            let controller = TerminalController()
            let existing = terminalSummary(id: "terminal")
            controller.start(sessionID: "session", model: harness.model)
            let list = try await request(in: harness.socket, frameIndex: 1)
            await harness.socket.enqueue(successResponse(
                id: list.id,
                result: .object(["terminals": try JSONValue.encode([existing])])
            ))
            let attach = try await request(in: harness.socket, frameIndex: 2)
            await harness.socket.enqueue(successResponse(
                id: attach.id,
                result: terminalReplayResult(chunks: [], terminalID: existing.id)
            ))
            try await eventually { controller.terminal?.id == existing.id }

            controller.terminate(model: harness.model)
            let terminate = try await request(in: harness.socket, frameIndex: 3)
            #expect(terminate.method == "terminal.terminate")
            await harness.socket.enqueue(failureResponse(
                id: terminate.id,
                failure: GatewayFailure(
                    code: "denied",
                    message: "Termination denied",
                    retryable: false,
                    details: nil
                )
            ))
            try await eventually { controller.actionError == "Termination denied" }
            #expect(controller.terminal?.id == existing.id)
            #expect(controller.connectionPhase == .connected)
            controller.clearActionError()
            #expect(controller.actionError == nil)
            controller.stop(model: harness.model)
        }
    }

    @Test("resize debounce is intent-keyed, bounded, coalesced, and revoked with presentation")
    func resizeDebounceOwnership() async throws {
        try await withHarness { harness in
            let target = harness.model.beginTerminalPresentation(sessionID: "session")
            let intent = try #require(harness.model.beginTerminalIntent(for: target))
            let first = Task {
                try await harness.model.resizeTerminal(
                    "terminal",
                    columns: 80,
                    rows: 24,
                    intent: intent
                )
            }
            try await harness.clock.waitUntilSleeping(count: 1)
            let second = Task {
                try await harness.model.resizeTerminal(
                    "terminal",
                    columns: 1_000,
                    rows: 1,
                    intent: intent
                )
            }
            do {
                try await first.value
                Issue.record("superseded resize unexpectedly completed")
            } catch {
                #expect(error is CancellationError)
            }
            try await harness.clock.waitUntilSleeping(count: 1)
            harness.clock.advance(by: .milliseconds(120))
            let resize = try await request(in: harness.socket, frameIndex: 1)
            #expect(resize.method == "terminal.resize")
            #expect(resize.params?.objectValue?["columns"] == .number(400))
            #expect(resize.params?.objectValue?["rows"] == .number(5))
            await harness.socket.enqueue(successResponse(
                id: resize.id,
                result: .object(["resized": .bool(true)])
            ))
            try await second.value

            let revoked = Task {
                try await harness.model.resizeTerminal(
                    "terminal",
                    columns: 100,
                    rows: 30,
                    intent: intent
                )
            }
            try await harness.clock.waitUntilSleeping(count: 1)
            harness.model.closeTerminalPresentation(target)
            do {
                try await revoked.value
                Issue.record("revoked resize unexpectedly completed")
            } catch {
                #expect(error is CancellationError)
            }
            harness.clock.advance(by: .seconds(1))
            #expect(await harness.socket.sentFrames().count == 2)
        }
    }

    @Test("caller cancellation distinguishes unsent resize from possibly-sent resize")
    func resizeCallerCancellation() async throws {
        try await withHarness { harness in
            let target = harness.model.beginTerminalPresentation(sessionID: "session")
            let intent = try #require(harness.model.beginTerminalIntent(for: target))
            let unsent = Task {
                try await harness.model.resizeTerminal(
                    "terminal",
                    columns: 80,
                    rows: 24,
                    intent: intent
                )
            }
            try await harness.clock.waitUntilSleeping(count: 1)
            unsent.cancel()
            do {
                try await unsent.value
                Issue.record("cancelled unsent resize unexpectedly completed")
            } catch {
                #expect(error is CancellationError)
            }
            harness.clock.advance(by: .seconds(1))
            #expect(await harness.socket.sentFrames().count == 1)

            await harness.socket.suspendSends()
            let dispatched = Task {
                try await harness.model.resizeTerminal(
                    "terminal",
                    columns: 100,
                    rows: 30,
                    intent: intent
                )
            }
            try await harness.clock.waitUntilSleeping(count: 1)
            harness.clock.advance(by: .milliseconds(120))
            try await harness.socket.waitUntilSendInvoked(count: 2)
            dispatched.cancel()
            do {
                try await dispatched.value
                Issue.record("cancelled possibly-sent resize unexpectedly completed")
            } catch let failure as GatewayFailure {
                #expect(failure.code == "outcome_unknown")
            } catch {
                Issue.record("unexpected error: \(error)")
            }
        }
    }

    @Test("in-flight resize supersession completes obsolete work silently")
    func inFlightResizeSupersession() async throws {
        try await withHarness { harness in
            let target = harness.model.beginTerminalPresentation(sessionID: "session")
            let intent = try #require(harness.model.beginTerminalIntent(for: target))
            await harness.socket.suspendSends()
            let first = Task {
                try await harness.model.resizeTerminal(
                    "terminal",
                    columns: 80,
                    rows: 24,
                    intent: intent
                )
            }
            try await harness.clock.waitUntilSleeping(count: 1)
            harness.clock.advance(by: .milliseconds(120))
            try await harness.socket.waitUntilSendInvoked(count: 2)

            let second = Task {
                try await harness.model.resizeTerminal(
                    "terminal",
                    columns: 100,
                    rows: 30,
                    intent: intent
                )
            }
            try await harness.clock.waitUntilSleeping(count: 1)
            harness.clock.advance(by: .milliseconds(120))
            try await harness.socket.waitUntilSendInvoked(count: 3)
            await harness.socket.releaseSend()

            let requests = [
                try await request(in: harness.socket, frameIndex: 1),
                try await request(in: harness.socket, frameIndex: 2),
            ]
            for request in requests {
                await harness.socket.enqueue(successResponse(
                    id: request.id,
                    result: .object(["resized": .bool(true)])
                ))
            }
            do {
                try await first.value
                Issue.record("obsolete in-flight resize unexpectedly remained current")
            } catch {
                #expect(error is CancellationError)
            }
            try await second.value
        }
    }

    @Test("distinct terminal presentations debounce resize independently")
    func independentResizeDebounce() async throws {
        try await withHarness { harness in
            let firstTarget = harness.model.beginTerminalPresentation(sessionID: "session")
            let firstIntent = try #require(harness.model.beginTerminalIntent(for: firstTarget))
            let secondTarget = harness.model.beginTerminalPresentation(sessionID: "session")
            let secondIntent = try #require(harness.model.beginTerminalIntent(for: secondTarget))
            let first = Task {
                try await harness.model.resizeTerminal(
                    "terminal-1",
                    columns: 80,
                    rows: 24,
                    intent: firstIntent
                )
            }
            let second = Task {
                try await harness.model.resizeTerminal(
                    "terminal-2",
                    columns: 100,
                    rows: 30,
                    intent: secondIntent
                )
            }
            try await harness.clock.waitUntilSleeping(count: 2)
            harness.clock.advance(by: .milliseconds(120))
            let requests = [
                try await request(in: harness.socket, frameIndex: 1),
                try await request(in: harness.socket, frameIndex: 2),
            ]
            #expect(Set(requests.compactMap { $0.params?.objectValue?["terminalId"]?.stringValue }) == [
                "terminal-1", "terminal-2",
            ])
            for request in requests {
                await harness.socket.enqueue(successResponse(
                    id: request.id,
                    result: .object(["resized": .bool(true)])
                ))
            }
            try await first.value
            try await second.value
        }
    }

    @Test("terminal open requires the exact installed session subscription")
    func openRequiresSubscription() async throws {
        try await withHarness { harness in
            let target = harness.model.beginTerminalPresentation(sessionID: "session")
            let intent = try #require(harness.model.beginTerminalIntent(for: target))
            do {
                _ = try await harness.model.openTerminal(intent: intent, columns: 80, rows: 24)
                Issue.record("terminal opened without an installed session subscription")
            } catch {
                #expect(error is CancellationError)
            }
            #expect(await harness.socket.sentFrames().count == 1)
        }
    }

    @Test("malformed terminal inventory cannot partially replace prior reducer state")
    func malformedInventoryPublicationIsAtomic() async throws {
        try await withHarness { harness in
            try installHostedTerminalSession(on: harness.model)
            let target = harness.model.beginTerminalPresentation(sessionID: "session")
            let intent = try #require(harness.model.beginTerminalIntent(for: target))
            let exited = TerminalSummary(
                id: "terminal",
                sessionId: "session",
                cwd: "/workspace",
                createdAt: "2026-01-01T00:00:00Z",
                exitedAt: "2026-01-01T00:01:00Z",
                exitCode: 0,
                sequence: 4
            )

            let firstListing = Task { try await harness.model.listTerminals(intent: intent) }
            let first = try await request(in: harness.socket, frameIndex: 1)
            await harness.socket.enqueue(successResponse(
                id: first.id,
                result: .object(["terminals": try JSONValue.encode([exited])])
            ))
            #expect(try await firstListing.value == [exited])
            #expect(harness.model.terminalHasExited("terminal"))

            let malformed = TerminalSummary(
                id: "terminal",
                sessionId: "session",
                cwd: "/workspace",
                createdAt: "not-a-date",
                exitedAt: nil,
                exitCode: nil,
                sequence: 0
            )
            let secondListing = Task { try await harness.model.listTerminals(intent: intent) }
            let second = try await request(in: harness.socket, frameIndex: 2)
            await harness.socket.enqueue(successResponse(
                id: second.id,
                result: .object(["terminals": try JSONValue.encode([malformed])])
            ))
            do {
                _ = try await secondListing.value
                Issue.record("malformed terminal inventory unexpectedly installed")
            } catch let failure as GatewayFailure {
                #expect(failure.code == "invalid_response")
            }
            #expect(harness.model.terminalHasExited("terminal"))
        }
    }

    @Test("terminal list and command façades preserve exact wire contracts")
    func terminalWireContracts() async throws {
        try await withHarness { harness in
            let snapshot = try SessionScenarioBuilder(seed: 7_301).openingTail(targetEncodedBytes: 32_000)
            harness.model.installHostedSubscribedSnapshot(snapshot)
            let target = harness.model.beginTerminalPresentation(sessionID: snapshot.sessionId)
            let intent = try #require(harness.model.beginTerminalIntent(for: target))

            let listing = Task { try await harness.model.listTerminals(intent: intent) }
            let list = try await request(in: harness.socket, frameIndex: 1)
            #expect(list.method == "terminal.list")
            #expect(list.params?.objectValue?["sessionId"] == .string(snapshot.sessionId))
            let summary = TerminalSummary(
                id: "terminal",
                sessionId: snapshot.sessionId,
                cwd: "/workspace",
                createdAt: "2026-01-01T00:00:00Z",
                exitedAt: nil,
                exitCode: nil,
                sequence: 0
            )
            await harness.socket.enqueue(successResponse(
                id: list.id,
                result: .object(["terminals": try JSONValue.encode([summary])])
            ))
            #expect(try await listing.value == [summary])

            let writing = Task {
                try await harness.model.writeTerminal("terminal", data: "hello", intent: intent)
            }
            let write = try await request(in: harness.socket, frameIndex: 2)
            #expect(write.method == "terminal.write")
            #expect(write.params?.objectValue?["terminalId"] == .string("terminal"))
            #expect(write.params?.objectValue?["data"] == .string("hello"))
            #expect(write.params?.objectValue?["writeId"] == write.params?.objectValue?["commandId"])
            await harness.socket.enqueue(successResponse(
                id: write.id,
                result: .object(["written": .bool(true)])
            ))
            try await writing.value

            let resizing = Task {
                try await harness.model.resizeTerminal(
                    "terminal",
                    columns: 120,
                    rows: 40,
                    intent: intent
                )
            }
            try await harness.clock.waitUntilSleeping(count: 1)
            harness.clock.advance(by: .milliseconds(119))
            #expect(await harness.socket.sentFrames().count == 3)
            harness.clock.advance(by: .milliseconds(1))
            let resize = try await request(in: harness.socket, frameIndex: 3)
            #expect(resize.method == "terminal.resize")
            #expect(resize.params?.objectValue?["columns"] == .number(120))
            #expect(resize.params?.objectValue?["rows"] == .number(40))
            await harness.socket.enqueue(successResponse(
                id: resize.id,
                result: .object(["resized": .bool(true)])
            ))
            try await resizing.value

            let terminating = Task {
                try await harness.model.terminateTerminal("terminal", intent: intent)
            }
            let terminate = try await request(in: harness.socket, frameIndex: 4)
            #expect(terminate.method == "terminal.terminate")
            #expect(terminate.params?.objectValue?["terminalId"] == .string("terminal"))
            await harness.socket.enqueue(successResponse(
                id: terminate.id,
                result: .object(["terminated": .bool(true)])
            ))
            try await terminating.value
        }
    }

    @Test("terminal owner mutations invalidate the AppModel replay façade")
    func terminalFacadeObservation() async throws {
        try await withHarness { harness in
            let target = harness.model.beginTerminalPresentation(sessionID: "session")
            let intent = try #require(harness.model.beginTerminalIntent(for: target))
            let attaching = Task {
                try await harness.model.attachTerminal("terminal", after: 0, intent: intent)
            }
            let attach = try await request(in: harness.socket, frameIndex: 1)
            await harness.socket.enqueue(successResponse(
                id: attach.id,
                result: terminalReplayResult(sequence: 1, data: "one")
            ))
            _ = try await attaching.value

            let changed = Mutex(false)
            withObservationTracking {
                _ = harness.model.terminalReplay(for: "terminal")
            } onChange: {
                changed.withLock { $0 = true }
            }
            await harness.model.handle(outputEvent(sequence: 2, data: "two"))
            #expect(changed.withLock { $0 })
            #expect(harness.model.terminalReplay(for: "terminal").chunks.last?.data == "two")
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

    private func installHostedTerminalSession(on model: AppModel) throws {
        var snapshot = try SessionScenarioBuilder(seed: 7_300).openingTail(targetEncodedBytes: 32_000)
        snapshot.sessionId = "session"
        model.installHostedSubscribedSnapshot(snapshot)
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
        let clock: ManualClock
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
        let clock = ManualClock()
        let model = AppModel(
            client: client,
            cache: SnapshotCache(
                root: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            ),
            clock: clock.clock
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
        return Harness(socket: socket, client: client, model: model, clock: clock)
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

    private func terminalSummary(id: String, sequence: Int = 0) -> TerminalSummary {
        TerminalSummary(
            id: id,
            sessionId: "session",
            cwd: "/workspace",
            createdAt: "2026-01-01T00:00:00Z",
            exitedAt: nil,
            exitCode: nil,
            sequence: sequence
        )
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

    private func failureResponse(id: String, failure: GatewayFailure) -> Data {
        try! JSONEncoder.gateway.encode(JSONValue.object([
            "type": .string("response"),
            "id": .string(id),
            "ok": .bool(false),
            "error": try! JSONValue.encode(failure),
        ]))
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
