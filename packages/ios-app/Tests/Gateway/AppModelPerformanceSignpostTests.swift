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
            #expect(await MainActor.run { harness.model.selectedSnapshot } == nil)
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
            await MainActor.run { harness.model.invalidateHostedPendingPresentation() }
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
            #expect(await MainActor.run { harness.model.selectedSnapshot } == nil)
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
            await MainActor.run { harness.model.installHostedSnapshotWithoutPresentation(cached) }
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
                harness.model.selectedSnapshot?.eventSequence
            } == cached.eventSequence)
            #expect(await MainActor.run {
                harness.model.authoritativeSnapshot(for: cached.sessionId)
            } == nil)
            await harness.client.close()
        }
    }

    @Test("mounted live snapshots require exact runtime and next cursor")
    func mountedLiveSnapshotAdmission() async throws {
        try await withTestWatchdog {
            let harness = try await makeHarness()
            let snapshot = try SessionScenarioBuilder(seed: 46).openingTail(targetEncodedBytes: 8_192)
            let responder = Task {
                try await respondToSessionSynchronization(
                    socket: harness.socket,
                    firstFrameIndex: 1,
                    snapshot: snapshot
                )
                try await respondToPresentationRefreshes(socket: harness.socket, firstFrameIndex: 3)
            }
            defer { responder.cancel() }

            let presentationGeneration = try await harness.model.openSessionPresentation(snapshot.sessionId)
            try await valueOfOwnedTask(responder)

            var duplicate = snapshot
            duplicate.phase = .running
            duplicate.name = "same-cursor replacement"
            await harness.model.handle(GatewayEvent(
                type: "event",
                topic: "session.snapshot",
                sessionId: snapshot.sessionId,
                payload: try JSONValue.encode(duplicate)
            ))
            let afterDuplicate = await MainActor.run {
                harness.model.authoritativeSnapshot(for: snapshot.sessionId)
            }
            #expect(afterDuplicate == snapshot)

            var next = snapshot
            next.eventSequence += 1
            next.phase = .running
            await harness.model.handle(GatewayEvent(
                type: "event",
                topic: "session.snapshot",
                sessionId: snapshot.sessionId,
                payload: try JSONValue.encode(next)
            ))
            let afterNext = await MainActor.run {
                harness.model.authoritativeSnapshot(for: snapshot.sessionId)
            }
            #expect(afterNext?.eventSequence == next.eventSequence)
            #expect(afterNext?.phase == .running)

            let target = AppModel.SessionPresentationTarget(
                sessionID: snapshot.sessionId,
                generation: presentationGeneration
            )
            await MainActor.run { harness.model.revokePresentationIntake(target) }
            var afterRevocation = next
            afterRevocation.eventSequence += 1
            afterRevocation.name = "revoked presentation"
            await harness.model.handle(GatewayEvent(
                type: "event",
                topic: "session.snapshot",
                sessionId: snapshot.sessionId,
                payload: try JSONValue.encode(afterRevocation)
            ))
            let rejectedAfterRevocation = await MainActor.run {
                harness.model.selectedSnapshot
            }
            #expect(rejectedAfterRevocation?.eventSequence == next.eventSequence)
            #expect(rejectedAfterRevocation?.name != "revoked presentation")
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
                harness.model.replaceHostedAuthoritativeSnapshot(expanded)
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
                harness.model.selectedSnapshot?.transcript.count
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

    @Test("post-mount profile rejection revokes composer, presentation, and share intake before returning")
    func rejectedMountedOpenClosesAuthority() async throws {
        try await withTestWatchdog {
            let harness = try await makeHarness()
            let snapshot = try SessionScenarioBuilder(seed: 144).openingTail(targetEncodedBytes: 4_096)
            await MainActor.run {
                harness.model.hostedSessionOpenAdmissionOverride = false
            }
            let opening = Task { try await harness.model.openSessionPresentation(snapshot.sessionId) }
            let responder = Task {
                try await respondToSessionSynchronization(
                    socket: harness.socket,
                    firstFrameIndex: 1,
                    snapshot: snapshot
                )
                try await respondToRejectedOpenCleanup(socket: harness.socket, firstFrameIndex: 3)
            }
            defer {
                opening.cancel()
                responder.cancel()
            }

            await #expect(throws: CancellationError.self) {
                try await valueOfOwnedTask(opening)
            }
            try await valueOfOwnedTask(responder)
            let rejectedTarget = AppModel.SessionPresentationTarget(
                sessionID: snapshot.sessionId,
                generation: 1
            )
            #expect(await MainActor.run { harness.model.mountedPresentationTarget } == nil)
            #expect(await MainActor.run { !harness.model.ownsPresentation(rejectedTarget) })
            #expect(await MainActor.run { !harness.model.composerDrafts.admits(rejectedTarget) })
            await #expect(throws: CancellationError.self) {
                try await harness.model.sendSharedContent("must remain pending", target: rejectedTarget)
            }
            await harness.client.close()
        }
    }

    @Test("receipt interval starts only after an uncertain mutation response")
    func receiptResolution() async throws {
        try await withTestWatchdog {
            let harness = try await makeHarness()
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
            let refreshing = Task { await harness.model.refreshAll() }
            defer { refreshing.cancel() }

            var expected = Set(["session.list", "provider.list", "model.list", "settings.get", "device.list"])
            for index in 1...5 {
                let next = try await request(in: harness.socket, frameIndex: index)
                #expect(expected.remove(next.method) != nil)
                let result: JSONValue
                switch next.method {
                case "session.list": result = .object([
                    "sessions": .array([]),
                    "nextCursor": .null,
                    "listRevision": .number(1),
                ])
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

    @Test("create returns its owned route without waiting for a catalog projection or opening implicitly")
    func createRouteIdentity() async throws {
        try await withTestWatchdog {
            let harness = try await makeHarness()
            let creating = Task { try await harness.model.createSession(cwd: "/workspace") }
            defer { creating.cancel() }

            let mutation = try await request(in: harness.socket, frameIndex: 1)
            #expect(mutation.method == "session.create")
            await harness.socket.enqueue(successResponse(
                id: mutation.id,
                result: .object(["sessionId": .string("created-route")])
            ))

            let route = try await valueOfOwnedTask(creating)
            #expect(route.sessionID == "created-route")
            #expect(await MainActor.run { harness.model.ownsNavigationRoute(route) })
            #expect(await harness.socket.sentFrames().count == 2)
            let selectedAfterCreate = await MainActor.run { harness.model.selectedSessionID }
            #expect(selectedAfterCreate == nil)

            await harness.model.handle(GatewayEvent(
                type: "event",
                topic: "session.listChanged",
                sessionId: nil,
                payload: .object([:])
            ))
            let convergence = Task { await harness.model.refreshSessions() }
            let refresh = try await request(in: harness.socket, frameIndex: 2)
            #expect(refresh.method == "session.list")
            await harness.socket.enqueue(successResponse(
                id: refresh.id,
                result: .object([
                    "sessions": .array([.object([
                        "id": .string("created-route"),
                        "cwd": .string("/workspace"),
                        "kind": .string("user"),
                        "createdAt": .string("2026-01-01T00:00:00Z"),
                        "updatedAt": .string("2026-01-01T00:00:00Z"),
                        "messageCount": .number(0),
                        "firstMessage": .string(""),
                        "phase": .string("idle"),
                    ])]),
                    "nextCursor": .null,
                    "listRevision": .number(1),
                ])
            ))
            #expect(await convergence.value == .published)
            #expect(await MainActor.run { harness.model.visibleSessions.map(\.id) } == ["created-route"])
            await harness.client.close()
        }
    }

    @Test("fork returns navigation identity without replacing dashboard selection")
    func forkRouteIdentity() async throws {
        try await withTestWatchdog {
            let harness = try await makeHarness()
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
            #expect(selectedAfterFork == nil)
            await harness.client.close()
        }
    }

    @Test("targeted prompt removes attachments only after confirmed success")
    func promptAttachmentOrdering() async throws {
        try await withTestWatchdog {
            let harness = try await makeHarness()
            let snapshot = try SessionScenarioBuilder(seed: 58).openingTail(targetEncodedBytes: 4_096)
            let target = try #require(await MainActor.run {
                harness.model.installHostedSubscribedSnapshot(snapshot, token: "prompt-token")
                return harness.model.mountedPresentationTarget
            })
            let attachments = [
                PendingAttachment(
                    id: "upload-a", name: "a.txt", mimeType: "text/plain",
                    size: 3, previewData: nil
                ),
                PendingAttachment(
                    id: "upload-b", name: "b.txt", mimeType: "text/plain",
                    size: 4, previewData: nil
                ),
            ]
            await MainActor.run {
                for attachment in attachments {
                    harness.model.composerDrafts.installHostedAttachment(attachment, target: target)
                }
            }

            let failing = Task {
                let scope = await MainActor.run {
                    harness.model.composerDrafts.prepareDraft(
                        profileID: "machine", sessionID: target.sessionID, initialText: "first"
                    )
                }
                await MainActor.run { harness.model.composerDrafts.setText("first", for: scope) }
                try await harness.model.sendComposer(target: target)
            }
            defer { failing.cancel() }
            let failedPrompt = try await request(in: harness.socket, frameIndex: 1)
            #expect(failedPrompt.method == "session.prompt")
            #expect(failedPrompt.params?.objectValue?["uploadIds"] == .array([
                .string("upload-a"), .string("upload-b"),
            ]))
            #expect(await MainActor.run {
                harness.model.composerDrafts.pendingAttachments(for: target)
            } == attachments)
            await harness.socket.enqueue(errorResponse(
                id: failedPrompt.id,
                code: "synthetic_prompt_failure",
                retryable: false
            ))
            do {
                try await valueOfOwnedTask(failing)
                Issue.record("failed prompt unexpectedly succeeded")
            } catch let failure as GatewayFailure {
                #expect(failure.code == "synthetic_prompt_failure")
            }
            #expect(await MainActor.run {
                harness.model.composerDrafts.pendingAttachments(for: target)
            } == attachments)

            let succeeding = Task {
                let scope = await MainActor.run {
                    harness.model.composerDrafts.prepareDraft(
                        profileID: "machine", sessionID: target.sessionID, initialText: "second"
                    )
                }
                await MainActor.run { harness.model.composerDrafts.setText("second", for: scope) }
                try await harness.model.sendComposer(target: target)
            }
            defer { succeeding.cancel() }
            let confirmedPrompt = try await request(in: harness.socket, frameIndex: 2)
            #expect(confirmedPrompt.method == "session.prompt")
            #expect(await MainActor.run {
                harness.model.composerDrafts.pendingAttachments(for: target)
            } == attachments)
            await harness.socket.enqueue(successResponse(
                id: confirmedPrompt.id,
                result: .object(["operationId": .string("operation")])
            ))
            try await valueOfOwnedTask(succeeding)
            #expect(await MainActor.run {
                harness.model.composerDrafts.pendingAttachments(for: target).isEmpty
            })

            await MainActor.run {
                harness.model.lastError = nil
                harness.model.presentComposerActionError(
                    GatewayFailure(
                        code: "current",
                        message: "current composer failure",
                        retryable: false,
                        details: nil
                    ),
                    target: target
                )
            }
            #expect(await MainActor.run { harness.model.lastError } == "current composer failure")
            await MainActor.run {
                harness.model.lastError = nil
                harness.model.revokePresentationIntake(target)
                harness.model.presentComposerActionError(
                    GatewayFailure(
                        code: "stale",
                        message: "stale composer failure",
                        retryable: false,
                        details: nil
                    ),
                    target: target
                )
            }
            #expect(await MainActor.run { harness.model.lastError } == nil)
            await harness.client.close()
        }
    }

    @Test("direct share prompt excludes composer attachments and leaves them staged after confirmation")
    func directShareExcludesComposerAttachments() async throws {
        try await withTestWatchdog {
            let harness = try await makeHarness()
            let snapshot = try SessionScenarioBuilder(seed: 158).openingTail(targetEncodedBytes: 4_096)
            let target = try #require(await MainActor.run {
                harness.model.installHostedSubscribedSnapshot(snapshot, token: "share-token")
                return harness.model.mountedPresentationTarget
            })
            let attachment = PendingAttachment(
                id: "composer-only", name: "draft.txt", mimeType: "text/plain",
                size: 5, previewData: nil
            )
            await MainActor.run {
                harness.model.composerDrafts.installHostedAttachment(attachment, target: target)
            }

            let sending = Task {
                try await harness.model.sendSharedContent("shared prompt", target: target)
            }
            let prompt = try await request(in: harness.socket, frameIndex: 1)
            #expect(prompt.method == "session.prompt")
            #expect(prompt.params?.objectValue?["text"] == .string("shared prompt"))
            #expect(prompt.params?.objectValue?["uploadIds"] == .array([]))
            #expect(await MainActor.run {
                harness.model.composerDrafts.pendingAttachments(for: target)
            } == [attachment])
            await harness.socket.enqueue(successResponse(
                id: prompt.id,
                result: .object(["operationId": .string("share-operation")])
            ))
            try await valueOfOwnedTask(sending)
            #expect(await MainActor.run {
                harness.model.composerDrafts.pendingAttachments(for: target)
            } == [attachment])
            await harness.client.close()
        }
    }

    @Test("queue projection clears only after mutation confirmation")
    func clearQueueOrdering() async throws {
        try await withTestWatchdog {
            let harness = try await makeHarness()
            var snapshot = try SessionScenarioBuilder(seed: 59).openingTail(targetEncodedBytes: 4_096)
            snapshot.queued = .init(steering: ["steer"], followUp: ["follow"])
            let sessionID = snapshot.sessionId
            let expectedQueue = snapshot.queued
            await MainActor.run {
                harness.model.installHostedSubscribedSnapshot(snapshot, token: "queue-token")
            }

            let clearing = Task { try await harness.model.clearQueue(sessionID: sessionID) }
            defer { clearing.cancel() }
            let mutation = try await request(in: harness.socket, frameIndex: 1)
            #expect(mutation.method == "session.clearQueue")
            #expect(await MainActor.run {
                harness.model.authoritativeSnapshot(for: sessionID)?.queued
            } == expectedQueue)
            await harness.socket.enqueue(successResponse(
                id: mutation.id,
                result: .object([
                    "steering": .array([.string("steer")]),
                    "followUp": .array([.string("follow")]),
                ])
            ))

            #expect(try await valueOfOwnedTask(clearing) == expectedQueue)
            #expect(await MainActor.run {
                harness.model.authoritativeSnapshot(for: sessionID)?.queued
            } == .init(steering: [], followUp: []))
            await harness.client.close()
        }
    }

    @Test("stale navigation cannot publish editor text and reloads the owned tree")
    func staleNavigateEditorAdmission() async throws {
        try await withTestWatchdog {
            let harness = try await makeHarness()
            let snapshot = try SessionScenarioBuilder(seed: 60).openingTail(targetEncodedBytes: 4_096)
            let oldTarget = try #require(await MainActor.run {
                harness.model.installHostedSubscribedSnapshot(snapshot, token: "old-token")
                return harness.model.mountedPresentationTarget
            })

            let navigating = Task {
                try await harness.model.navigate(
                    sessionID: snapshot.sessionId,
                    entryID: "entry",
                    summarize: false
                )
            }
            defer { navigating.cancel() }
            let mutation = try await request(in: harness.socket, frameIndex: 1)
            #expect(mutation.method == "session.navigate")

            let newTarget = try #require(await MainActor.run {
                harness.model.installHostedSubscribedSnapshot(snapshot, token: "new-token")
                return harness.model.mountedPresentationTarget
            })
            #expect(newTarget != oldTarget)
            await harness.socket.enqueue(successResponse(
                id: mutation.id,
                result: .object(["editorText": .string("stale editor text")])
            ))

            let treeRequest = try await request(in: harness.socket, frameIndex: 2)
            #expect(treeRequest.method == "session.tree")
            #expect(treeRequest.params?.objectValue?["sessionId"] == .string(snapshot.sessionId))
            let node = SessionTreeNode(
                id: "owned-entry", parentId: nil, timestamp: "2026-01-01T00:00:00Z",
                kind: "message", label: nil, preview: "Owned", role: .user,
                depth: 0, childCount: 0, isCurrentPath: true
            )
            await harness.socket.enqueue(successResponse(
                id: treeRequest.id,
                result: try JSONValue.encode([node])
            ))

            #expect(try await valueOfOwnedTask(navigating) == "stale editor text")
            #expect(await MainActor.run {
                harness.model.composerDrafts.editorRequest(for: oldTarget)
            } == nil)
            #expect(await MainActor.run {
                harness.model.composerDrafts.editorRequest(for: newTarget)
            } == nil)
            #expect(await MainActor.run { harness.model.sessionTree } == [node])
            await harness.client.close()
        }
    }

    @Test("label confirmation precedes the owned tree reload")
    func labelTreeReloadOrdering() async throws {
        try await withTestWatchdog {
            let harness = try await makeHarness()
            let snapshot = try SessionScenarioBuilder(seed: 61).openingTail(targetEncodedBytes: 4_096)
            await MainActor.run {
                harness.model.installHostedSubscribedSnapshot(snapshot, token: "label-token")
            }
            let oldNode = SessionTreeNode(
                id: "old", parentId: nil, timestamp: "2026-01-01T00:00:00Z",
                kind: "message", label: nil, preview: "Old", role: .user,
                depth: 0, childCount: 0, isCurrentPath: true
            )
            await MainActor.run {
                harness.model.installHostedSecondaryProjection(
                    context: nil,
                    tree: [oldNode],
                    resources: nil
                )
            }

            let labeling = Task {
                try await harness.model.setLabel(
                    sessionID: snapshot.sessionId,
                    entryID: "old",
                    label: "checkpoint"
                )
            }
            defer { labeling.cancel() }
            let mutation = try await request(in: harness.socket, frameIndex: 1)
            #expect(mutation.method == "session.label")
            #expect(await harness.socket.sentFrames().count == 2)
            #expect(await MainActor.run { harness.model.sessionTree } == [oldNode])
            await harness.socket.enqueue(successResponse(
                id: mutation.id,
                result: .object(["updated": .bool(true)])
            ))

            let treeRequest = try await request(in: harness.socket, frameIndex: 2)
            #expect(treeRequest.method == "session.tree")
            #expect(await MainActor.run { harness.model.sessionTree } == [oldNode])
            let newNode = SessionTreeNode(
                id: "new", parentId: "old", timestamp: "2026-01-01T00:00:01Z",
                kind: "message", label: "checkpoint", preview: "New", role: .assistant,
                depth: 1, childCount: 0, isCurrentPath: true
            )
            await harness.socket.enqueue(successResponse(
                id: treeRequest.id,
                result: try JSONValue.encode([newNode])
            ))

            try await valueOfOwnedTask(labeling)
            #expect(await MainActor.run { harness.model.sessionTree } == [newNode])
            await harness.client.close()
        }
    }

    @Test("delete closes subscription before command and preserves projection on failure")
    func deleteFailureOrdering() async throws {
        try await withTestWatchdog {
            let harness = try await makeHarness()
            let snapshot = try SessionScenarioBuilder(seed: 57).openingTail(targetEncodedBytes: 4_096)
            await MainActor.run {
                harness.model.installHostedSubscribedSnapshot(snapshot, token: "installed-token")
            }
            let deleting = Task { try await harness.model.deleteSession(snapshot.sessionId) }
            defer { deleting.cancel() }

            let close = try await request(in: harness.socket, frameIndex: 1)
            #expect(close.method == "session.close")
            #expect(close.params?.objectValue?["subscriptionToken"] == .string("installed-token"))
            await harness.socket.enqueue(successResponse(
                id: close.id,
                result: .object(["closed": .bool(true)])
            ))

            let mutation = try await request(in: harness.socket, frameIndex: 2)
            #expect(mutation.method == "session.delete")
            #expect(mutation.params?.objectValue?["sessionId"] == .string(snapshot.sessionId))
            await harness.socket.enqueue(errorResponse(
                id: mutation.id,
                code: "synthetic_delete_failure",
                retryable: false
            ))

            do {
                try await valueOfOwnedTask(deleting)
                Issue.record("failed delete unexpectedly succeeded")
            } catch let failure as GatewayFailure {
                #expect(failure.code == "synthetic_delete_failure")
            }
            #expect(await MainActor.run {
                harness.model.authoritativeSnapshot(for: snapshot.sessionId)?.sessionId
            } == snapshot.sessionId)
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

            let presentation = await MainActor.run {
                harness.model.beginTerminalPresentation(sessionID: terminal.sessionId)
            }
            let intent = try #require(await MainActor.run {
                harness.model.beginTerminalIntent(for: presentation)
            })
            _ = try await harness.model.attachTerminal(terminal.id, after: 0, intent: intent)
            let appendedReplay = await MainActor.run {
                harness.model.terminalReplay(for: terminal.id)
            }
            #expect(appendedReplay.chunks == Array(chunks.prefix(2)))
            #expect(appendedReplay.revision == 0)
            _ = try await harness.model.attachTerminal(terminal.id, after: 2, intent: intent)
            try await valueOfOwnedTask(responder)
            let resetReplay = await MainActor.run {
                harness.model.terminalReplay(for: terminal.id)
            }
            #expect(resetReplay.chunks == Array(resetChunks.prefix(1)))
            #expect(resetReplay.revision == 1)
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
        signposts.reset()
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

    private func respondToRejectedOpenCleanup(
        socket: ScriptedGatewaySocket,
        firstFrameIndex: Int
    ) async throws {
        var index = firstFrameIndex
        while true {
            let next = try await request(in: socket, frameIndex: index)
            index += 1
            let result: JSONValue
            switch next.method {
            case "provider.list":
                result = .object(["providers": .array([])])
            case "model.list":
                result = .object(["models": .array([]), "nextCursor": .null])
            case "session.commands":
                result = .object(["commands": .array([])])
            case "session.close":
                await socket.enqueue(successResponse(
                    id: next.id,
                    result: .object(["closed": .bool(true)])
                ))
                return
            default:
                Issue.record("unexpected rejected-open cleanup request: \(next.method)")
                return
            }
            await socket.enqueue(successResponse(id: next.id, result: result))
        }
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
