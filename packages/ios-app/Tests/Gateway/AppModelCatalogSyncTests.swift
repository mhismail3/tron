import Foundation
import Observation
import Testing
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

    private func withHarness(
        sockets: [ScriptedGatewaySocket] = [ScriptedGatewaySocket()],
        manualClock: ManualClock? = nil,
        reconnectDelayPolicy: ReconnectDelayPolicy = .standard,
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
            cache: SnapshotCache(root: root),
            clock: manualClock?.clock ?? .continuous,
            reconnectDelayPolicy: reconnectDelayPolicy
        )
        let profile = GatewayProfile(
            id: "profile", label: "Mac", host: "gateway.test", port: 9_847,
            machineId: "machine", deviceId: "device"
        )
        let harness = Harness(socket: socket, sockets: sockets, client: client, model: model, root: root)
        do {
            await socket.enqueue(helloFrame())
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
        Data(#"{"type":"hello","gatewayVersion":"1.0.0","piVersion":"1.0.0","protocolVersion":5,"minProtocolVersion":5,"machineId":"machine","machineName":"Mac","gatewayChannel":"stable","capabilities":["sessions.v1"]}"#.utf8)
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
