import Foundation
import Observation
import Testing
@testable import TronMobileCore
@testable import TronMobile

@MainActor
@Suite("Dashboard catalog synchronization", .serialized)
struct AppModelCatalogSyncTests {
    @Test("catalog retries autonomously past the warning threshold on its current connection")
    func catalogFailureRetriesWithoutInvalidation() async throws {
        let clock = ManualClock()
        let retryPolicy = ReconnectDelayPolicy(nextUnitInterval: { 0.5 })
        try await withHarness(manualClock: clock, reconnectDelayPolicy: retryPolicy) { harness in
            let loading = Task { await harness.model.refreshSessions() }
            for index in 0..<4 {
                let request = try await request(harness.socket, index: index + 1)
                await harness.socket.enqueue(errorResponse(id: request.id, code: "invalid_dashboard_catalog"))
                if index == 0 { #expect(await loading.value == .retained) }
                #expect(await harness.client.activeConnectionID() != nil)
                let delay = retryPolicy.delay(forFailureAttempt: index + 1)
                try await clock.waitUntilSleeping(count: 1, duration: delay)
                if index == 2 {
                    #expect(harness.model.visibleNotices.contains { $0.replacement?.key == .sessionCatalogCatchUp })
                }
                clock.advance(by: delay)
            }
            let connection = await harness.client.activeConnectionID()
            let retried = try await request(harness.socket, index: 5)
            await harness.socket.enqueue(response(id: retried.id, sessions: [summary(id: "fresh", revision: 1)], listRevision: 1))
            while harness.model.sessions.map(\.id) != ["fresh"] {
                try Task.checkCancellation()
                await Task.yield()
            }
            #expect(harness.model.sessions.map(\.id) == ["fresh"])
            #expect(await harness.client.activeConnectionID() == connection)
            #expect(!harness.model.visibleNotices.contains { $0.replacement?.key == .sessionCatalogCatchUp })
        }
    }

    @Test("slow session-list response beyond ten seconds still publishes")
    func slowListPagePublishesAfterTenSeconds() async throws {
        let clock = ManualClock()
        try await withHarness(manualClock: clock) { harness in
            let loading = Task { await harness.model.refreshSessions() }
            let request = try await request(harness.socket, index: 1)
            clock.advance(by: .seconds(11))
            await harness.socket.enqueue(response(
                id: request.id,
                sessions: [summary(id: "slow", revision: 1)],
                listRevision: 1
            ))
            #expect(await loading.value == .published)
            #expect(harness.model.sessions.map(\.id) == ["slow"])
        }
    }

    @Test("timeout outcomes on list, context, and command reads never become error notices")
    func transportTimeoutReadErrorsStaySilent() async throws {
        try await withHarness { harness in
            let snapshot = try SessionScenarioBuilder(seed: 91_004).openingTail(targetEncodedBytes: 4_096)
            harness.model.installHostedSubscribedSnapshot(snapshot)

            let contextRead = Task { await harness.model.loadContext(sessionID: snapshot.sessionId) }
            let context = try await request(harness.socket, index: 1)
            #expect(context.method == "session.context")
            await harness.socket.enqueue(errorResponse(id: context.id, code: "timeout"))
            await contextRead.value

            let commandRead = Task { await harness.model.loadCommands(sessionID: snapshot.sessionId) }
            let commands = try await request(harness.socket, index: 2)
            #expect(commands.method == "session.commands")
            await harness.socket.enqueue(errorResponse(id: commands.id, code: "timeout"))
            await commandRead.value

            let catalogRead = Task { await harness.model.refreshSessions() }
            let catalog = try await request(harness.socket, index: 3)
            #expect(catalog.method == "session.list")
            await harness.socket.enqueue(errorResponse(id: catalog.id, code: "timeout"))
            #expect(await catalogRead.value == .retained)
            #expect(harness.model.visibleNotices.isEmpty)
        }
    }

    @Test("shared catalog loader rejects repeated cursors before publication")
    func loaderRejectsRepeatedCursor() async throws {
        try await withHarness { harness in
            let loading = Task { try await SessionCatalogLoader.load(client: harness.client) { true } }
            let first = try await request(harness.socket, index: 1)
            await harness.socket.enqueue(response(id: first.id, sessions: [summary(id: "first", revision: 1)], listRevision: 7, nextCursor: "repeat"))
            let second = try await request(harness.socket, index: 2)
            await harness.socket.enqueue(response(id: second.id, sessions: [summary(id: "second", revision: 1)], listRevision: 7, nextCursor: "repeat"))
            switch try await loading.value {
            case let .invalid(code, reason, pageCount, revision):
                #expect(code == "invalid_response")
                #expect(reason == "repeated-cursor")
                #expect(pageCount == 2)
                #expect(revision == 7)
            default:
                Issue.record("Repeated catalog cursor was not rejected.")
            }
        }
    }

    @Test("shared catalog loader enforces the bounded page budget")
    func loaderEnforcesPageBudget() async throws {
        try await withHarness { harness in
            let loading = Task { try await SessionCatalogLoader.load(client: harness.client) { true } }
            for page in 0..<SessionCatalogLoadBounds.maximumPages {
                let request = try await request(harness.socket, index: page + 1)
                if page == 0 {
                    #expect(request.params?["cursor"] == nil)
                } else {
                    #expect(request.params?["cursor"] == .string("cursor-\(page)"))
                }
                await harness.socket.enqueue(response(
                    id: request.id,
                    sessions: [],
                    listRevision: 9,
                    nextCursor: "cursor-\(page + 1)"
                ))
            }
            switch try await loading.value {
            case let .invalid(code, reason, pageCount, revision):
                #expect(code == "limit_exceeded")
                #expect(reason == "page-budget")
                #expect(pageCount == SessionCatalogLoadBounds.maximumPages)
                #expect(revision == 9)
            default:
                Issue.record("Catalog traversal exceeded its page budget.")
            }
        }
    }

    @Test("known summary overlays synchronously without scheduling a catalog reload")
    func knownSummaryNeedsNoReload() async throws {
        try await withHarness { harness in
            harness.model.sessions = [summary(id: "known", revision: 0)]
            await harness.model.handle(summaryEvent(id: "known", revision: 1, phase: .running))

            #expect(harness.model.sessions.first?.phase == .running)
            #expect(harness.model.dashboardActivity(for: "known") == .active)
            #expect(await harness.socket.sentFrames().count == 1)
            #expect(harness.model.visibleNotices.isEmpty)
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
            #expect(harness.model.visibleNotices.isEmpty)
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
            #expect(harness.model.visibleNotices.isEmpty)
            #expect(harness.model.visibleNotices.isEmpty)
        }
    }

    @Test("an invalidation during the final traversal is never lost")
    func invalidationDuringFinalTraversalStillPublishes() async throws {
        try await withHarness(capabilities: ["sessions.v1", "session-archive.v1"]) { harness in
            try Self.storePairedProfile(harness.model)
            let model = harness.model
            let loading = Task { await model.refreshSessions() }

            // The lease's first traversal reads while a list change lands, so
            // the lease owes a second traversal for the newer revision.
            let firstTraversal = try await nextRequest(harness.socket, method: "session.list", from: 1)
            await model.handle(GatewayEvent(
                type: "event",
                topic: "session.listChanged",
                sessionId: nil,
                payload: .object(["listRevision": .number(2)])
            ))
            await harness.socket.enqueue(response(
                id: firstTraversal.request.id,
                sessions: [summary(id: "visible", revision: 1)],
                listRevision: 1,
                archivedCount: 0
            ))

            // The second (final) traversal reads. An archive lands while it is
            // in flight: its response invalidates in-flight loads and marks a
            // newer archive revision, which is the general shape of every
            // invalidation during a traversal — the same page cannot publish.
            let finalTraversal = try await nextRequest(
                harness.socket, method: "session.list", from: firstTraversal.index + 1
            )
            let archiving = Task {
                try await model.setSessionArchived(sessionID: "gone", profileID: "profile", archived: true)
            }
            let archive = try await nextRequest(
                harness.socket, method: "session.archive.set", from: finalTraversal.index + 1
            )
            await harness.socket.enqueue(Self.archiveResponse(id: archive.request.id, archivedAt: "2026-01-02T00:00:00Z"))
            try await archiving.value
            await harness.socket.enqueue(response(
                id: finalTraversal.request.id,
                sessions: [summary(id: "visible", revision: 1)],
                listRevision: 3,
                archivedCount: 1
            ))
            #expect(await loading.value == .retained)

            // That retired page was the only read that could carry the count,
            // so the lease must honor the follow-up it deferred. A dropped
            // follow-up leaves the dashboard on stale truth until some
            // unrelated list change.
            let followUpIndex = archive.index + 1
            let followUpArrived = await harness.socket.waitUntilSent(count: followUpIndex + 1, within: .seconds(2))
            try #require(
                followUpArrived,
                "the deferred catalog follow-up was dropped after its final traversal was retired"
            )
            let followUp = try await request(harness.socket, index: followUpIndex)
            #expect(followUp.method == "session.list")
            await harness.socket.enqueue(response(
                id: followUp.id,
                sessions: [summary(id: "visible", revision: 1)],
                listRevision: 3,
                archivedCount: 1
            ))
            while model.archivedSessionCount != 1 {
                try Task.checkCancellation()
                await Task.yield()
            }
            #expect(model.archivedSessionCount == 1)
            #expect(model.sessions.map(\.id) == ["visible"])
            #expect(model.visibleNotices.isEmpty)
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
            #expect(harness.model.visibleNotices.isEmpty)
            #expect(harness.model.visibleNotices.isEmpty)
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
            #expect(harness.model.visibleNotices.isEmpty)
            #expect(harness.model.visibleNotices.isEmpty)
        }
    }

    @Test("subagent-driven catalog churn never consumes the failure budget")
    func subagentCatalogChurnDoesNotSurfaceUnavailable() async throws {
        try await withHarness { harness in
            harness.model.sessions = [summary(id: "retained", revision: 1)]
            // A subagent can invalidate the Gateway's structural generation while
            // the user-scoped lease is being read. The Gateway pins continuation
            // pages, but this also protects iOS from a moving older peer. Three
            // mixed-revision passes must remain benign rather than exhausting the
            // actionable failure budget.
            for cycle in 0..<3 {
                await harness.model.handle(GatewayEvent(
                    type: "event", topic: "session.listChanged", sessionId: nil,
                    payload: .object(["source": .string("active-subagent")])
                ))
                let loading = Task { await harness.model.refreshSessions() }
                let first = try await request(harness.socket, index: cycle * 4 + 1)
                await harness.socket.enqueue(response(
                    id: first.id,
                    sessions: [summary(id: "partial-\(cycle)", revision: 1)],
                    listRevision: cycle * 4 + 1,
                    nextCursor: "cursor-\(cycle)"
                ))
                let continuation = try await request(harness.socket, index: cycle * 4 + 2)
                await harness.socket.enqueue(response(
                    id: continuation.id,
                    sessions: [summary(id: "partial-tail-\(cycle)", revision: 1)],
                    listRevision: cycle * 4 + 2
                ))
                let retryFirst = try await request(harness.socket, index: cycle * 4 + 3)
                await harness.socket.enqueue(response(
                    id: retryFirst.id,
                    sessions: [summary(id: "retry-\(cycle)", revision: 1)],
                    listRevision: cycle * 4 + 3,
                    nextCursor: "retry-cursor-\(cycle)"
                ))
                let retryContinuation = try await request(harness.socket, index: cycle * 4 + 4)
                await harness.socket.enqueue(response(
                    id: retryContinuation.id,
                    sessions: [summary(id: "retry-tail-\(cycle)", revision: 1)],
                    listRevision: cycle * 4 + 4
                ))
                #expect(await loading.value == .retained)
                // Exhausted revision churn must not leave a hidden retry lease
                // issuing requests after the caller has completed.
                #expect(await harness.socket.sentFrames().count == (cycle + 1) * 4 + 1)
                #expect(harness.model.visibleNotices.isEmpty)
            }

            let recovery = Task { await harness.model.refreshSessions() }
            let request = try await request(harness.socket, index: 13)
            await harness.socket.enqueue(response(
                id: request.id,
                sessions: [summary(id: "recovered", revision: 1)],
                listRevision: 20
            ))
            #expect(await recovery.value == .published)
            #expect(harness.model.sessions.map(\.id) == ["recovered"])
            #expect(harness.model.visibleNotices.isEmpty)
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
            #expect(harness.model.visibleNotices.isEmpty)
            #expect(harness.model.visibleNotices.isEmpty)
        }
    }

    @Test("application-level catalog errors retain state while the socket epoch remains responsive")
    func typedFailureOutcomes() async throws {
        try await withHarness { harness in
            let invalidLoad = Task { await harness.model.refreshSessions() }
            let invalid = try await request(harness.socket, index: 1)
            await harness.socket.enqueue(errorResponse(id: invalid.id, code: "invalid_request"))
            #expect(await invalidLoad.value == .retained)

            let disconnectedLoad = Task { await harness.model.refreshSessions() }
            let disconnected = try await request(harness.socket, index: 2)
            await harness.socket.enqueue(errorResponse(id: disconnected.id, code: "disconnected"))
            #expect(await disconnectedLoad.value == .retained)
            #expect(await harness.client.activeConnectionID() != nil)
            #expect(harness.model.visibleNotices.isEmpty)
        }
    }

    @Test("cancelled catalog demand cannot create a shared traversal")
    func cancelledCatalogDemandCannotStartTraversal() async throws {
        try await withHarness { harness in
            let cancelled = Task { await harness.model.refreshSessions() }
            cancelled.cancel()
            #expect(await cancelled.value == .retained)
            #expect(!harness.model.sessionCatalogIsLoading)
            #expect(await harness.socket.sentFrames().count == 1)
        }
    }

    @Test("cancelled connection-refresh admission cannot schedule reads or publish readiness")
    func cancelledOptionalRefreshAdmission() async throws {
        try await withHarness { harness in
            let connectionID = try #require(await harness.client.activeConnectionID())
            let baseline = harness.model.diagnosticsReadinessGeneration
            let refresh = Task { @MainActor in
                await harness.model.lifecycleRefreshAll(admission: .init(generation: 0, connectionID: connectionID))
            }
            refresh.cancel() // Cancel before this MainActor child can enter the delegate.
            await refresh.value
            #expect(harness.model.diagnosticsReadinessGeneration == baseline)
            #expect(!harness.model.sessionCatalogIsLoading)
            #expect(await harness.socket.sentFrames().count == 1)
        }
    }

    @Test("background retires optional connection reads without publishing their late catalog")
    func backgroundRetiresOptionalRefresh() async throws {
        try await withHarness { harness in
            harness.model.sessions = [summary(id: "retained", revision: 1)]
            let connectionID = try #require(await harness.client.activeConnectionID())
            await harness.model.lifecycleRefreshAll(admission: .init(generation: 0, connectionID: connectionID))
            try await harness.socket.waitUntilSent(count: 2)
            let requests = try await harness.socket.sentFrames().dropFirst().map {
                try JSONDecoder.gateway.decode(Request.self, from: $0)
            }
            let catalog = try #require(requests.first { $0.method == "session.list" })
            #expect(harness.model.sessionCatalogIsLoading)
            let read = Task { await harness.model.refreshSessions() }
            defer { read.cancel() }
            await harness.model.enteredBackground().value
            try await harness.socket.waitUntilClosed()
            await harness.socket.enqueue(response(
                id: catalog.id, sessions: [summary(id: "late", revision: 2)], listRevision: 2
            ))
            #expect(await read.value == .retained)
            #expect(harness.model.sessions.map(\.id) == ["retained"])
            #expect(!harness.model.sessionCatalogIsLoading)
            #expect(!harness.model.diagnosticsAreReady)
            #expect(harness.model.visibleNotices.isEmpty)
        }
    }

    @Test("transport loss during optional catalog loading does not fan out later reads")
    func optionalCatalogLossStopsLaterReads() async throws {
        try await withHarness { harness in
            let connectionID = try #require(await harness.client.activeConnectionID())
            // Hosted connection installs only the transport. This fixture's
            // empty profile store makes the independent inbox owner ineligible.
            #expect(harness.model.profiles.selected == nil)
            await harness.model.lifecycleRefreshAll(admission: .init(generation: 0, connectionID: connectionID))
            let catalog = try await request(harness.socket, index: 1)
            #expect(catalog.method == "session.list")
            let loss = Task { @MainActor in
                await harness.socket.failPendingReceivers(URLError(.networkConnectionLost))
            }
            #expect(await harness.model.refreshSessions() != .published)
            await loss.value
            try await harness.socket.waitUntilClosed()
            #expect(await harness.client.activeConnectionID() == nil)
            #expect(await harness.socket.sentFrames().count == 2)
            #expect(harness.model.visibleNotices.isEmpty)
        }
    }

    @Test("provider, settings, and device reads wait until mounted restoration completes")
    func optionalReadsStartAfterMountedRestoration() async throws {
        try await withHarness { harness in
            let model = harness.model
            let connectionID = try #require(await harness.client.activeConnectionID())
            let admission = GatewayLifecycleCoordinator.Admission(generation: 0, connectionID: connectionID)
            await model.lifecycleRefreshAll(admission: admission)
            let catalog = try await request(harness.socket, index: 1)
            #expect(catalog.method == "session.list")
            #expect((await harness.socket.sentFrames()).count == 2)
            await harness.socket.enqueue(response(id: catalog.id, sessions: [], listRevision: 1))
            #expect(await model.refreshSessions() == .published)
            #expect((await harness.socket.sentFrames()).count == 2)

            #expect(await model.lifecycleRestoreMountedPresentation(admission: admission))
            let required = Set(["provider.list", "model.list", "settings.get", "device.list"])
            var reads: [Request] = []
            while Set(reads.map(\.method)) != required {
                reads.append(try await request(harness.socket, index: reads.count + 2))
            }
            let settings: JSONValue = .object(["effective": .object(["theme": .string("current")])])
            let devices = [PairedDevice(id: "current-device", name: "Phone", createdAt: "2026-09-10T00:00:00Z")]
            for read in reads {
                let result: JSONValue
                switch read.method {
                case "settings.get": result = settings
                case "provider.list": result = .object(["providers": .array([])])
                case "model.list": result = .object(["models": .array([]), "nextCursor": .null])
                case "device.list": result = .object(["devices": try JSONValue.encode(devices)])
                default: throw CancellationError()
                }
                await harness.socket.enqueue(try JSONEncoder.gateway.encode(JSONValue.object([
                    "type": .string("response"), "id": .string(read.id), "ok": .bool(true), "result": result,
                ])))
            }
            try await withTestWatchdog(timeout: .seconds(2)) { @MainActor in
                while model.settings(for: .global) != settings
                    || model.providerCatalog(for: .global) == nil
                    || model.pairedDevices != devices {
                    await Task.yield()
                }
            }
            #expect(await harness.client.activeConnectionID() == connectionID)
            #expect(model.visibleNotices.isEmpty)
        }
    }

    @Test("newer paired-device reads own success publication")
    func newerDeviceReadWins() async throws {
        try await withHarness { harness in
            let older = Task { await harness.model.refreshDevices() }
            let olderRequest = try await request(harness.socket, index: 1)
            let newer = Task { await harness.model.refreshDevices() }
            let newerRequest = try await request(harness.socket, index: 2)
            let newerDevices = [PairedDevice(
                id: "newer-device", name: "Newer Phone", createdAt: "2026-09-11T00:00:00Z"
            )]
            await harness.socket.enqueue(deviceResponse(id: newerRequest.id, devices: newerDevices))
            await newer.value
            await harness.socket.enqueue(deviceResponse(id: olderRequest.id, devices: [PairedDevice(
                id: "older-device", name: "Older Phone", createdAt: "2026-09-10T00:00:00Z"
            )]))
            await older.value
            #expect(harness.model.pairedDevices == newerDevices)
        }
    }

    enum OptionalRead: CaseIterable, Sendable { case settings, providers, devices }

    @Test("a cancelled optional read cannot supersede a current read before entry", arguments: OptionalRead.allCases)
    func cancelledOptionalReadCannotSupersede(owner: OptionalRead) async throws {
        try await withHarness { harness in
            let refresh: @MainActor @Sendable () async -> Void = {
                switch owner {
                case .settings: _ = await harness.model.refreshSettings(target: .global)
                case .providers: _ = await harness.model.refreshProviders(target: .global)
                case .devices: await harness.model.refreshDevices()
                }
            }
            let current = Task { await refresh() }
            let gate = TestReadGate()
            let obsolete = Task {
                await gate.wait()
                await refresh()
            }
            do {
                let expectedFrames = owner == .providers ? 3 : 2
                try await harness.socket.waitUntilSent(count: expectedFrames)
                try await gate.waitForEntry()
                obsolete.cancel()
                await gate.release()
                await obsolete.value
                #expect(await harness.socket.sentFrames().count == expectedFrames)
                let settings: JSONValue = .object(["effective": .object(["theme": .string("current")])])
                let devices = [PairedDevice(id: "current-device", name: "Phone", createdAt: "2026-09-10T00:00:00Z")]
                for frame in await harness.socket.sentFrames().dropFirst() {
                    let request = try JSONDecoder.gateway.decode(Request.self, from: frame)
                    let result: JSONValue
                    switch request.method {
                    case "settings.get": result = settings
                    case "provider.list": result = .object(["providers": .array([])])
                    case "model.list": result = .object(["models": .array([]), "nextCursor": .null])
                    case "device.list": result = .object(["devices": try JSONValue.encode(devices)])
                    default: throw CancellationError()
                    }
                    await harness.socket.enqueue(try JSONEncoder.gateway.encode(JSONValue.object([
                        "type": .string("response"), "id": .string(request.id), "ok": .bool(true), "result": result,
                    ])))
                }
                await current.value
                switch owner {
                case .settings: #expect(harness.model.settings(for: .global) == settings)
                case .providers: #expect(harness.model.providerCatalog(for: .global) != nil)
                case .devices: #expect(harness.model.pairedDevices == devices)
                }
                #expect(harness.model.visibleNotices.isEmpty)
            } catch {
                obsolete.cancel()
                await gate.release()
                await obsolete.value
                current.cancel()
                await current.value
                throw error
            }
        }
    }

    @Test("foreground diagnostics readiness does not await optional catalog convergence")
    func foregroundDiagnosticsReadiness() async throws {
        let socket = ScriptedGatewaySocket()
        let client = GatewayClient(socketFactory: ScriptedGatewaySocketFactory(sockets: [socket]).factory)
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let model = AppModel(client: client, cache: SnapshotCache(root: root))
        let profile = GatewayProfile(
            id: "profile", label: "Mac", host: "gateway.test", port: 9_847,
            machineId: "machine", deviceId: "device"
        )
        await socket.enqueue(helloFrame())
        try await model.connectHostedGateway(profile: profile, token: "token")
        defer { try? FileManager.default.removeItem(at: root) }
        let baseline = model.diagnosticsReadinessGeneration
        let foregroundBaseline = model.foregroundReconciliationGeneration

        let reconciliation = model.becameActive()
        await reconciliation?.value
        var catalogIndex = 1
        var catalog = try await request(socket, index: catalogIndex)
        while catalog.method != "session.list" {
            #expect(["provider.list", "model.list", "settings.get", "device.list"].contains(catalog.method))
            catalogIndex += 1
            catalog = try await request(socket, index: catalogIndex)
        }
        // Mounted authority is complete before optional catalog convergence;
        // the catalog request remains owned and fenced in the background.
        #expect(!model.isReconcilingForeground)
        #expect(model.foregroundReconciliationGeneration == foregroundBaseline + 1)
        #expect(model.diagnosticsReadinessGeneration == baseline + 1)
        await socket.enqueue(response(id: catalog.id, sessions: [], listRevision: 1))
        await reconciliation?.value

        #expect(model.diagnosticsReadinessGeneration == baseline + 1)
        #expect(model.foregroundReconciliationGeneration == foregroundBaseline + 1)
        #expect(!model.isReconcilingForeground)
        #expect(model.diagnosticsAreReady)
        model.enteredBackground()
        #expect(!model.diagnosticsAreReady)
        await model.teardown()
        await client.close()
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
        var catalogIndex = 1
        var catalog = try await request(socket, index: catalogIndex)
        while catalog.method != "session.list" {
            #expect(["provider.list", "model.list", "settings.get", "device.list"].contains(catalog.method))
            catalogIndex += 1
            catalog = try await request(socket, index: catalogIndex)
        }
        await socket.enqueue(errorResponse(id: catalog.id, code: "disconnected"))
        await reconciliation?.value

        #expect(model.connectionState == .connected)
        #expect(factory.requests.count == 1)
        #expect(model.visibleNotices.isEmpty)
        await model.teardown()
        await client.close()
    }

    @Test("archive support and its count come only from a capable Gateway")
    func archivedCountRequiresCapability() async throws {
        try await withHarness(capabilities: ["sessions.v1", "session-archive.v1"]) { harness in
            try Self.storePairedProfile(harness.model)
            #expect(harness.model.supportsSessionArchive(profileID: "profile"))
            #expect(!harness.model.supportsSessionArchive(profileID: "unknown"))
            #expect(!harness.model.supportsSessionArchive(profileID: nil))
            let loading = Task { await harness.model.refreshSessions() }
            let catalog = try await request(harness.socket, index: 1)
            #expect(catalog.method == "session.list")
            #expect(catalog.params?["archived"] == nil)
            await harness.socket.enqueue(response(
                id: catalog.id,
                sessions: [summary(id: "visible", revision: 1)],
                listRevision: 1,
                archivedCount: 3
            ))
            #expect(await loading.value == .published)
            #expect(harness.model.archivedSessionCount == 3)
            #expect(harness.model.visibleSessions.map(\.id) == ["visible"])
        }
        // A Gateway without the capability publishes nothing: never a zero, and
        // no archive controls.
        try await withHarness { harness in
            try Self.storePairedProfile(harness.model)
            #expect(!harness.model.supportsSessionArchive(profileID: "profile"))
            let loading = Task { await harness.model.refreshSessions() }
            let catalog = try await request(harness.socket, index: 1)
            await harness.socket.enqueue(response(
                id: catalog.id,
                sessions: [summary(id: "visible", revision: 1)],
                listRevision: 1,
                archivedCount: 3
            ))
            #expect(await loading.value == .published)
            #expect(harness.model.archivedSessionCount == nil)
        }
    }

    @Test("a superseded archived page is retired instead of replacing newer truth")
    func archivedReadFence() async throws {
        try await withHarness(capabilities: ["sessions.v1", "session-archive.v1"]) { harness in
            let model = harness.model
            let first = Task {
                try await model.loadArchivedSessions(
                    profileID: "profile", cursor: nil, purpose: .container
                ) { true }
            }
            let firstRequest = try await archivedRequest(harness.socket, from: 1)
            #expect(firstRequest.request.params?["archived"] == .string("only"))
            #expect(firstRequest.request.params?["scope"] == .string("user"))
            let second = Task {
                try await model.loadArchivedSessions(
                    profileID: "profile", cursor: nil, purpose: .container
                ) { true }
            }
            let secondRequest = try await archivedRequest(harness.socket, from: firstRequest.index + 1)
            #expect(secondRequest.request.id != firstRequest.request.id)

            // The older page arrives after the newer read started. It must be
            // retired rather than published over newer archive truth.
            await harness.socket.enqueue(response(
                id: firstRequest.request.id,
                sessions: [summary(id: "older", revision: 1, archivedAt: "2026-01-02T00:00:00Z")],
                listRevision: 1
            ))
            await harness.socket.enqueue(response(
                id: secondRequest.request.id,
                sessions: [summary(id: "newer", revision: 2, archivedAt: "2026-01-03T00:00:00Z")],
                listRevision: 1
            ))
            guard case .retired = try await first.value else {
                Issue.record("a superseded archived page was published")
                return
            }
            guard case let .loaded(page) = try await second.value else {
                Issue.record("the current archived page was not published")
                return
            }
            #expect(page.sessions.map(\.id) == ["newer"])
            #expect(page.sessions.first?.archivedAt == "2026-01-03T00:00:00Z")
        }
    }

    @Test("a background catalog publication advances the archive projection")
    func backgroundCatalogPublicationAdvancesArchiveProjection() async throws {
        try await withHarness { harness in
            let model = harness.model
            try Self.storePairedProfile(model)
            try model.profiles.save(
                GatewayProfile(
                    id: "remote", label: "Remote", host: "remote.test", port: 9_847,
                    machineId: "remote-machine", deviceId: "device"
                ),
                token: "token",
                selecting: false
            )
            let before = model.archiveProjectionRevision
            // The container's rows come from a background profile's own page,
            // so its every authoritative publication is a new authority — the
            // archived count is not: it can stay the same while rows change.
            model.dashboardPoolDidPublishAuthoritativeCatalog(profileID: "remote")
            #expect(model.archiveProjectionRevision == before + 1)
            // The focused profile's authority arrives through its own catalog
            // publication, so a pool report for it is not a second one.
            model.dashboardPoolDidPublishAuthoritativeCatalog(profileID: "profile")
            #expect(model.archiveProjectionRevision == before + 1)
            model.dashboardPoolDidPublishAuthoritativeCatalog(profileID: "forgotten")
            #expect(model.archiveProjectionRevision == before + 1)
        }
    }

    @Test("archived pages carry the Gateway that owns each row")
    func archivedRowsCarryOwningGateway() async throws {
        try await withHarness(capabilities: ["sessions.v1", "session-archive.v1"]) { harness in
            let model = harness.model
            try Self.storePairedProfile(model)
            let read = Task {
                try await model.loadArchivedSessions(
                    profileID: "profile", cursor: nil, purpose: .container
                ) { true }
            }
            let request = try await archivedRequest(harness.socket, from: 1)
            await harness.socket.enqueue(response(
                id: request.request.id,
                sessions: [summary(id: "archived", revision: 1, archivedAt: "2026-01-02T00:00:00Z")],
                listRevision: 1
            ))
            guard case let .loaded(page) = try await read.value else {
                Issue.record("an archived page was not published")
                return
            }
            // Two servers can own equal session IDs, so an archived row must
            // carry the Gateway it came from: every action on it is addressed
            // to that Gateway, and the dashboard identity is qualified by it.
            let row = try #require(page.sessions.first)
            #expect(row.gatewayProfileID == "profile")
            #expect(row.gatewayProfileLabel == "Mac")
            #expect(row.dashboardID == "profile:archived")
        }
    }

    @Test("a container pass does not retire the automation form's target lookup")
    func archivedReadPurposesFenceIndependently() async throws {
        try await withHarness(capabilities: ["sessions.v1", "session-archive.v1"]) { harness in
            let model = harness.model
            let lookup = Task {
                try await model.archivedSessionSummary(
                    profileID: "profile", sessionID: "target", presentationActive: { true }
                )
            }
            let lookupRequest = try await archivedRequest(harness.socket, from: 1)
            // A container pass starts while the lookup is in flight. They read
            // the same projection for different surfaces, so the container's
            // read fence must not retire the lookup.
            let container = Task {
                try await model.loadArchivedSessions(
                    profileID: "profile", cursor: nil, purpose: .container
                ) { true }
            }
            let containerRequest = try await archivedRequest(harness.socket, from: lookupRequest.index + 1)
            await harness.socket.enqueue(response(
                id: lookupRequest.request.id,
                sessions: [summary(id: "target", revision: 1, archivedAt: "2026-01-02T00:00:00Z")],
                listRevision: 1
            ))
            await harness.socket.enqueue(response(
                id: containerRequest.request.id,
                sessions: [summary(id: "other", revision: 1, archivedAt: "2026-01-03T00:00:00Z")],
                listRevision: 1
            ))
            #expect(try await lookup.value?.id == "target")
            guard case let .loaded(page) = try await container.value else {
                Issue.record("the container's page was not published")
                return
            }
            #expect(page.sessions.map(\.id) == ["other"])
        }
    }

    @Test("an inactive surface publishes no archived page")
    func archivedReadAdmission() async throws {
        try await withHarness(capabilities: ["sessions.v1", "session-archive.v1"]) { harness in
            try Self.storePairedProfile(harness.model)
            let sentBefore = await harness.socket.sentFrames().count
            let inactive = try await harness.model.loadArchivedSessions(
                profileID: "profile",
                cursor: nil,
                purpose: .container
            ) { false }
            guard case .retired = inactive else {
                Issue.record("an inactive surface received an archived page")
                return
            }
            #expect(await harness.socket.sentFrames().count == sentBefore)
        }
    }

    @Test("a session the dashboard cannot name is resolved through the archived projection")
    func archivedTargetLookupWalksBoundedPages() async throws {
        try await withHarness(capabilities: ["sessions.v1", "session-archive.v1"]) { harness in
            try Self.storePairedProfile(harness.model)
            let lookup = Task {
                try await harness.model.archivedSessionSummary(
                    profileID: "profile", sessionID: "target", presentationActive: { true }
                )
            }
            let first = try await archivedRequest(harness.socket, from: 1)
            await harness.socket.enqueue(response(
                id: first.request.id,
                sessions: [summary(id: "other", revision: 1, archivedAt: "2026-01-02T00:00:00Z")],
                listRevision: 1,
                nextCursor: "page-2"
            ))
            let second = try await archivedRequest(harness.socket, from: first.index + 1)
            #expect(second.request.params?["cursor"] == .string("page-2"))
            await harness.socket.enqueue(response(
                id: second.request.id,
                sessions: [summary(id: "target", revision: 1, archivedAt: "2026-01-03T00:00:00Z")],
                listRevision: 1
            ))
            let resolved = try await lookup.value
            #expect(resolved?.id == "target")
        }

        // The page walk is bounded: an archived count beyond the bound keeps the
        // existing fallback rather than reading forever.
        try await withHarness(capabilities: ["sessions.v1", "session-archive.v1"]) { harness in
            try Self.storePairedProfile(harness.model)
            let lookup = Task {
                try await harness.model.archivedSessionSummary(
                    profileID: "profile", sessionID: "target", presentationActive: { true }
                )
            }
            var index = 1
            for page in 0..<SessionArchiveTargetLookup.maximumPages {
                let read = try await archivedRequest(harness.socket, from: index)
                index = read.index + 1
                await harness.socket.enqueue(response(
                    id: read.request.id,
                    sessions: [summary(id: "other-\(page)", revision: 1, archivedAt: "2026-01-02T00:00:00Z")],
                    listRevision: 1,
                    nextCursor: "page-\(page + 2)"
                ))
            }
            let bounded = try await lookup.value
            #expect(bounded == nil)
        }

        // A Gateway without the archive contract is never asked to walk.
        try await withHarness { harness in
            let sentBefore = await harness.socket.sentFrames().count
            let unsupported = try await harness.model.archivedSessionSummary(
                profileID: "profile", sessionID: "target", presentationActive: { true }
            )
            #expect(unsupported == nil)
            #expect(await harness.socket.sentFrames().count == sentBefore)
        }
    }

    // MARK: Session-list cache checkpoints

    @Test("a live summary burst becomes one trailing cache write of its newest rows")
    func summaryBurstCoalescesIntoOneCacheWrite() async throws {
        let clock = ManualClock()
        let signposts = RecordingPerformanceSignposts()
        try await withHarness(manualClock: clock, cacheSignposts: signposts) { harness in
            try Self.storePairedProfile(harness.model)
            try await publishCatalog(harness, sessions: [summary(id: "known", revision: 0), summary(id: "other", revision: 0)])
            // An authoritative page is written without waiting for a window.
            try await waitForPublishedCheckpoint(harness, signposts)
            signposts.reset()

            for revision in 1...5 {
                await harness.model.handle(summaryEvent(id: "known", revision: revision, phase: .running))
            }
            try await clock.waitUntilSleeping(count: 1, duration: SnapshotCachePolicy.summaryCheckpointDelay)
            #expect(cacheSaveCount(signposts) == 0)
            #expect(await SnapshotCache(root: harness.root).load(profileID: "profile")
                .sessions.first { $0.id == "known" }?.summaryRevision == 0)

            clock.advance(by: SnapshotCachePolicy.summaryCheckpointDelay)
            try await waitForCacheSaves(signposts, count: 1)
            let restored = await SnapshotCache(root: harness.root).load(profileID: "profile")
            #expect(restored.sessions == harness.model.sessions)
            #expect(restored.sessions.first { $0.id == "known" }?.summaryRevision == 5)

            // The burst owned one window; nothing else is armed or written.
            clock.advance(by: SnapshotCachePolicy.summaryCheckpointDelay)
            try await settleCacheWork()
            #expect(cacheSaveCount(signposts) == 1)
        }
    }

    @Test("backgrounding writes a pending summary checkpoint that a cold start restores")
    func backgroundFlushesPendingCacheCheckpoint() async throws {
        let clock = ManualClock()
        let signposts = RecordingPerformanceSignposts()
        try await withHarness(manualClock: clock, cacheSignposts: signposts) { harness in
            try Self.storePairedProfile(harness.model)
            try await publishCatalog(harness, sessions: [summary(id: "known", revision: 0), summary(id: "other", revision: 0)])
            try await waitForPublishedCheckpoint(harness, signposts)
            signposts.reset()

            await harness.model.handle(summaryEvent(id: "known", revision: 1, phase: .running))
            await harness.model.handle(summaryEvent(id: "other", revision: 1, phase: .running))
            try await clock.waitUntilSleeping(count: 1, duration: SnapshotCachePolicy.summaryCheckpointDelay)
            let lastCatalog = harness.model.sessions

            // The returned task is what the background assertion retains; the
            // write completes inside it without the window elapsing.
            await harness.model.enteredBackground().value
            #expect(cacheSaveCount(signposts) == 1)
            let restored = await SnapshotCache(root: harness.root).load(profileID: "profile")
            #expect(restored.sessions == lastCatalog)
            #expect(restored.sessions.allSatisfy { $0.summaryRevision == 1 })

            clock.advance(by: SnapshotCachePolicy.summaryCheckpointDelay)
            try await settleCacheWork()
            #expect(cacheSaveCount(signposts) == 1)
        }
    }

    @Test("an inactive scene writes a pending summary checkpoint before the app switcher can end it")
    func inactiveSceneFlushesPendingCacheCheckpoint() async throws {
        let clock = ManualClock()
        let signposts = RecordingPerformanceSignposts()
        try await withHarness(manualClock: clock, cacheSignposts: signposts) { harness in
            try Self.storePairedProfile(harness.model)
            try await publishCatalog(harness, sessions: [summary(id: "known", revision: 0)])
            try await waitForPublishedCheckpoint(harness, signposts)
            signposts.reset()

            await harness.model.handle(summaryEvent(id: "known", revision: 1, phase: .running))
            try await clock.waitUntilSleeping(count: 1, duration: SnapshotCachePolicy.summaryCheckpointDelay)
            harness.model.becameInactive()
            try await waitForCacheSaves(signposts, count: 1)
            #expect(await SnapshotCache(root: harness.root).load(profileID: "profile").sessions == harness.model.sessions)

            clock.advance(by: SnapshotCachePolicy.summaryCheckpointDelay)
            try await settleCacheWork()
            #expect(cacheSaveCount(signposts) == 1)
        }
    }

    @Test("forgetting a server inside a trailing window never leaves or resurrects its cache")
    func profileRemovalDuringTrailingWindowNeverWrites() async throws {
        let clock = ManualClock()
        let signposts = RecordingPerformanceSignposts()
        try await withHarness(manualClock: clock, cacheSignposts: signposts) { harness in
            try Self.storePairedProfile(harness.model)
            try await publishCatalog(harness, sessions: [summary(id: "known", revision: 0)])
            try await waitForPublishedCheckpoint(harness, signposts)
            await harness.model.handle(summaryEvent(id: "known", revision: 1, phase: .running))
            try await clock.waitUntilSleeping(count: 1, duration: SnapshotCachePolicy.summaryCheckpointDelay)

            await harness.model.forgetCurrentGateway()
            #expect(try cacheFiles(harness.root).isEmpty)

            clock.advance(by: SnapshotCachePolicy.summaryCheckpointDelay)
            try await settleCacheWork()
            #expect(try cacheFiles(harness.root).isEmpty)
            #expect(await SnapshotCache(root: harness.root).load(profileID: "profile").sessions.isEmpty)
        }
    }

    private func publishCatalog(_ harness: Harness, sessions: [SessionSummary]) async throws {
        let loading = Task { await harness.model.refreshSessions() }
        let list = try await nextRequest(harness.socket, method: "session.list", from: 1)
        await harness.socket.enqueue(response(id: list.request.id, sessions: sessions, listRevision: 1))
        #expect(await loading.value == .published)
    }

    private func cacheSaveCount(_ signposts: RecordingPerformanceSignposts) -> Int {
        signposts.events().filter { $0 == .begin(.cacheSave) }.count
    }

    /// The publish's save drains on the main actor after its signpost ends. A
    /// summary delivered before that resumption finds the drain in flight, which
    /// writes without arming a trailing window, so the window tests await the drain.
    private func waitForPublishedCheckpoint(_ harness: Harness, _ signposts: RecordingPerformanceSignposts) async throws {
        try await waitForCacheSaves(signposts, count: 1)
        await harness.model.inFlightCacheCheckpoint?.value
    }

    /// Cache saves complete on the `SnapshotCache` actor, off the main actor.
    private func waitForCacheSaves(_ signposts: RecordingPerformanceSignposts, count: Int) async throws {
        while signposts.events().filter({
            if case .end(.cacheSave, _, _) = $0 { return true }
            return false
        }).count < count {
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    /// Gives an erroneously armed window or save time to reach the cache actor.
    private func settleCacheWork() async throws {
        for _ in 0..<10 {
            await Task.yield()
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func cacheFiles(_ root: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
    }

    /// A paired profile is normally stored before it is selected; the hosted
    /// harness connects one directly, so archive counting needs the store
    /// projection that production has.
    private static func storePairedProfile(_ model: AppModel) throws {
        try model.profiles.save(
            GatewayProfile(
                id: "profile",
                label: "Mac",
                host: "gateway.test",
                port: 9_847,
                machineId: "machine",
                deviceId: "device"
            ),
            token: "token",
            selecting: true
        )
    }

    /// Finds the next archived-container read. Catalog refreshes share the same
    /// transport, so the unique `archived: "only"` parameter identifies it.
    private func archivedRequest(
        _ socket: ScriptedGatewaySocket,
        from startIndex: Int
    ) async throws -> (request: Request, index: Int) {
        var index = startIndex
        while true {
            let request = try await request(socket, index: index)
            if request.params?["archived"] == .string("only") { return (request, index) }
            index += 1
        }
    }

    private func withHarness(
        sockets: [ScriptedGatewaySocket] = [ScriptedGatewaySocket()],
        manualClock: ManualClock? = nil,
        reconnectDelayPolicy: ReconnectDelayPolicy = .standard,
        capabilities: [String] = ["sessions.v1"],
        cacheSignposts: RecordingPerformanceSignposts? = nil,
        operation: @escaping @MainActor @Sendable (Harness) async throws -> Void
    ) async throws {
        let socket = try #require(sockets.first)
        let client = GatewayClient(socketFactory: ScriptedGatewaySocketFactory(sockets: sockets).factory)
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let suiteName = "AppModelCatalogSyncTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = AppModel(
            client: client,
            profiles: GatewayProfileStore(defaults: defaults),
            cache: SnapshotCache(
                root: root,
                performanceSignposts: cacheSignposts ?? SystemPerformanceSignposts.shared
            ),
            clock: manualClock?.clock ?? .continuous,
            reconnectDelayPolicy: reconnectDelayPolicy
        )
        let profile = GatewayProfile(
            id: "profile", label: "Mac", host: "gateway.test", port: 9_847,
            machineId: "machine", deviceId: "device"
        )
        let harness = Harness(socket: socket, sockets: sockets, client: client, model: model, root: root)
        do {
            await socket.enqueue(helloFrame(capabilities: capabilities))
            try await model.connectHostedGateway(profile: profile, token: "token")
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
        phase: SessionPhase = .idle,
        archivedAt: String? = nil
    ) -> SessionSummary {
        SessionSummary(
            id: id, name: id, cwd: "/workspace", parentSessionId: nil,
            createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:01Z",
            messageCount: revision, firstMessage: id, phase: phase, summaryRevision: revision,
            archivedAt: archivedAt
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

    private func deviceResponse(id: String, devices: [PairedDevice]) -> Data {
        let encoded = try! JSONEncoder.gateway.encode(devices)
        let rawDevices = try! JSONSerialization.jsonObject(with: encoded)
        return try! JSONSerialization.data(withJSONObject: [
            "type": "response", "id": id, "ok": true,
            "result": ["devices": rawDevices],
        ])
    }

    private func response(
        id: String,
        sessions: [SessionSummary],
        listRevision: Int,
        projectionToken: String? = nil,
        nextCursor: String? = nil,
        archivedCount: Int? = nil
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
        return try! JSONSerialization.data(withJSONObject: [
            "type": "response", "id": id, "ok": true, "result": result,
        ])
    }

    /// The next request of `method` at or after `startIndex`. Catalog refreshes
    /// and mutations share one transport, so a traversal is identified by its
    /// method rather than by a fixed frame index.
    private func nextRequest(
        _ socket: ScriptedGatewaySocket,
        method: String,
        from startIndex: Int
    ) async throws -> (request: Request, index: Int) {
        var index = startIndex
        while true {
            let request = try await request(socket, index: index)
            if request.method == method { return (request, index) }
            index += 1
        }
    }

    private static func archiveResponse(id: String, archivedAt: String) -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "type": "response", "id": id, "ok": true,
            "result": ["archived": true, "archivedAt": archivedAt],
        ])
    }

    private func errorResponse(id: String, code: String) -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "type": "response", "id": id, "ok": false,
            "error": ["code": code, "message": "synthetic \(code)", "retryable": true],
        ])
    }

    private func helloFrame(capabilities: [String] = ["sessions.v1"]) -> Data {
        let listed = capabilities.map { "\"\($0)\"" }.joined(separator: ",")
        return Data(#"{"type":"hello","gatewayVersion":"1.0.0","piVersion":"1.0.0","protocolVersion":7,"minProtocolVersion":7,"machineId":"machine","machineName":"Mac","gatewayChannel":"stable","capabilities":["#.utf8)
            + Data(listed.utf8) + Data("]}".utf8)
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
