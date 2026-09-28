import Foundation
import Observation
import Synchronization
import Testing
@testable import TronMobile
@testable import TronMobileCore

@MainActor
@Suite("AppModel reconnect delay ownership", .serialized)
struct AppModelReconnectTests {
    @Test("bounded jitter preserves nominal backoff progression and hard cap")
    func policyBoundsAndProgression() {
        let units = SequenceReconnectUnits([0, 0.5, 1, 0, 1, -1, 2, .nan])
        let policy = ReconnectDelayPolicy(nextUnitInterval: units.next)

        #expect(policy.delay(nominalSeconds: 2) == .seconds(1.6))
        #expect(policy.delay(nominalSeconds: 2) == .seconds(2))
        #expect(policy.delay(nominalSeconds: 2) == .seconds(2.4))
        #expect(policy.delay(nominalSeconds: 15) == .seconds(12))
        #expect(policy.delay(nominalSeconds: 15) == .seconds(15))
        #expect(policy.delay(nominalSeconds: 2) == .seconds(1.6))
        #expect(policy.delay(nominalSeconds: 2) == .seconds(2.4))
        #expect(policy.delay(nominalSeconds: 2) == .seconds(2))

        var nominal = policy.initialSeconds
        let expected = [2.0, 3.4, 5.78, 9.826, 15.0, 15.0]
        for value in expected {
            #expect(abs(nominal - value) < 0.000_001)
            nominal = policy.nextNominalSeconds(after: nominal)
        }
    }

    @Test("foreground activation keeps a selected profile without credentials unpaired")
    func missingCredentialDoesNotReconnect() async throws {
        let suiteName = "GatewayLifecycleMissingCredentialTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.removePersistentDomain(forName: suiteName)
        let profile = GatewayProfile(
            id: "gateway", label: "Mac", host: "gateway.test", port: 9_847,
            machineId: "machine", deviceId: "device"
        )
        defaults.set(try JSONEncoder.gateway.encode([profile]), forKey: "gatewayProfiles.v1")
        defaults.set(profile.id, forKey: "selectedGateway.v1")
        let store = GatewayProfileStore(defaults: defaults)
        let factory = ScriptedGatewaySocketFactory(socket: ScriptedGatewaySocket())
        let client = GatewayClient(socketFactory: factory.factory)
        let coordinator = GatewayLifecycleCoordinator(
            client: client,
            profiles: store,
            clock: .continuous,
            reconnectDelayPolicy: .standard,
            uuidSource: .random,
            pairer: GatewayPairer(),
            pairingCommit: { _, _ in },
            profileTokenLookup: { _ in nil }
        )

        coordinator.notePathHint(satisfied: true)
        await coordinator.becameActive()?.value
        await coordinator.start()
        coordinator.notePathHint(satisfied: true)
        #expect(coordinator.connectionState == .unpaired)
        #expect(coordinator.hasResolvedLaunchState)
        #expect(factory.requests.isEmpty)
        if case .some = coordinator.becameActive() {
            Issue.record("Unpaired foreground activation unexpectedly started lifecycle work")
        }
        #expect(coordinator.connectionState == .unpaired)
        #expect(factory.requests.isEmpty)

        await coordinator.teardown()
        await client.close()
    }

    @Test("a path callback before cold startup cannot consume recovery or bypass cached-profile admission")
    func pathHintBeforeStartup() async throws {
        try await withStartupCoordinator { coordinator, projection, factory, _ in
            // Production starts NWPathMonitor before the root task, and sends
            // another path hint before awaiting notification badge cleanup.
            coordinator.notePathHint(satisfied: true)
            await coordinator.becameActive()?.value
            await coordinator.start()

            #expect(coordinator.connectionState == .connected)
            #expect(coordinator.hasResolvedLaunchState)
            #expect(factory.requests.count == 1)
            #expect(projection.cacheLoads == 1)
            // Startup returns at transport readiness; the presentation owner it
            // handed its projection to runs beneath that socket.
            await projection.waitForRefresh(count: 1)
            #expect(projection.refreshCount == 1)
            #expect(projection.failures.isEmpty)
        }
    }

    @Test("initial projection failure retains the live socket and settles reconciliation")
    func initialProjectionFailureKeepsTransport() async throws {
        try await withStartupCoordinator { coordinator, projection, factory, _ in
            projection.setRestoreResult(false)
            await coordinator.start()
            #expect(coordinator.connectionState == .connected)
            await projection.waitForAggregateCompletion(count: 1)
            #expect(projection.aggregateCompletions == [false])
            #expect(factory.requests.count == 1)
        }
    }

    @Test("cold AppModel startup loads authoritative sessions after an early path callback without manual Retry")
    func coldStartupLoadsSessions() async throws {
        try await withFixture(sockets: [ScriptedGatewaySocket()], clock: ManualClock(), units: SequenceReconnectUnits([0])) { fixture in
            let socket = fixture.sockets[0]
            await socket.enqueue(helloFrame())
            fixture.model.lifecycleNotePathHint(satisfied: true)
            await fixture.model.becameActive()?.value
            let start = Task { await fixture.model.start() }
            defer { start.cancel() }
            // Startup admits transport without waiting for optional reads.
            // The catalog owns loading and its eventual atomic publication.
            await start.value
            var index = 1
            var catalog: (id: String, method: String)?
            var inboxFilters: [String] = []
            // The inbox refresh reads one page per server window, so wait for
            // both filters before asserting the startup request set.
            while catalog == nil || Set(inboxFilters) != ["all", "unread"] {
                try await socket.waitUntilSent(count: index + 1)
                let frame = try JSONDecoder.gateway.decode(JSONValue.self, from: await socket.sentFrames()[index]).objectValue
                let method = try #require(frame?["method"]?.stringValue)
                let id = try #require(frame?["id"]?.stringValue)
                index += 1
                if method == "session.list" {
                    catalog = (id: id, method: method)
                } else if method == "notification.inbox.list" {
                    inboxFilters.append(frame?["params"]?.objectValue?["filter"]?.stringValue ?? "")
                } else {
                    #expect(["provider.list", "model.list", "settings.get", "device.list"].contains(method))
                }
            }
            let catalogRequest = try #require(catalog)
            #expect(inboxFilters.sorted() == ["all", "unread"])
            #expect(fixture.model.sessionCatalogIsLoading)
            let startedMethods = try await socket.sentFrames().dropFirst().map { try requestFrame($0).method }
            #expect(Set(startedMethods).isSubset(of: [
                "session.list", "notification.inbox.list", "provider.list", "model.list", "settings.get", "device.list",
            ]))
            #expect(startedMethods.filter { $0 == "notification.inbox.list" }.count == 2)
            let sessions = try JSONValue.encode([startupSummary("loaded")])
            let reply = Task {
                await socket.enqueue(successResponse(id: catalogRequest.id, result: .object([
                    "sessions": sessions, "nextCursor": .null, "listRevision": .number(1),
                    "projectionToken": .string("epoch-1:1")
                ])))
            }
            #expect(await fixture.model.refreshSessions() == .published)
            await reply.value
            #expect(fixture.model.sessions.map(\.id) == ["loaded"])
            #expect(fixture.model.connectionState == .connected)
            #expect(fixture.model.visibleNotices.isEmpty)
            #expect(fixture.socketFactory.requests.count == 1)
        }
    }

    @Test("a catalog read revalidates its retained projection token and a reconnect resumes")
    func conditionalCatalogReadRevalidatesRetainedRevision() async throws {
        try await withFixture(
            sockets: [ScriptedGatewaySocket(), ScriptedGatewaySocket()],
            clock: ManualClock(), units: SequenceReconnectUnits([0])
        ) { fixture in
            let model = fixture.model
            let first = fixture.sockets[0]
            let replacement = fixture.sockets[1]
            let profile = try #require(model.profiles.selected)
            await first.enqueue(helloFrame())
            try await model.connectHostedGateway(profile: profile, token: "token")

            // First authoritative read: one row at revision 4, with no token
            // named because nothing has been retained yet.
            let initial = Task { await model.refreshSessions() }
            let catalog = try await firstCatalogRequest(first, from: 1)
            #expect(catalog.projectionToken == nil)
            await first.enqueue(successResponse(id: catalog.id, result: .object([
                "sessions": try JSONValue.encode([startupSummary("loaded")]),
                "nextCursor": .null,
                "listRevision": .number(4),
                "projectionToken": .string("epoch-one:4:0:user:exclude:0"),
            ])))
            #expect(await initial.value == .published)
            #expect(model.sessions.map(\.id) == ["loaded"])

            // The same connection asks again, naming the token it holds; the
            // Gateway confirms it without rows and nothing is republished.
            let revalidation = Task { await model.refreshSessions() }
            let second = try await firstCatalogRequest(first, from: 2)
            #expect(second.projectionToken == "epoch-one:4:0:user:exclude:0")
            await first.enqueue(successResponse(id: second.id, result: .object([
                "sessions": .array([]),
                "listRevision": .number(4),
                "projectionToken": .string("epoch-one:4:0:user:exclude:0"),
                "notModified": .bool(true),
            ])))
            #expect(await revalidation.value == .published)
            #expect(model.sessions.map(\.id) == ["loaded"])

            // A replacement connection names the retained token too: the token
            // carries the Gateway runtime epoch and every mutable row overlay,
            // so it can only be confirmed when the same Gateway still holds
            // this exact projection.
            await model.handle(GatewayEvent(type: "event", topic: "system.stopping", sessionId: nil, payload: .object([:])))
            try await replacement.waitUntilSent(count: 1)
            await replacement.enqueue(helloFrame(runtimeEpoch: "debug-epoch-2"))
            let reconnected = try await firstCatalogRequest(replacement, from: 1)
            #expect(reconnected.projectionToken == "epoch-one:4:0:user:exclude:0")
            // The projection moved while away, so the Gateway answers rows with
            // the replacement token; the reconnect converges on them.
            await replacement.enqueue(successResponse(id: reconnected.id, result: .object([
                "sessions": try JSONValue.encode([
                    startupSummary("loaded"),
                    startupSummary("added-while-away"),
                ]),
                "nextCursor": .null,
                "listRevision": .number(5),
                "projectionToken": .string("epoch-one:5:2:user:exclude:1"),
            ])))
            for _ in 0..<200 where model.sessions.count != 2 || model.sessionCatalogIsLoading {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(model.sessions.map(\.id) == ["loaded", "added-while-away"])

            // The reconnected read retains the replacement token, so the next
            // revalidation is conditional again.
            let settled = await replacement.sentFrames().count
            let adopted = Task { await model.refreshSessions() }
            let adoptedRequest = try await firstCatalogRequest(replacement, from: settled)
            #expect(adoptedRequest.projectionToken == "epoch-one:5:2:user:exclude:1")
            await replacement.enqueue(successResponse(id: adoptedRequest.id, result: .object([
                "sessions": .array([]),
                "listRevision": .number(5),
                "projectionToken": .string("epoch-one:5:2:user:exclude:1"),
                "notModified": .bool(true),
            ])))
            #expect(await adopted.value == .published)
            #expect(model.sessions.map(\.id) == ["loaded", "added-while-away"])
            await model.teardown()
        }
    }

    @Test("a reconnect whose catalog read is unchanged still rebuilds the dashboard's row projection")
    func unchangedReconnectRebuildsRowProjection() async throws {
        try await withFixture(
            sockets: [ScriptedGatewaySocket(), ScriptedGatewaySocket()],
            clock: ManualClock(), units: SequenceReconnectUnits([0])
        ) { fixture in
            let model = fixture.model
            let first = fixture.sockets[0]
            let replacement = fixture.sockets[1]
            let profile = try #require(model.profiles.selected)
            await first.enqueue(helloFrame())
            try await model.connectHostedGateway(profile: profile, token: "token")

            let initial = Task { await model.refreshSessions() }
            let catalog = try await firstCatalogRequest(first, from: 1)
            await first.enqueue(successResponse(id: catalog.id, result: .object([
                "sessions": try JSONValue.encode([waitingSummary("waiting")]),
                "nextCursor": .null,
                "listRevision": .number(4),
                "projectionToken": .string("epoch-one:4:0:user:exclude:0"),
            ])))
            #expect(await initial.value == .published)
            #expect(model.dashboardActivity(for: "waiting") == .waitingForUser)

            // The connection ends. The retained token survives it, the
            // projection loses liveness, and the dashboard's snapshot is read
            // in this state: a row that is not idle reads "resuming".
            await model.handle(GatewayEvent(
                type: "event", topic: "system.stopping", sessionId: nil, payload: .object([:])
            ))
            #expect(model.dashboardActivity(for: "waiting") == .resuming)
            let presentationBefore = model.dashboardPresentationRevision
            let archiveBefore = model.archiveProjectionRevision

            // The replacement connection names the retained token and the
            // Gateway answers unchanged, without rows. The rows are untouched,
            // but the two projections the view watches must move, because the
            // snapshot it holds was taken while the catalog was retired.
            try await replacement.waitUntilSent(count: 1)
            await replacement.enqueue(helloFrame())
            let reconnected = try await firstCatalogRequest(replacement, from: 1)
            #expect(reconnected.projectionToken == "epoch-one:4:0:user:exclude:0")
            await replacement.enqueue(successResponse(id: reconnected.id, result: .object([
                "sessions": .array([]),
                "listRevision": .number(4),
                "projectionToken": .string("epoch-one:4:0:user:exclude:0"),
                "notModified": .bool(true),
            ])))
            // The response is consumed asynchronously, and the reconnect's own
            // presentation restoration moves the dashboard revision for its own
            // reason, so the archive projection — which only catalog authority
            // moves — is the signal that the answer landed.
            for _ in 0..<200 where model.archiveProjectionRevision == archiveBefore {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(model.sessions.map(\.id) == ["waiting"])
            #expect(model.dashboardPresentationRevision > presentationBefore)
            #expect(model.archiveProjectionRevision > archiveBefore)
            #expect(model.dashboardActivity(for: "waiting") == .waitingForUser)
            await model.teardown()
        }
    }

    /// Answers every non-catalog request until one `session.list` arrives, then
    /// returns it. Startup reads are independent owners, so the traversal's
    /// position in the frame stream is the only stable ordering.
    private func firstCatalogRequest(
        _ socket: ScriptedGatewaySocket,
        from start: Int,
        within attempts: Int = 40
    ) async throws -> (id: String, projectionToken: String?) {
        var index = start
        for _ in 0..<attempts {
            try await socket.waitUntilSent(count: index + 1)
            let value = try JSONDecoder.gateway.decode(JSONValue.self, from: await socket.sentFrames()[index])
            index += 1
            let object = try #require(value.objectValue)
            let method = object["method"]?.stringValue
            let id = object["id"]?.stringValue
            guard let id else { continue }
            if method == "session.list" {
                return (id: id, projectionToken: object["params"]?.objectValue?["projectionToken"]?.stringValue)
            }
            // Independent optional owners (providers, settings, devices,
            // inbox) must not stall the traversal under test.
            await socket.enqueue(successResponse(id: id, result: .object([:])))
        }
        Issue.record("No session.list request arrived")
        return (id: "missing", projectionToken: nil)
    }

    @Test("replacement reconnect restores mounted authority before an optional catalog page responds",
          arguments: [false, true])
    func replacementReadinessDoesNotAwaitCatalog(holdContinuation: Bool) async throws {
        try await withFixture(
            sockets: [ScriptedGatewaySocket(), ScriptedGatewaySocket()],
            clock: ManualClock(), units: SequenceReconnectUnits([])
        ) { fixture in
            let model = fixture.model
            let first = fixture.sockets[0]
            let replacement = fixture.sockets[1]
            let profile = try #require(model.profiles.selected)
            await first.enqueue(helloFrame())
            try await model.connectHostedGateway(profile: profile, token: "token")
            let snapshot = try SessionScenarioBuilder(seed: 47_021).openingTail(targetEncodedBytes: 10_000)
            model.installHostedSubscribedSnapshot(snapshot)
            model.sessions = [startupSummary(snapshot.sessionId)]
            let target = try #require(model.mountedPresentationTarget)
            let scope = try #require(model.composerDrafts.scope(for: target))
            #expect(model.setHostedComposerText("Retain this draft", sessionID: snapshot.sessionId))
            let baseline = model.foregroundReconciliationGeneration
            let completed = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
            defer { completed.continuation.finish() }
            withObservationTracking {
                _ = model.foregroundReconciliationGeneration
            } onChange: {
                completed.continuation.yield(())
            }

            await model.enteredBackground().value
            #expect(!model.admitsLiveSessionCommands(target))
            await model.becameActive()?.value // Join retirement; replacement owns its own flight.
            try await replacement.waitUntilSent(count: 1)
            await replacement.enqueue(helloFrame())
            var recovered = snapshot
            recovered.revision += 1
            recovered.eventSequence += 1
            var index = 1
            var catalogID: String?
            var catalogPages = 0
            var synchronized = false
            while !synchronized || catalogID == nil {
                try await replacement.waitUntilSent(count: index + 1)
                let request = try requestFrame(await replacement.sentFrames()[index])
                index += 1
                switch request.method {
                case "session.list":
                    catalogPages += 1
                    #expect(catalogID == nil)
                    if holdContinuation && catalogPages == 1 {
                        await replacement.enqueue(successResponse(id: request.id, result: .object([
                            "sessions": try JSONValue.encode([startupSummary(snapshot.sessionId)]),
                            "listRevision": .number(1), "projectionToken": .string("epoch-1:1:0:user:exclude:0"),
                            "nextCursor": .string("next-page"),
                        ])))
                    } else {
                        catalogID = request.id // Intentionally keep this page pending.
                    }
                case "session.open":
                    await replacement.enqueue(successResponse(id: request.id, result: .object([
                        "session": try JSONValue.encode(recovered),
                        "syncToken": .string("replacement-sync"),
                        "subscriptionToken": .string("replacement-subscription"),
                    ])))
                case "session.sync":
                    #expect(model.isReconcilingForeground)
                    #expect(!model.admitsLiveSessionCommands(target))
                    await replacement.enqueue(successResponse(
                        id: request.id, result: .object(["synchronized": .bool(true)])
                    ))
                    synchronized = true
                case "provider.list", "model.list", "settings.get", "device.list":
                    #expect(synchronized, "Optional catalog/settings/device reads must wait for mounted synchronization.")
                case "notification.inbox.list":
                    break // The inbox is an independent optional owner.
                default:
                    Issue.record("Unexpected request before mounted synchronization: \(request.method)")
                    throw CancellationError()
                }
            }
            // An observed aggregate completion, not a fixed sleep or a mock
            // refresh result, proves the true replacement executor can finish.
            try await withTestWatchdog(timeout: .seconds(2)) {
                var iterator = completed.stream.makeAsyncIterator()
                guard await iterator.next() != nil else { throw CancellationError() }
            }
            #expect(model.connectionState == .connected)
            #expect(!model.isReconcilingForeground)
            #expect(model.foregroundReconciliationGeneration == baseline + 1)
            #expect(model.mountedPresentationTarget == target)
            #expect(model.authoritativeSnapshot(for: snapshot.sessionId)?.revision == recovered.revision)
            #expect(model.admitsLiveSessionCommands(target))
            #expect(model.composerDrafts.text(for: scope) == "Retain this draft")
            #expect(!model.visibleNotices.contains { $0.replacement?.key == .gatewayRecovery })
            #expect(fixture.socketFactory.requests.count == 2)

            #expect(model.sessions.map(\.id) == [snapshot.sessionId])
            #expect(model.sessionCatalogIsLoading)
            let pendingCatalog = try #require(catalogID)
            let remaining = holdContinuation ? [] : [startupSummary(snapshot.sessionId)]
            let reply = Task {
                await replacement.enqueue(successResponse(id: pendingCatalog, result: .object([
                    "sessions": try JSONValue.encode(remaining), "listRevision": .number(1),
                    "projectionToken": .string("epoch-1:1:0:user:exclude:0"),
                ])))
            }
            #expect(await model.refreshSessions() == .published)
            try await reply.value
            #expect(model.sessions.map(\.id) == [snapshot.sessionId])
            #expect(model.foregroundReconciliationGeneration == baseline + 1)
        }
    }

    @Test("a canceled startup cache read cannot replace the foreground session catalog")
    func canceledStartupCacheCannotPublish() async throws {
        try await withFixture(sockets: [ScriptedGatewaySocket()], clock: ManualClock(), units: SequenceReconnectUnits([])) { fixture in
            let cache = SnapshotCache(root: fixture.cacheRoot)
            await cache.save(profileID: "gateway", sessions: [startupSummary("cached")])
            let admission = GatewayLifecycleCoordinator.Admission(generation: 0, connectionID: nil)
            await fixture.model.lifecycleLoadCache(profileID: "gateway", admission: admission)
            #expect(fixture.model.sessions.map(\.id) == ["cached"])
            fixture.model.sessions = [startupSummary("current")]
            let read = Task {
                await fixture.model.lifecycleLoadCache(profileID: "gateway", admission: admission)
            }
            read.cancel()
            await read.value
            #expect(fixture.model.sessions.map(\.id) == ["current"])
        }
    }

    @Test("path and foreground callbacks cannot steal startup or a profile switch during cache loading",
          arguments: [false, true])
    func pathHintDuringStartupCache(switching: Bool) async throws {
        let gate = TestReadGate()
        try await withStartupCoordinator(cacheGate: gate) { coordinator, projection, factory, _ in
            let target = switching ? coordinator.profiles.profiles[1] : coordinator.profiles.selected!
            let start = Task {
                if switching { await coordinator.switchGateway(target) }
                else { await coordinator.start() }
            }
            do {
                try await gate.waitForEntry()
                coordinator.notePathHint(satisfied: true)
                await coordinator.becameActive()?.value
                #expect(factory.requests.isEmpty)
            } catch {
                await gate.release()
                await start.value
                throw error
            }
            await gate.release()
            await start.value
            #expect(coordinator.connectionState == .connected)
            #expect(factory.requests.count == 1)
            #expect(projection.cacheLoads == 1)
            #expect(factory.requests.first?.url?.host == target.host)
            #expect(factory.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer token-for-\(target.id)")
        }
    }

    @Test("a repeated start preserves the existing admission instead of loading cache and connecting twice")
    func repeatedStartDuringCache() async throws {
        let gate = TestReadGate()
        try await withStartupCoordinator(cacheGate: gate) { coordinator, projection, factory, _ in
            let first = Task { await coordinator.start() }
            do {
                try await gate.waitForEntry()
                try await withTestWatchdog(timeout: .seconds(1)) {
                    await withTaskCancellationHandler {
                        await coordinator.start()
                    } onCancel: {
                        Task { await gate.release() }
                    }
                }
                #expect(projection.cacheLoads == 1)
                #expect(factory.requests.isEmpty)
            } catch {
                await gate.release()
                await first.value
                throw error
            }
            await gate.release()
            await first.value
            #expect(coordinator.connectionState == .connected)
            #expect(factory.requests.count == 1)
        }
    }

    @Test("background before the first hello resumes the selected profile and fences late cache completion")
    func backgroundDuringStartupCache() async throws {
        let gate = TestReadGate()
        try await withStartupCoordinator(cacheGate: gate) { coordinator, projection, factory, socket in
            let start = Task { await coordinator.start() }
            do {
                try await gate.waitForEntry()
                coordinator.enteredBackground()
                await coordinator.becameActive()?.value // Join exact retirement.
                await coordinator.becameActive()?.value // Join its replacement.
                #expect(coordinator.connectionState == .connected)
                #expect(coordinator.hasResolvedLaunchState)
                #expect(factory.requests.count == 1)
                #expect(factory.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer token-for-gateway")
                await projection.waitForRefresh(count: 1)
                #expect(projection.refreshCount == 1)
            } catch {
                await gate.release()
                await start.value
                throw error
            }
            await gate.release()
            await start.value
            #expect(coordinator.connectionState == .connected)
            #expect(factory.requests.count == 1)
            #expect(await socket.closeInvocationCount() == 0)
        }
    }

    @Test("path return during initial hello cannot start a second socket")
    func pathHintDoesNotOverlapInitialConnect() async throws {
        let clock = ManualClock()
        try await withFixture(
            sockets: [ScriptedGatewaySocket(), ScriptedGatewaySocket()],
            clock: clock,
            units: SequenceReconnectUnits([0])
        ) { fixture in
            let start = Task { await fixture.model.start() }
            defer { start.cancel() }
            try await fixture.sockets[0].waitUntilSent(count: 1)
            fixture.model.lifecycleNotePathHint(satisfied: true)
            for _ in 0..<20 { await Task.yield() }
            #expect(fixture.socketFactory.requests.count == 1)
            await fixture.sockets[0].failPendingReceivers(CancellationError())
            await start.value
        }
    }

    @Test("non-immediate retries jitter each preserved backoff delay")
    func jitteredRetryProgression() async throws {
        let units = SequenceReconnectUnits([0, 0.5, 1])
        let clock = ManualClock()
        try await withFixture(
            sockets: (0..<4).map { _ in ScriptedGatewaySocket() },
            clock: clock,
            units: units
        ) { fixture in
            let start = Task { await fixture.model.start() }
            defer { start.cancel() }
            try await failHandshake(fixture.sockets[0])
            try await clock.waitUntilSleeping(count: 1)
            await start.value
            #expect(clock.recordedSleeps() == [.seconds(1.6)])

            clock.advance(by: .seconds(1.6))
            try await failHandshake(fixture.sockets[1])
            try await clock.waitUntilSleeping(count: 1)
            #expect(clock.recordedSleeps() == [.seconds(1.6), .seconds(3.4000000000000004)])
            #expect(fixture.socketFactory.requests.count == 2)
            #expect(fixture.socketFactory.requests.count == 2)
        }
    }

    @Test("foreground activation cancels a delayed retry and connects immediately once")
    func foregroundAcceleratesDelayedRetryOnce() async throws {
        let units = SequenceReconnectUnits([0])
        let clock = ManualClock()
        try await withFixture(
            sockets: (0..<3).map { _ in ScriptedGatewaySocket() },
            clock: clock,
            units: units
        ) { fixture in
            let start = Task { await fixture.model.start() }
            defer { start.cancel() }
            try await failHandshake(fixture.sockets[0])
            try await clock.waitUntilSleeping(count: 1)
            await start.value

            fixture.model.becameActive()
            fixture.model.becameActive()
            try await fixture.sockets[1].waitUntilSent(count: 1)
            await Task.yield()

            #expect(clock.activeSleeperCount() == 0)
            #expect(clock.recordedSleeps() == [.seconds(1.6)])
            #expect(fixture.socketFactory.requests.count == 2)
            #expect(fixture.model.connectionState == .reconnecting)
        }
    }

    @Test("a path return cancels a pending backoff wait, attempts at once and restarts the curve")
    func pathReturnCancelsPendingBackoff() async throws {
        let clock = ManualClock()
        let sockets = (0..<3).map { _ in ScriptedGatewaySocket() }
        try await withFixture(sockets: sockets, clock: clock, units: SequenceReconnectUnits([0, 0, 0])) { fixture in
            let start = Task { await fixture.model.start() }
            defer { start.cancel() }
            try await failHandshake(sockets[0])
            try await clock.waitUntilSleeping(count: 1, duration: .seconds(1.6))
            await start.value
            #expect(fixture.socketFactory.requests.count == 1)

            // The route changed while the wait was pending (a Wi-Fi/cellular or
            // Tailscale handoff keeps the path satisfied): the wait is cancelled
            // and the phone attempts at once instead of running it out.
            fixture.model.lifecycleNotePathHint(satisfied: true)
            try await sockets[1].waitUntilSent(count: 1)
            for _ in 0..<20 { await Task.yield() }
            #expect(clock.activeSleeperCount() == 0)
            #expect(clock.recordedSleeps() == [.seconds(1.6)])
            #expect(fixture.socketFactory.requests.count == 2)

            // That attempt fails on the new route: because the path change also
            // restarted the curve, the wait after it is the base interval again
            // rather than the second step the closed route had grown.
            try await failHandshake(sockets[1])
            try await sockets[1].waitUntilClosed()
            try await clock.waitUntilSleeping(count: 1, duration: .seconds(1.6))
            #expect(clock.recordedSleeps() == [.seconds(1.6), .seconds(1.6)])
        }
    }

    @Test("a path notice during a reconnect attempt starts no second socket")
    func pathNoticeDuringReconnectAttemptStartsNoSecondSocket() async throws {
        let clock = ManualClock()
        let sockets = (0..<3).map { _ in ScriptedGatewaySocket() }
        try await withFixture(sockets: sockets, clock: clock, units: SequenceReconnectUnits([0, 0, 0])) { fixture in
            let start = Task { await fixture.model.start() }
            defer { start.cancel() }
            try await failHandshake(sockets[0])
            try await clock.waitUntilSleeping(count: 1, duration: .seconds(1.6))
            await start.value

            // The retry's hello is unanswered, so this attempt is in flight.
            clock.advance(by: .seconds(1.6))
            try await sockets[1].waitUntilSent(count: 1)

            fixture.model.lifecycleNotePathHint(satisfied: true)
            fixture.model.lifecycleNotePathHint(satisfied: true)
            for _ in 0..<20 { await Task.yield() }
            #expect(fixture.socketFactory.requests.count == 2)

            // The in-flight attempt keeps its own deadline, its failure
            // schedules the next wait on the same loop, and neither path notice
            // put a third socket on the wire.
            try await failHandshake(sockets[1])
            try await sockets[1].waitUntilClosed()
            try await clock.waitUntilSleeping(count: 1, duration: .seconds(2.72))
            #expect(fixture.socketFactory.requests.count == 2)
        }
    }

    @Test("two never-opened connect failures publish no-path until a handshake succeeds")
    func twoNeverOpenedFailuresPublishNoPath() async throws {
        let clock = ManualClock()
        let recoveryClock = ManualClock()
        let sockets = (0..<3).map { _ in ScriptedGatewaySocket() }
        for socket in sockets.prefix(2) {
            await socket.failNextSend(GatewayFailure(
                code: "timeout", message: "synthetic timeout", retryable: true, details: nil
            ))
        }
        try await withFixture(
            sockets: sockets, clock: clock,
            units: SequenceReconnectUnits(Array(repeating: 0, count: 20)), recoveryClock: recoveryClock
        ) { fixture in
            let start = Task { await fixture.model.start() }
            try await clock.waitUntilSleeping(count: 1)
            await start.value
            #expect(fixture.model.dashboardServerState(for: "gateway") == .reconnecting)

            clock.advance(by: .seconds(60))
            try await sockets[1].waitUntilSendInvoked(count: 1)
            for _ in 0..<100 where fixture.model.dashboardServerState(for: "gateway") != .noPath(nil) {
                await Task.yield()
            }
            #expect(fixture.model.dashboardServerState(for: "gateway") == .noPath(nil))
            try await recoveryClock.waitUntilSleeping(count: 1, duration: .seconds(2))
            recoveryClock.advance(by: .seconds(2))
            for _ in 0..<10 { await Task.yield() }
            let noPathNotice = try #require(fixture.model.visibleNotices.first { $0.replacement?.key == .gatewayRecovery })
            #expect(noPathNotice.title == "No path to this Mac")

            try await clock.waitUntilSleeping(count: 1)
            await sockets[2].enqueue(helloFrame())
            clock.advance(by: .seconds(60))
            try await sockets[2].waitUntilSent(count: 1)
            while fixture.model.connectionState != .connected {
                await Task.yield()
            }
            #expect(fixture.model.dashboardServerState(for: "gateway") == .connected)
        }
    }

    @Test("stale scripted connect failures cannot relabel a newer connected attempt")
    func staleConnectFailureClassificationIsFenced() async throws {
        let clock = ManualClock()
        let sockets = (0..<4).map { _ in ScriptedGatewaySocket() }
        let factory = ScriptedGatewaySocketFactory(sockets: sockets)
        let client = GatewayClient(socketFactory: factory.factory, clock: clock.clock)
        let profile = GatewayProfile(
            id: "gateway", label: "Mac", host: "gateway.test", port: 9_847,
            machineId: "machine", deviceId: "device"
        )
        await sockets[0].enqueue(helloFrame())
        _ = try await client.connectForLifecycle(profile: profile, token: "token")

        var classifier = GatewayConnectionFailureClassifier()
        var lateFailures: [(generation: Int, diagnostic: GatewayConnectionDiagnostic)] = []
        for index in 1...2 {
            let generation = classifier.beginAttempt()
            let diagnosticSequence = await client.latestDiagnosticSequence()
            await sockets[index].failNextSend(GatewayFailure(
                code: "timeout", message: "synthetic timeout", retryable: true, details: nil
            ))
            do {
                _ = try await client.reconnectForLifecycle(
                    profile: profile, token: "token", attemptID: "stale-\(index)"
                )
                Issue.record("Scripted handshake unexpectedly succeeded")
            } catch { }
            let diagnostic = try #require(await client.latestHandshakeDiagnostic(after: diagnosticSequence))
            #expect(diagnostic.stage == .transportOpen)
            #expect(diagnostic.handshake?.transportOpened == false)
            lateFailures.append((generation, diagnostic))
        }

        await sockets[3].enqueue(helloFrame())
        _ = try await client.reconnectForLifecycle(profile: profile, token: "token", attemptID: "newer")
        classifier.reset()
        #expect(classifier.noPath == nil)
        for failure in lateFailures {
            let applied = classifier.failedAttempt(
                failure.diagnostic,
                code: "timeout",
                attemptGeneration: failure.generation
            )
            #expect(!applied)
        }
        #expect(classifier.noPath == nil)

        var negativeControl = GatewayConnectionFailureClassifier()
        for failure in lateFailures {
            _ = negativeControl.failedAttempt(failure.diagnostic, code: "timeout")
        }
        #expect(negativeControl.noPath != nil)
        await client.close()
    }

    @Test("transient failures keep retrying with capped backoff until a handshake succeeds")
    func retriesTenFailuresThenConnects() async throws {
        let clock = ManualClock()
        let sockets = (0..<12).map { _ in ScriptedGatewaySocket() }
        let units = SequenceReconnectUnits(Array(repeating: 0.5, count: 16))
        try await withFixture(sockets: sockets, clock: clock, units: units) { fixture in
            let start = Task { await fixture.model.start() }
            try await failHandshake(sockets[0])
            try await clock.waitUntilSleeping(count: 1)
            await start.value

            for index in 1...10 {
                clock.advance(by: .seconds(60))
                try await sockets[index].waitUntilSent(count: 1)
                try await failHandshake(sockets[index])
                try await sockets[index].waitUntilClosed()
                try await clock.waitUntilSleeping(count: 1)
            }
            await sockets[11].enqueue(helloFrame())
            clock.advance(by: .seconds(60))
            try await sockets[11].waitUntilSent(count: 1)
            while fixture.model.connectionState != .connected {
                try Task.checkCancellation()
                await Task.yield()
            }
            #expect(fixture.socketFactory.requests.count == 12)
            #expect(fixture.model.connectionState == .connected)
        }
    }

    @Test("an unsatisfied path pauses retry and path return resumes immediately")
    func noPathPausesAndPathReturnResumes() async throws {
        let clock = ManualClock()
        let sockets = (0..<3).map { _ in ScriptedGatewaySocket() }
        try await withFixture(sockets: sockets, clock: clock, units: SequenceReconnectUnits([0])) { fixture in
            let start = Task { await fixture.model.start() }
            try await failHandshake(sockets[0])
            try await clock.waitUntilSleeping(count: 1)
            await start.value
            fixture.model.lifecycleNotePathHint(satisfied: false)
            try await clock.waitUntilSleeping(
                count: 1, duration: GatewayLifecycleCoordinator.parkedRetryBound
            )
            // The hint pauses the loop: nothing attempts before the parked bound.
            clock.advance(by: GatewayLifecycleCoordinator.parkedRetryBound - .seconds(5))
            for _ in 0..<20 { await Task.yield() }
            #expect(fixture.socketFactory.requests.count == 1)
            // The bound probes the stale hint instead of leaving the phone quiet,
            // and that probe consumes the failed attempt.
            clock.advance(by: .seconds(10))
            try await sockets[1].waitUntilSent(count: 1)
            #expect(fixture.socketFactory.requests.count == 2)
            await sockets[1].enqueue(helloFrame())
            while fixture.model.connectionState != .connected {
                try Task.checkCancellation()
                await Task.yield()
            }
        }
    }

    @Test("a park and its resume reach the phone's persisted diagnostic log")
    func parkedRecoveryReachesTheDiagnosticLog() async throws {
        let clock = ManualClock()
        let sockets = (0..<3).map { _ in ScriptedGatewaySocket() }
        try await withFixture(sockets: sockets, clock: clock, units: SequenceReconnectUnits([0])) { fixture in
            let start = Task { await fixture.model.start() }
            try await failHandshake(sockets[0])
            try await clock.waitUntilSleeping(count: 1)
            await start.value
            fixture.model.lifecycleNotePathHint(satisfied: false)
            try await clock.waitUntilSleeping(
                count: 1, duration: GatewayLifecycleCoordinator.parkedRetryBound
            )
            let parked = await fixture.model.loadGatewayLogsResult(limit: 200, includeRemote: false)
            #expect(parked.records.contains {
                $0.record.event == "gateway.lifecycle"
                    && $0.record.message.contains("kind=reconnect.parked")
                    && $0.record.message.contains("reason=pathUnsatisfied")
            })

            // The bound probes the stale hint without a callback, and that probe
            // is its own cause on the timeline.
            await sockets[1].enqueue(helloFrame())
            clock.advance(by: GatewayLifecycleCoordinator.parkedRetryBound)
            try await sockets[1].waitUntilSent(count: 1)
            let resumed = await fixture.model.loadGatewayLogsResult(limit: 200, includeRemote: false)
            #expect(resumed.records.contains {
                $0.record.event == "gateway.lifecycle"
                    && $0.record.message.contains("kind=reconnect.parked-resume")
            })
        }
    }

    @Test("a refused reconnect from the notification route poll reaches the phone log")
    func refusedReconnectFromRoutePollReachesTheLog() async throws {
        let clock = ManualClock()
        let sockets = (0..<3).map { _ in ScriptedGatewaySocket() }
        try await withFixture(sockets: sockets, clock: clock, units: SequenceReconnectUnits([0, 0])) { fixture in
            let start = Task { await fixture.model.start() }
            await sockets[0].enqueue(helloFrame())
            try await sockets[0].waitUntilSent(count: 1)
            while fixture.model.connectionState != .connected {
                try Task.checkCancellation()
                await Task.yield()
            }
            await start.value

            // The live socket drops and its replacement is refused for good, so
            // recovery is stopped and `.offline` is what offers the user Retry.
            await sockets[1].failNextSend(GatewayFailure(
                code: "forbidden", message: "This device is no longer allowed.",
                retryable: false, details: nil
            ))
            await sockets[0].failPendingReceivers(URLError(.networkConnectionLost))
            try await sockets[0].waitUntilClosed()
            for _ in 0..<600 {
                if case .offline = fixture.model.connectionState { break }
                try? await Task.sleep(for: .milliseconds(2))
            }
            guard case .offline = fixture.model.connectionState else {
                Issue.record("the stopped replacement left \(fixture.model.connectionState)")
                return
            }

            // Opening a notification waits for the route by asking for recovery
            // every 100 ms. The stop must refuse that by name instead of
            // publishing a recovery state that no user action can leave.
            let route = Task {
                try await fixture.model.navigationRoute(for: PushNotificationTap(
                    sessionID: "session-from-push", machineID: "machine"
                ))
            }
            for _ in 0..<60 { await Task.yield() }
            route.cancel()
            _ = try? await route.value
            guard case .offline = fixture.model.connectionState else {
                Issue.record("the route poll replaced the stop with \(fixture.model.connectionState)")
                return
            }

            let records = await fixture.model.loadGatewayLogsResult(limit: 200, includeRemote: false)
            #expect(records.records.contains {
                $0.record.event == "gateway.lifecycle"
                    && $0.record.message.contains("kind=reconnect.skipped")
                    && $0.record.message.contains("reason=nonRetryable")
            })
        }
    }

    @Test("path loss on an active socket pauses replacement until the path returns")
    func pathLossDuringActiveConnectionPausesReplacement() async throws {
        let clock = ManualClock()
        let sockets = (0..<3).map { _ in ScriptedGatewaySocket() }
        try await withFixture(sockets: sockets, clock: clock, units: SequenceReconnectUnits([0])) { fixture in
            let start = Task { await fixture.model.start() }
            await sockets[0].enqueue(helloFrame())
            try await sockets[0].waitUntilSent(count: 1)
            while fixture.model.connectionState != .connected {
                try Task.checkCancellation()
                await Task.yield()
            }
            await start.value

            fixture.model.lifecycleNotePathHint(satisfied: false)
            await sockets[0].failPendingReceivers(URLError(.networkConnectionLost))
            try await sockets[0].waitUntilClosed()
            try await clock.waitUntilSleeping(
                count: 1, duration: GatewayLifecycleCoordinator.parkedRetryBound
            )
            clock.advance(by: GatewayLifecycleCoordinator.parkedRetryBound - .seconds(5))
            for _ in 0..<20 { await Task.yield() }
            #expect(fixture.socketFactory.requests.count == 1)

            fixture.model.lifecycleNotePathHint(satisfied: true)
            try await sockets[1].waitUntilSent(count: 1)
            #expect(fixture.socketFactory.requests.count == 2)
            await sockets[1].enqueue(helloFrame())
            while fixture.model.connectionState != .connected {
                try Task.checkCancellation()
                await Task.yield()
            }
        }
    }

    @Test("authentication failure stops recovery until explicit Retry")
    func authenticationFailureStopsUntilRetry() async throws {
        let clock = ManualClock()
        let sockets = [ScriptedGatewaySocket(), ScriptedGatewaySocket()]
        try await withFixture(sockets: sockets, clock: clock, units: SequenceReconnectUnits([0])) { fixture in
            let start = Task { await fixture.model.start() }
            try await sockets[0].waitUntilSent(count: 1)
            await sockets[0].failPendingReceivers(GatewayFailure(
                code: "unauthenticated", message: "Pair this Gateway again.", retryable: false, details: nil
            ))
            try await sockets[0].waitUntilClosed()
            await start.value
            #expect(fixture.model.connectionState == .unauthorized)
            #expect(fixture.socketFactory.requests.count == 1)

            let profile = GatewayProfile(
                id: "gateway", label: "Mac", host: "gateway.test", port: 9_847,
                machineId: "machine", deviceId: "device"
            )
            fixture.model.retryGatewayConnection(for: profile)
            try await sockets[1].waitUntilSent(count: 1)
            await sockets[1].enqueue(helloFrame())
            while fixture.model.connectionState != .connected {
                try Task.checkCancellation()
                await Task.yield()
            }
            #expect(fixture.socketFactory.requests.count == 2)
        }
    }

    @Test("a non-retryable stop keeps its Retry surface while the route poll asks again")
    func nonRetryableStopSurvivesTheRoutePoll() async throws {
        let clock = ManualClock()
        let logURL = FileManager.default.temporaryDirectory
            .appending(path: "reconnect-stopped-poll-\(UUID().uuidString).jsonl")
        defer {
            try? FileManager.default.removeItem(at: logURL)
            try? FileManager.default.removeItem(at: logURL.appendingPathExtension("1"))
        }
        let appLog = AppLog(fileURL: logURL)
        let projection = NoopGatewayLifecycleProjection()
        try await withRecordedCoordinator(
            sockets: (0..<3).map { _ in ScriptedGatewaySocket() },
            clock: clock, watchdogClock: clock.clock, appLog: appLog, projection: projection
        ) { coordinator, client, sockets in
            await sockets[0].enqueue(helloFrame())
            await coordinator.start()
            #expect(coordinator.connectionState == .connected)
            await coordinator.noteDisconnected(connectionID: await client.activeConnectionID())
            // The replacement attempt is refused for good: recovery stops and
            // `.offline` is the status that offers the user Retry.
            await sockets[1].failNextSend(GatewayFailure(
                code: "forbidden", message: "This device is no longer allowed.",
                retryable: false, details: nil
            ))
            coordinator.requestReconnect(immediate: true)
            _ = try await waitForRecords(in: appLog, event: "gateway.attempt", count: 2)
            guard case .offline = coordinator.connectionState else {
                Issue.record("the failed replacement left \(coordinator.connectionState)")
                return
            }
            await projection.waitForAggregateCompletion(count: 1)

            // The route the notification needs is gone, and the readiness poll
            // asks for recovery every 100 ms. None of those requests may turn a
            // stop into a recovery state nothing can leave.
            coordinator.notePathHint(satisfied: false)
            let admission = try #require(coordinator.generationAdmission)
            let poll = Task {
                await coordinator.waitForRouteConnection(
                    profileID: "gateway", until: clock.clock.now() + .seconds(5),
                    admission: admission
                )
            }
            for _ in 0..<40 { await Task.yield() }
            poll.cancel()
            #expect(await poll.value == nil)
            guard case .offline = coordinator.connectionState else {
                Issue.record("the route poll replaced the stop with \(coordinator.connectionState)")
                return
            }
            #expect(
                projection.diagnostics.contains {
                    $0.hasPrefix("reconnect.skipped ") && $0.contains("reason=nonRetryable")
                }
            )
            #expect(!projection.diagnostics.contains { $0.hasPrefix("reconnect.parked ") })

            // Explicit Retry is still the way out, and it still works.
            await sockets[2].enqueue(helloFrame())
            coordinator.retryReconnect()
            try await sockets[2].waitUntilSent(count: 1)
            while coordinator.connectionState != .connected {
                try Task.checkCancellation()
                await Task.yield()
            }
        }
    }

    @Test("a workspace retry cannot retry a credential the Gateway already rejected")
    func transientTransportRetryLeavesUnauthorized() async throws {
        let clock = ManualClock()
        let sockets = [ScriptedGatewaySocket(), ScriptedGatewaySocket()]
        let logURL = FileManager.default.temporaryDirectory
            .appending(path: "transient-unauthorized-\(UUID().uuidString).jsonl")
        defer {
            try? FileManager.default.removeItem(at: logURL)
            try? FileManager.default.removeItem(at: logURL.appendingPathExtension("1"))
        }
        let appLog = AppLog(fileURL: logURL)
        try await withFixture(
            sockets: sockets, clock: clock, units: SequenceReconnectUnits([0]), appLog: appLog
        ) { fixture in
            let start = Task { await fixture.model.start() }
            try await sockets[0].waitUntilSent(count: 1)
            await sockets[0].failPendingReceivers(GatewayFailure(
                code: "unauthenticated", message: "Pair this Gateway again.",
                retryable: false, details: nil
            ))
            try await sockets[0].waitUntilClosed()
            await start.value
            #expect(fixture.model.connectionState == .unauthorized)

            // The browser's transient-error retry is neither a scene activation
            // nor an explicit Retry: it may revive a parked route, and a
            // credential the Gateway rejected is not a parked route. It must
            // leave the state, the attempts and the schedule untouched instead
            // of retrying the token and flickering the unauthorized surface.
            let sleepersBefore = clock.activeSleeperCount()
            fixture.model.recoverTransientTransportFailure()
            for _ in 0..<20 { await Task.yield() }
            #expect(fixture.model.connectionState == .unauthorized)
            #expect(fixture.socketFactory.requests.count == 1)
            #expect(clock.activeSleeperCount() == sleepersBefore)
            #expect(await recordCount(in: appLog, event: "gateway.attempt") == 1)
        }
    }

    @Test("a workspace retry cannot replace a live connection")
    func transientTransportRetryLeavesConnectedTransport() async throws {
        let clock = ManualClock()
        let sockets = [ScriptedGatewaySocket(), ScriptedGatewaySocket()]
        let logURL = FileManager.default.temporaryDirectory
            .appending(path: "transient-connected-\(UUID().uuidString).jsonl")
        defer {
            try? FileManager.default.removeItem(at: logURL)
            try? FileManager.default.removeItem(at: logURL.appendingPathExtension("1"))
        }
        let appLog = AppLog(fileURL: logURL)
        try await withFixture(
            sockets: sockets, clock: clock, units: SequenceReconnectUnits([0]), appLog: appLog
        ) { fixture in
            await sockets[0].enqueue(helloFrame())
            let start = Task { await fixture.model.start() }
            defer { start.cancel() }
            await start.value
            #expect(fixture.model.connectionState == .connected)
            #expect(await recordCount(in: appLog, event: "gateway.attempt") == 1)

            // A failed read on a live connection is not a lost connection: the
            // retry must not replace the socket, publish `.reconnecting`, write a
            // scene record for a scene that did not move, or count an attempt.
            let sleepersBefore = clock.activeSleeperCount()
            fixture.model.recoverTransientTransportFailure()
            for _ in 0..<20 { await Task.yield() }
            #expect(fixture.model.connectionState == .connected)
            #expect(fixture.socketFactory.requests.count == 1)
            #expect(clock.activeSleeperCount() == sleepersBefore)
            #expect(await appLog.snapshot().filter { $0.event.hasPrefix("scene.") }.isEmpty)
            #expect(await recordCount(in: appLog, event: "gateway.attempt") == 1)
        }
    }

    @Test("a workspace retry revives a parked retry without waiting out its backoff")
    func transientTransportRetryRevivesParkedRetry() async throws {
        let clock = ManualClock()
        let sockets = [ScriptedGatewaySocket(), ScriptedGatewaySocket()]
        let logURL = FileManager.default.temporaryDirectory
            .appending(path: "transient-parked-\(UUID().uuidString).jsonl")
        defer {
            try? FileManager.default.removeItem(at: logURL)
            try? FileManager.default.removeItem(at: logURL.appendingPathExtension("1"))
        }
        let appLog = AppLog(fileURL: logURL)
        try await withFixture(
            sockets: sockets, clock: clock, units: SequenceReconnectUnits([0]), appLog: appLog
        ) { fixture in
            let start = Task { await fixture.model.start() }
            defer { start.cancel() }
            try await failHandshake(sockets[0])
            try await clock.waitUntilSleeping(count: 1)
            await start.value
            #expect(fixture.model.connectionState == .reconnecting)
            #expect(fixture.socketFactory.requests.count == 1)

            // A parked route is exactly what the browser's transient-error
            // retry exists for: the read failed, the scene did not move, and the
            // lifecycle owns a route waiting out its backoff. The retry must
            // connect now, without advancing the clock and without recording a
            // scene transition.
            fixture.model.recoverTransientTransportFailure()
            try await sockets[1].waitUntilSent(count: 1)
            #expect(fixture.socketFactory.requests.count == 2)
            #expect(clock.activeSleeperCount() == 0)
            #expect(clock.recordedSleeps() == [.seconds(1.6)])
            #expect(await appLog.snapshot().filter { $0.event.hasPrefix("scene.") }.isEmpty)
        }
    }

    @Test("ordinary short successful foreground visits do not become an artificial outage")
    func healthyForegroundVisitsDoNotExhaustRecovery() async throws {
        let suiteName = "GatewayHealthyForegroundTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let profile = GatewayProfile(id: "gateway", label: "Mac", host: "gateway.test", port: 9_847,
                                     machineId: "machine", deviceId: "device")
        defaults.set(try JSONEncoder.gateway.encode([profile]), forKey: "gatewayProfiles.v1")
        defaults.set(profile.id, forKey: "selectedGateway.v1")
        let sockets = (0..<5).map { _ in ScriptedGatewaySocket() }
        let factory = ScriptedGatewaySocketFactory(sockets: sockets)
        let client = GatewayClient(socketFactory: factory.factory)
        let coordinator = GatewayLifecycleCoordinator(
            client: client, profiles: GatewayProfileStore(defaults: defaults), clock: .continuous,
            reconnectDelayPolicy: .standard, uuidSource: .random, pairer: GatewayPairer(),
            pairingCommit: { _, _ in }, profileTokenLookup: { _ in "token" }
        )
        do {
            try await withTestWatchdog { @MainActor in
                for index in sockets.indices {
                    await sockets[index].enqueue(helloFrame())
                    if index == 0 { await coordinator.start() }
                    else { await coordinator.becameActive()?.value }
                    try await sockets[index].waitUntilSent(count: 1)
                    while coordinator.connectionState != .connected {
                        try Task.checkCancellation()
                        await Task.yield()
                    }
                    coordinator.enteredBackground()
                    try await sockets[index].waitUntilClosed()
                }
                #expect(factory.requests.count == sockets.count)
            }
        } catch {
            await coordinator.teardown()
            await client.close()
            throw error
        }
        await coordinator.teardown()
        await client.close()
    }

    @Test("mounted restore failure leaves the responsive replacement transport usable")
    func mountedRestoreFailureKeepsTransport() async throws {
        try await withTestWatchdog { @MainActor in
            let suiteName = "GatewayMountedRestoreTests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suiteName)!
            defaults.removePersistentDomain(forName: suiteName)
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let profile = GatewayProfile(
                id: "gateway", label: "Mac", host: "gateway.test", port: 9_847,
                machineId: "machine", deviceId: "device"
            )
            defaults.set(try JSONEncoder.gateway.encode([profile]), forKey: "gatewayProfiles.v1")
            defaults.set(profile.id, forKey: "selectedGateway.v1")
            let sockets = [
                ScriptedGatewaySocket(),
                ScriptedGatewaySocket(),
                ScriptedGatewaySocket(),
            ]
            let factory = ScriptedGatewaySocketFactory(sockets: sockets)
            let client = GatewayClient(socketFactory: factory.factory)
            let coordinator = GatewayLifecycleCoordinator(
                client: client,
                profiles: GatewayProfileStore(defaults: defaults),
                clock: .continuous,
                reconnectDelayPolicy: .standard,
                uuidSource: .random,
                pairer: GatewayPairer(),
                pairingCommit: { _, _ in },
                profileTokenLookup: { _ in "token" }
            )
            let projection = FailFirstMountedRestoreProjection()
            coordinator.delegate = projection

            let initial = Task { try await coordinator.connectHosted(profile: profile, token: "token") }
            try await sockets[0].waitUntilSent(count: 1)
            await sockets[0].enqueue(helloFrame())
            try await initial.value

            coordinator.requestReconnect(immediate: true)
            try await sockets[1].waitUntilSent(count: 1)
            await sockets[1].enqueue(helloFrame())
            await projection.waitForAggregateCompletion(count: 1)
            #expect(projection.restoreCount == 1)
            #expect(projection.aggregateCompletions == [false])
            #expect(coordinator.connectionState == .connected)
            #expect(factory.requests.count == 2)
            #expect(!(await sockets[1].closed()))

            await coordinator.teardown()
            await client.close()
        }
    }

    @Test("false mounted restore cannot publish connected after its socket dies during refresh")
    func falseRestoreRejectsDeadEpochAfterRefresh() async throws {
        try await withTestWatchdog { @MainActor in
            let suiteName = "GatewayMountedRestoreDisconnectTests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suiteName)!
            defaults.removePersistentDomain(forName: suiteName)
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let profile = GatewayProfile(
                id: "gateway", label: "Mac", host: "gateway.test", port: 9_847,
                machineId: "machine", deviceId: "device"
            )
            defaults.set(try JSONEncoder.gateway.encode([profile]), forKey: "gatewayProfiles.v1")
            defaults.set(profile.id, forKey: "selectedGateway.v1")
            let sockets = [ScriptedGatewaySocket(), ScriptedGatewaySocket()]
            let factory = ScriptedGatewaySocketFactory(sockets: sockets)
            let client = GatewayClient(socketFactory: factory.factory)
            let coordinator = GatewayLifecycleCoordinator(
                client: client,
                profiles: GatewayProfileStore(defaults: defaults),
                clock: .continuous,
                reconnectDelayPolicy: .standard,
                uuidSource: .random,
                pairer: GatewayPairer(),
                pairingCommit: { _, _ in },
                profileTokenLookup: { _ in "token" }
            )
            let projection = FailFirstMountedRestoreProjection(blockRefresh: true)
            coordinator.delegate = projection

            let initial = Task { try await coordinator.connectHosted(profile: profile, token: "token") }
            try await sockets[0].waitUntilSent(count: 1)
            await sockets[0].enqueue(helloFrame())
            try await initial.value

            coordinator.requestReconnect(immediate: true)
            try await sockets[1].waitUntilSent(count: 1)
            await sockets[1].enqueue(helloFrame())
            for _ in 0..<50 where !projection.refreshStarted { await Task.yield() }
            #expect(projection.refreshStarted)
            await sockets[1].failPendingReceivers(CancellationError())
            try await sockets[1].waitUntilClosed()
            #expect(await client.activeConnectionID() == nil)
            // Deliberately leave transport.disconnected queued: the coordinator
            // still has its stale ID until the event reducer catches up.
            projection.releaseRefresh()
            for _ in 0..<50 where coordinator.connectionState == .connected { await Task.yield() }
            #expect(coordinator.connectionState != .connected)
            await coordinator.teardown()
            await client.close()
        }
    }

    @Test("foreground reconciliation releases its task slot after failure and reconnect")
    func foregroundFailureReleasesOwnership() async throws {
        try await withTestWatchdog {
            try await performForegroundFailureRecovery()
        }
    }

    private func performForegroundFailureRecovery() async throws {
        let suiteName = "GatewayLifecycleForegroundTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let profile = GatewayProfile(
            id: "gateway",
            label: "Mac",
            host: "gateway.test",
            port: 9_847,
            machineId: "machine",
            deviceId: "device"
        )
        defaults.set(try JSONEncoder.gateway.encode([profile]), forKey: "gatewayProfiles.v1")
        defaults.set(profile.id, forKey: "selectedGateway.v1")
        let store = GatewayProfileStore(defaults: defaults)
        let sockets = [ScriptedGatewaySocket(), ScriptedGatewaySocket()]
        let factory = ScriptedGatewaySocketFactory(sockets: sockets)
        let client = GatewayClient(socketFactory: factory.factory)
        let coordinator = GatewayLifecycleCoordinator(
            client: client,
            profiles: store,
            clock: .continuous,
            reconnectDelayPolicy: .standard,
            uuidSource: .random,
            pairer: GatewayPairer(),
            pairingCommit: { _, _ in },
            profileTokenLookup: { _ in "token" }
        )
        let projection = FailFirstForegroundProjection()
        coordinator.delegate = projection

        let initial = Task { try await coordinator.connectHosted(profile: profile, token: "token") }
        try await sockets[0].waitUntilSent(count: 1)
        await sockets[0].enqueue(helloFrame())
        try await initial.value

        coordinator.becameActive()
        await projection.waitForReconciliation(count: 1)
        try await sockets[1].waitUntilSent(count: 1)
        await sockets[1].enqueue(helloFrame())
        for _ in 0..<20 where coordinator.connectionState != .connected {
            await Task.yield()
        }
        #expect(coordinator.connectionState == .connected)

        coordinator.becameActive()
        await projection.waitForReconciliation(count: 2)
        #expect(projection.reconciliationCount == 2)

        await coordinator.teardown()
        await client.close()
        defaults.removePersistentDomain(forName: suiteName)
    }

    @Test("terminal mutation response survives immediate lifecycle retirement")
    func terminalMutationResponseOwnsCompletion() async throws {
        try await withTestWatchdog { @MainActor in
            let socket = ScriptedGatewaySocket()
            let client = GatewayClient(
                socketFactory: ScriptedGatewaySocketFactory(sockets: [socket]).factory
            )
            let lifecycle = GatewayLifecycleCoordinator(
                client: client,
                profiles: GatewayProfileStore(),
                clock: .continuous,
                reconnectDelayPolicy: .standard,
                uuidSource: .random,
                pairer: GatewayPairer(),
                pairingCommit: { _, _ in },
                profileTokenLookup: { _ in "token" }
            )
            let profile = GatewayProfile(
                id: "profile", label: "Mac", host: "gateway.test", port: 9_847,
                machineId: "machine", deviceId: "device"
            )
            await socket.enqueue(helloFrame())
            try await lifecycle.connectHosted(profile: profile, token: "token")
            let executor = ConfirmedMutationExecutor(
                client: client,
                lifecycle: lifecycle,
                clock: .continuous,
                performanceSignposts: RecordingPerformanceSignposts()
            )

            let result = try await executor.performValue(
                method: "test.confirmed",
                commandID: "confirmed-command"
            ) {
                lifecycle.enteredBackground()
                return .string("confirmed")
            }

            #expect(result == .string("confirmed"))
            await lifecycle.teardown()
            await client.close()
        }
    }

    @Test("foreground cannot open a conversation before replacement transport admission")
    func foregroundOpenRejectsRetiredTransport() async throws {
        let socket = ScriptedGatewaySocket()
        let client = GatewayClient(
            socketFactory: ScriptedGatewaySocketFactory(sockets: [socket]).factory
        )
        let model = AppModel(client: client)
        let profile = GatewayProfile(
            id: "profile", label: "Mac", host: "gateway.test", port: 9_847,
            machineId: "machine", deviceId: "device"
        )
        await socket.enqueue(helloFrame())
        try await model.connectHostedGateway(profile: profile, token: "token")
        #expect(model.admitsSessionPresentationOpen)
        model.beginHostedReconciliationAggregate()
        #expect(model.isReconcilingForeground)
        #expect(model.admitsSessionPresentationOpen)
        model.completeHostedReconciliationAggregate(succeeded: true)
        #expect(!model.isReconcilingForeground)

        model.enteredBackground()
        _ = model.becameActive()
        #expect(!model.admitsSessionPresentationOpen)
        do {
            _ = try await model.openSessionPresentation("session-a")
            Issue.record("retired transport unexpectedly admitted session.open")
        } catch is CancellationError {
            // Expected: foreground UI waits for the replacement connection.
        }
        let methods = await socket.sentFrames().compactMap { frame in
            (try? JSONDecoder.gateway.decode(JSONValue.self, from: frame))?
                .objectValue?["method"]?.stringValue
        }
        #expect(!methods.contains("session.open"))

        await model.teardown()
        await client.close()
    }

    @Test("recovery warning timer uses its injected clock and never grants Send authority")
    func recoveryWarningTimerAndAuthorityFence() async throws {
        let suite = "GatewayRecoveryWarningTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let profile = GatewayProfile(
            id: "gateway", label: "Mac", host: "gateway.test", port: 9_847,
            machineId: "machine", deviceId: "device"
        )
        defaults.set(try JSONEncoder.gateway.encode([profile]), forKey: "gatewayProfiles.v1")
        defaults.set(profile.id, forKey: "selectedGateway.v1")
        let displayClock = ManualClock()
        let socket = ScriptedGatewaySocket()
        let replacement = ScriptedGatewaySocket()
        let client = GatewayClient(socketFactory: ScriptedGatewaySocketFactory(sockets: [socket, replacement]).factory)
        let model = AppModel(
            client: client,
            profiles: GatewayProfileStore(defaults: defaults),
            recoveryDisplayClock: displayClock.clock,
            profileTokenLookup: { _ in "token" }
        )
        let connected = Task { try await model.connectHostedGateway(profile: profile, token: "token") }
        try await socket.waitUntilSent(count: 1)
        await socket.enqueue(helloFrame())
        try await connected.value
        let snapshot = try SessionScenarioBuilder(seed: 47_022).openingTail(targetEncodedBytes: 4_096)
        model.installHostedSubscribedSnapshot(snapshot)
        await socket.failPendingReceivers(URLError(.networkConnectionLost))
        try await socket.waitUntilClosed()
        try await displayClock.waitUntilSleeping(count: 1, duration: .seconds(2))
        #expect(model.visibleNotices.isEmpty)
        displayClock.advance(by: .seconds(2))
        for _ in 0..<10 { await Task.yield() }
        let warning = try #require(model.visibleNotices.first { $0.replacement?.key == .gatewayRecovery })
        #expect(warning.title == "Gateway connection unavailable")
        #expect(warning.lifetime == .automatic(.seconds(8)))
        #expect(warning.message?.contains("Settings") == true)
        let target = try #require(model.mountedPresentationTarget)
        #expect(!model.admitsLiveSessionCommands(target))
        await replacement.enqueue(helloFrame())
        try await withTestWatchdog { @MainActor in
            var index = 1
            while true {
                try await replacement.waitUntilSent(count: index + 1)
                let request = try requestFrame(await replacement.sentFrames()[index])
                if request.method == "session.open" { break }
                index += 1
            }
        }
        #expect(model.isReconcilingForeground)
        #expect(!model.admitsLiveSessionCommands(target))
        #expect(!model.visibleNotices.contains { $0.replacement?.key == .gatewayRecovery })
        await model.teardown()
        await client.close()
    }

    @Test("planned maintenance restart watchdog uses the controlled clock without charging roaming recovery")
    func maintenanceRestartWatchdogUsesControlledClock() async throws {
        try await withTestWatchdog { @MainActor in
            let clock = ManualClock()
            let suite = "GatewayMaintenanceWatchdogTests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let profile = GatewayProfile(id: "gateway", label: "Mac", host: "gateway.test", port: 9847, machineId: "machine", deviceId: "device")
            defaults.set(try JSONEncoder.gateway.encode([profile]), forKey: "gatewayProfiles.v1")
            defaults.set(profile.id, forKey: "selectedGateway.v1")
            let sockets = (0..<3).map { _ in ScriptedGatewaySocket() }
            let factory = ScriptedGatewaySocketFactory(sockets: sockets)
            let client = GatewayClient(socketFactory: factory.factory)
            let projection = NoopGatewayLifecycleProjection()
            let coordinator = GatewayLifecycleCoordinator(client: client, profiles: GatewayProfileStore(defaults: defaults),
                clock: clock.clock, reconnectDelayPolicy: .standard, uuidSource: .random, pairer: GatewayPairer(),
                pairingCommit: { _, _ in }, profileTokenLookup: { _ in "fixture" })
            coordinator.delegate = projection
            do {
                await sockets[0].enqueue(helloFrame())
                await coordinator.start()
                coordinator.beginRestarting()
                #expect(coordinator.connectionState == .restarting)
                await coordinator.noteDisconnected(connectionID: await client.activeConnectionID(), countsAsTransportFailure: false)
                coordinator.requestReconnect(immediate: true)
                try await sockets[1].waitUntilSent(count: 1)
                try await failHandshake(sockets[1])
                try await sockets[1].waitUntilClosed()
                try await clock.waitUntilSleeping(count: 1, duration: .seconds(90))
                clock.advance(by: .seconds(90))
                try await sockets[2].waitUntilSent(count: 1)
                #expect(coordinator.connectionState == .reconnecting)
                #expect(factory.requests.count == 3)
            } catch {
                await coordinator.teardown(); await client.close(); throw error
            }
            await coordinator.teardown(); await client.close()
        }
    }

    @Test("paired Debug profile publishes an authenticated replacement before projection refresh without prompt replay")
    func debugPlannedRestartReconnectsWithoutReplay() async throws {
        let suiteName = "GatewayDebugReconnectTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let cacheRoot = FileManager.default.temporaryDirectory.appending(path: suiteName, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let profile = GatewayProfile(
            id: "debug", label: "Mac Debug", host: "gateway.test", port: 9_848,
            machineId: "machine-debug", deviceId: "device-debug"
        )
        defaults.set(try JSONEncoder.gateway.encode([profile]), forKey: "gatewayProfiles.v1")
        defaults.set(profile.id, forKey: "selectedGateway.v1")
        let first = ScriptedGatewaySocket()
        let replacement = ScriptedGatewaySocket()
        let factory = ScriptedGatewaySocketFactory(sockets: [first, replacement])
        let client = GatewayClient(socketFactory: factory.factory)
        let store = GatewayProfileStore(defaults: defaults)
        let model = AppModel(
            client: client,
            profiles: store,
            cache: SnapshotCache(root: cacheRoot),
            profileTokenLookup: { value in value.id == "debug" ? "debug-token" : nil }
        )

        let initial = Task { try await model.connectHostedGateway(profile: profile, token: "debug-token") }
        try await first.waitUntilSent(count: 1)
        await first.enqueue(helloFrame(runtimeEpoch: "debug-epoch-1", machineID: "machine-debug", gatewayChannel: "dev"))
        try await initial.value

        let acceptedPrompt = Task {
            try await client.requestValue(
                "session.prompt",
                JSONValue.object(["sessionId": .string("accepted-session"), "text": .string("accepted prompt")]),
                timeout: .seconds(2)
            )
        }
        try await first.waitUntilSent(count: 2)
        let promptRequest = try requestFrame(await first.sentFrames()[1])
        #expect(promptRequest.method == "session.prompt")
        await first.enqueue(successResponse(id: promptRequest.id, result: .object(["accepted": .bool(true)])))
        _ = try await acceptedPrompt.value

        await model.handle(GatewayEvent(type: "event", topic: "system.stopping", sessionId: nil, payload: .object([:])))
        try await replacement.waitUntilSent(count: 1)
        #expect(model.connectionState == .restarting)
        await Task.yield()
        #expect(model.connectionState == .restarting)
        await replacement.enqueue(helloFrame(runtimeEpoch: "debug-epoch-2", machineID: "machine-debug", gatewayChannel: "dev"))

        let requiredRefreshes: Set<String> = ["session.list", "provider.list", "model.list", "settings.get", "device.list"]
        var refreshedMethods = Set<String>()
        var frameIndex = 1
        while !requiredRefreshes.isSubset(of: refreshedMethods) {
            try await replacement.waitUntilSent(count: frameIndex + 1)
            let request = try requestFrame(await replacement.sentFrames()[frameIndex])
            frameIndex += 1
            refreshedMethods.insert(request.method)
            let result: JSONValue
            switch request.method {
            case "session.list":
                result = .object(["sessions": .array([]), "nextCursor": .null, "listRevision": .number(2),
                                  "projectionToken": .string("epoch-1:2:0:user:exclude:0")])
            case "provider.list": result = .object(["providers": .array([])])
            case "model.list": result = .object(["models": .array([]), "nextCursor": .null])
            case "settings.get": result = .object(["effective": .object([:])])
            case "device.list": result = .object(["devices": .array([])])
            case "notification.inbox.list": continue // Independent optional owner; leave it pending.
            default:
                Issue.record("unexpected reconnect baseline request: \(request.method)")
                result = .object([:])
            }
            await replacement.enqueue(successResponse(id: request.id, result: result))
        }
        for _ in 0..<100
            where model.gatewayInfo?.runtimeEpoch != "debug-epoch-2"
                || model.connectionState != GatewayConnectionState.connected {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(model.gatewayInfo?.runtimeEpoch == "debug-epoch-2")
        #expect(model.connectionState == GatewayConnectionState.connected)
        #expect(refreshedMethods.contains("session.list"))
        #expect(store.selected?.host == "gateway.test")
        #expect(store.selected?.port == 9_848)
        #expect(factory.requests.count == 2)
        #expect(factory.requests.allSatisfy { $0.url?.port == 9_848 })
        #expect(factory.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer debug-token" })
        let replacementText = await replacement.sentFrames().compactMap { String(data: $0, encoding: .utf8) }.joined(separator: "\n")
        #expect(!replacementText.contains("session.prompt"))

        await model.teardown()
        await client.close()
    }

    @Test("active handshake ignores duplicate activation and stale unauthorized teardown completion")
    func activeHandshakeKeepsExactOwner() async throws {
        let units = SequenceReconnectUnits([0.5])
        let clock = ManualClock()
        let initial = ScriptedGatewaySocket()
        let active = ScriptedGatewaySocket(deliversCallbacksAfterClose: true)
        try await withFixture(
            sockets: [initial, active],
            clock: clock,
            units: units
        ) { fixture in
            let start = Task { await fixture.model.start() }
            defer { start.cancel() }
            try await failHandshake(initial)
            try await clock.waitUntilSleeping(count: 1)
            await start.value

            clock.advance(by: .seconds(2))
            try await active.waitUntilSent(count: 1)
            fixture.model.becameActive()
            fixture.model.becameActive()
            await Task.yield()
            #expect(fixture.socketFactory.requests.count == 2)
            #expect(await active.closeInvocationCount() == 0)

            let teardown = Task { await fixture.model.teardown() }
            defer { teardown.cancel() }
            try await active.waitUntilCloseInvoked()
            await active.failPendingReceivers(GatewayFailure(
                code: "unauthenticated",
                message: "retired credentials",
                retryable: false,
                details: nil
            ))
            await teardown.value

            #expect(fixture.model.connectionState == .unpaired)
            #expect(fixture.model.visibleNotices.isEmpty)
            #expect(fixture.socketFactory.requests.count == 2)
            #expect(await active.closeTransitionCount() == 1)
        }
    }

    /// A mounted restoration the real foreground pass left blocked on an
    /// unanswered `session.open`, so a test can drive the clock and the route
    /// while that restoration is still in flight.
    private struct HeldMountedRestoration {
        let target: SessionPresentationIdentity
        let snapshot: SessionSnapshot
        let openID: String
        let index: Int
    }

    /// Drives the real replacement reconnect (`enteredBackground` →
    /// `becameActive` → authenticated handshake) up to a mounted restoration
    /// whose `session.open` the Gateway never answers. `index` is the frame
    /// cursor just past that request.
    private func holdMountedRestoration(
        _ fixture: ReconnectFixture
    ) async throws -> HeldMountedRestoration {
        let model = fixture.model
        let first = fixture.sockets[0]
        let replacement = fixture.sockets[1]
        let profile = try #require(model.profiles.selected)
        await first.enqueue(helloFrame())
        try await model.connectHostedGateway(profile: profile, token: "token")
        let snapshot = try SessionScenarioBuilder(seed: 61_204).openingTail(targetEncodedBytes: 4_096)
        model.installHostedSubscribedSnapshot(snapshot)
        model.sessions = [startupSummary(snapshot.sessionId)]
        let target = try #require(model.mountedPresentationTarget)

        await model.enteredBackground().value
        await model.becameActive()?.value
        try await replacement.waitUntilSent(count: 1)
        await replacement.enqueue(helloFrame())
        var index = 1
        var openID: String?
        while openID == nil {
            try await replacement.waitUntilSent(count: index + 1)
            let request = try requestFrame(await replacement.sentFrames()[index])
            index += 1
            switch request.method {
            case "session.open": openID = request.id
            case "session.list", "notification.inbox.list": break // Optional owners stay pending.
            default:
                Issue.record("Unexpected request before mounted restoration: \(request.method)")
                throw CancellationError()
            }
        }
        #expect(model.connectionState == .connected)
        #expect(model.isReconcilingForeground)
        return HeldMountedRestoration(
            target: target, snapshot: snapshot, openID: try #require(openID), index: index
        )
    }

    private func startupSummary(_ id: String) -> SessionSummary {
        SessionSummary(
            id: id, name: id, cwd: "/workspace", parentSessionId: nil,
            createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:01Z",
            messageCount: 0, firstMessage: id, phase: .idle, summaryRevision: 1
        )
    }

    /// A row that is working and waiting for the user. Its phase is not idle,
    /// so a retired projection reports it as "resuming" rather than "idle".
    private func waitingSummary(_ id: String) -> SessionSummary {
        SessionSummary(
            id: id, name: id, cwd: "/workspace", parentSessionId: nil,
            createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:01Z",
            messageCount: 0, firstMessage: id, phase: .running, waitingForUser: true,
            summaryRevision: 1
        )
    }

    private func helloFrame(
        runtimeEpoch: String? = nil,
        machineID: String = "machine",
        gatewayChannel: String = "stable"
    ) -> Data {
        var value: [String: JSONValue] = [
            "type": .string("hello"),
            "gatewayVersion": .string("1.0.0"),
            "piVersion": .string("1.0.0"),
            "protocolVersion": .number(6),
            "minProtocolVersion": .number(6),
            "machineId": .string(machineID),
            "machineName": .string("Mac"),
            "capabilities": .array([.string("sessions.v1")]),
            "gatewayChannel": .string(gatewayChannel),
        ]
        if let runtimeEpoch { value["runtimeEpoch"] = .string(runtimeEpoch) }
        return try! JSONEncoder.gateway.encode(JSONValue.object(value))
    }

    private func requestFrame(_ data: Data) throws -> (id: String, method: String) {
        let value = try JSONDecoder.gateway.decode(JSONValue.self, from: data)
        return (
            try #require(value.objectValue?["id"]?.stringValue),
            try #require(value.objectValue?["method"]?.stringValue)
        )
    }

    private func successResponse(id: String, result: JSONValue) -> Data {
        try! JSONEncoder.gateway.encode(JSONValue.object([
            "type": .string("response"),
            "id": .string(id),
            "ok": .bool(true),
            "result": result,
        ]))
    }

    private func failHandshake(_ socket: ScriptedGatewaySocket) async throws {
        try await socket.waitUntilSent(count: 1)
        await socket.failPendingReceivers(GatewayFailure(
            code: "disconnected",
            message: "synthetic disconnect",
            retryable: true,
            details: nil
        ))
    }

    @Test("every reconnect attempt and one episode reach the always-on app log")
    func reconnectAttemptsAndEpisodeAreRecorded() async throws {
        let clock = ManualClock()
        let sockets = (0..<4).map { _ in ScriptedGatewaySocket() }
        let logURL = FileManager.default.temporaryDirectory
            .appending(path: "reconnect-records-\(UUID().uuidString).jsonl")
        defer {
            try? FileManager.default.removeItem(at: logURL)
            try? FileManager.default.removeItem(at: logURL.appendingPathExtension("1"))
        }
        let appLog = AppLog(fileURL: logURL)
        try await withFixture(
            sockets: sockets, clock: clock,
            units: SequenceReconnectUnits(Array(repeating: 0.5, count: 8)), appLog: appLog
        ) { fixture in
            let start = Task { await fixture.model.start() }
            defer { start.cancel() }
            try await failHandshake(sockets[0])
            try await clock.waitUntilSleeping(count: 1)
            await start.value

            for index in 1...2 {
                clock.advance(by: .seconds(60))
                try await sockets[index].waitUntilSent(count: 1)
                try await failHandshake(sockets[index])
                try await sockets[index].waitUntilClosed()
                try await clock.waitUntilSleeping(count: 1)
            }
            await sockets[3].enqueue(helloFrame())
            clock.advance(by: .seconds(60))
            try await sockets[3].waitUntilSent(count: 1)
            while fixture.model.connectionState != .connected {
                try Task.checkCancellation()
                await Task.yield()
            }

            let attempts = try await waitForRecords(in: appLog, event: "gateway.attempt", count: 4)
            // The initial connect plus the loop's three retries: the first three
            // fail and the fourth connects.
            #expect(attempts.map(\.outcome) == ["failure", "failure", "failure", "success"])
            #expect(attempts[0].message.contains("attemptId=initial"))
            #expect(attempts[1].message.contains("retry=1"))
            #expect(attempts[2].message.contains("retry=2"))
            #expect(attempts[3].message.contains("retry=3"))
            #expect(attempts[3].message.contains("stageReached=connected"))
            let episodes = try await waitForRecords(in: appLog, event: "connection.episode", count: 1)
            #expect(episodes.count == 1)
            #expect(episodes[0].message.contains("endedBy=connected"))
            #expect(episodes[0].message.contains("attempts=4"))
            // Every attempt started on the 60 s the test's clock advanced between
            // them, so the largest gap is that advance.
            #expect(episodes[0].message.contains("maxGapBetweenAttemptsMs=60000"))
        }
    }

    @Test("an attempt in flight or waiting in its backoff is never reported as a stall")
    func backoffIsNotAStall() async throws {
        let clock = ManualClock()
        let watchdog = ManualClock()
        let logURL = FileManager.default.temporaryDirectory
            .appending(path: "reconnect-stall-\(UUID().uuidString).jsonl")
        defer {
            try? FileManager.default.removeItem(at: logURL)
            try? FileManager.default.removeItem(at: logURL.appendingPathExtension("1"))
        }
        let appLog = AppLog(fileURL: logURL)
        try await withRecordedCoordinator(
            sockets: (0..<2).map { _ in ScriptedGatewaySocket() },
            clock: clock, watchdogClock: watchdog.clock, appLog: appLog
        ) { coordinator, client, sockets in
            await sockets[0].enqueue(helloFrame())
            await coordinator.start()
            #expect(coordinator.connectionState == .connected)
            // The socket retires under the app: an episode opens and the loop
            // parks in its bounded backoff, then attempts, which are both
            // progress, not a stall.
            await coordinator.noteDisconnected(connectionID: await client.activeConnectionID())
            coordinator.requestReconnect()
            // The stall bound is measured on the lifecycle clock and polled on
            // the watchdog clock, so both advance: 30 s of bound time pass with
            // the episode open and nothing may be reported. Each tick is awaited
            // before the next advance, so every check sees the whole advance.
            for _ in 0..<6 {
                clock.advance(by: .seconds(5))
                try await watchdog.waitUntilSleeping(
                    count: 1, duration: GatewayConnectionEpisodeRecorder.watchdogInterval
                )
                watchdog.advance(by: GatewayConnectionEpisodeRecorder.watchdogInterval)
            }
            try await watchdog.waitUntilSleeping(
                count: 1, duration: GatewayConnectionEpisodeRecorder.watchdogInterval
            )
            #expect(await recordCount(in: appLog, event: "reconnect.stalled") == 0)
            coordinator.enteredBackground()
            let episodes = try await waitForRecords(in: appLog, event: "connection.episode", count: 1)
            #expect(episodes.count == 1)
            #expect(episodes[0].message.contains("endedBy=background"))
        }
    }

    @Test("a parked episode is not a stall and its bound resumes it without a callback")
    func parkedEpisodeResumesAtItsBound() async throws {
        let clock = ManualClock()
        let watchdog = ManualClock()
        let logURL = FileManager.default.temporaryDirectory
            .appending(path: "reconnect-parked-bound-\(UUID().uuidString).jsonl")
        defer {
            try? FileManager.default.removeItem(at: logURL)
            try? FileManager.default.removeItem(at: logURL.appendingPathExtension("1"))
        }
        let appLog = AppLog(fileURL: logURL)
        let projection = NoopGatewayLifecycleProjection()
        try await withRecordedCoordinator(
            sockets: (0..<2).map { _ in ScriptedGatewaySocket() },
            clock: clock, watchdogClock: watchdog.clock, appLog: appLog, projection: projection
        ) { coordinator, client, sockets in
            await sockets[0].enqueue(helloFrame())
            await coordinator.start()
            #expect(coordinator.connectionState == .connected)
            await coordinator.noteDisconnected(connectionID: await client.activeConnectionID())
            coordinator.requestReconnect()
            // The route goes away before its first attempt: recovery is parked
            // with nothing in flight or scheduled, and the parked bound is what
            // will resume it without a callback.
            coordinator.notePathHint(satisfied: false)
            try await clock.waitUntilSleeping(
                count: 1, duration: GatewayLifecycleCoordinator.parkedRetryBound
            )
            #expect(
                projection.diagnostics.contains {
                    $0.hasPrefix("reconnect.parked ") && $0.contains("reason=pathUnsatisfied")
                }
            )
            // 20 s of bound time pass with the episode open: a parked episode has
            // its resume scheduled, so it is never reported as a stall.
            for _ in 0..<4 {
                clock.advance(by: .seconds(5))
                try await watchdog.waitUntilSleeping(
                    count: 1, duration: GatewayConnectionEpisodeRecorder.watchdogInterval
                )
                watchdog.advance(by: GatewayConnectionEpisodeRecorder.watchdogInterval)
            }
            try await watchdog.waitUntilSleeping(
                count: 1, duration: GatewayConnectionEpisodeRecorder.watchdogInterval
            )
            #expect(await recordCount(in: appLog, event: "reconnect.stalled") == 0)

            // The path callback never arrives; the bound still resumes recovery.
            await sockets[1].enqueue(helloFrame())
            clock.advance(by: GatewayLifecycleCoordinator.parkedRetryBound)
            try await sockets[1].waitUntilSent(count: 1)
            #expect(
                projection.diagnostics.contains {
                    $0.hasPrefix("reconnect.parked-resume ") && $0.contains("reason=pathUnsatisfied")
                }
            )
            while coordinator.connectionState != .connected {
                try Task.checkCancellation()
                await Task.yield()
            }
        }
    }

    @Test("a parked episode whose probe attempt fails parks again with a fresh bound")
    func parkedProbeFailureReparksTheEpisode() async throws {
        let clock = ManualClock()
        let watchdog = ManualClock()
        let logURL = FileManager.default.temporaryDirectory
            .appending(path: "reconnect-parked-repark-\(UUID().uuidString).jsonl")
        defer {
            try? FileManager.default.removeItem(at: logURL)
            try? FileManager.default.removeItem(at: logURL.appendingPathExtension("1"))
        }
        let appLog = AppLog(fileURL: logURL)
        let projection = NoopGatewayLifecycleProjection()
        try await withRecordedCoordinator(
            sockets: (0..<3).map { _ in ScriptedGatewaySocket() },
            clock: clock, watchdogClock: watchdog.clock, appLog: appLog, projection: projection
        ) { coordinator, client, sockets in
            await sockets[0].enqueue(helloFrame())
            await coordinator.start()
            #expect(coordinator.connectionState == .connected)
            await coordinator.noteDisconnected(connectionID: await client.activeConnectionID())
            coordinator.requestReconnect()
            // The route is down and its callback never comes: only the bound
            // brings the next attempt.
            coordinator.notePathHint(satisfied: false)
            try await waitForDiagnostics(projection, prefix: "reconnect.parked ", count: 1)
            try await clock.waitUntilSleeping(
                count: 1, duration: GatewayLifecycleCoordinator.parkedRetryBound
            )

            // The bound spends one probe attempt on the stale hint and that
            // attempt fails on the same still-down route. The episode must park
            // again: ending the loop silently here is the missed-callback gap.
            clock.advance(by: GatewayLifecycleCoordinator.parkedRetryBound)
            try await sockets[1].waitUntilSent(count: 1)
            try await failHandshake(sockets[1])
            try await waitForDiagnostics(projection, prefix: "reconnect.parked ", count: 2)
            #expect(
                projection.diagnostics.filter { $0.hasPrefix("reconnect.parked ") }.last?.contains(
                    "reason=pathUnsatisfied"
                ) == true
            )
            // A fresh bound is armed, so the stall watchdog reads a parked
            // episode as progressing and 20 s of bound time report no stall.
            #expect(coordinator.reconnectStallGuard == nil)
            try await clock.waitUntilSleeping(
                count: 1, duration: GatewayLifecycleCoordinator.parkedRetryBound
            )
            for _ in 0..<4 {
                clock.advance(by: .seconds(5))
                try await watchdog.waitUntilSleeping(
                    count: 1, duration: GatewayConnectionEpisodeRecorder.watchdogInterval
                )
                watchdog.advance(by: GatewayConnectionEpisodeRecorder.watchdogInterval)
            }
            try await watchdog.waitUntilSleeping(
                count: 1, duration: GatewayConnectionEpisodeRecorder.watchdogInterval
            )
            #expect(await recordCount(in: appLog, event: "reconnect.stalled") == 0)

            // The fresh bound resumes recovery with the second probe attempt.
            await sockets[2].enqueue(helloFrame())
            clock.advance(by: GatewayLifecycleCoordinator.parkedRetryBound)
            try await sockets[2].waitUntilSent(count: 1)
            while coordinator.connectionState != .connected {
                try Task.checkCancellation()
                await Task.yield()
            }
            #expect(await recordCount(in: appLog, event: "reconnect.stalled") == 0)
        }
    }

    @Test("a foreground probe that fails parks the episode again")
    func foregroundProbeFailureReparksTheEpisode() async throws {
        let clock = ManualClock()
        let logURL = FileManager.default.temporaryDirectory
            .appending(path: "reconnect-parked-foreground-repark-\(UUID().uuidString).jsonl")
        defer {
            try? FileManager.default.removeItem(at: logURL)
            try? FileManager.default.removeItem(at: logURL.appendingPathExtension("1"))
        }
        let appLog = AppLog(fileURL: logURL)
        let projection = NoopGatewayLifecycleProjection()
        try await withRecordedCoordinator(
            sockets: (0..<3).map { _ in ScriptedGatewaySocket() },
            clock: clock, watchdogClock: clock.clock, appLog: appLog, projection: projection
        ) { coordinator, client, sockets in
            await sockets[0].enqueue(helloFrame())
            await coordinator.start()
            await coordinator.noteDisconnected(connectionID: await client.activeConnectionID())
            coordinator.requestReconnect()
            coordinator.notePathHint(satisfied: false)
            try await waitForDiagnostics(projection, prefix: "reconnect.parked ", count: 1)

            // Foreground probes the stale hint, the probe fails, and no callback
            // follows: the foreground path must park like the bound does.
            let activation = coordinator.becameActive()
            try await sockets[1].waitUntilSent(count: 1)
            try await failHandshake(sockets[1])
            await activation?.value
            try await waitForDiagnostics(projection, prefix: "reconnect.parked ", count: 2)
            #expect(coordinator.reconnectStallGuard == nil)
            try await clock.waitUntilSleeping(
                count: 1, duration: GatewayLifecycleCoordinator.parkedRetryBound
            )
            #expect(await recordCount(in: appLog, event: "reconnect.stalled") == 0)

            await sockets[2].enqueue(helloFrame())
            clock.advance(by: GatewayLifecycleCoordinator.parkedRetryBound)
            try await sockets[2].waitUntilSent(count: 1)
            while coordinator.connectionState != .connected {
                try Task.checkCancellation()
                await Task.yield()
            }
        }
    }

    @Test("a path hint cannot park over the initial connect that owns the attempt")
    func pathHintDoesNotParkOverAnInFlightConnect() async throws {
        let clock = ManualClock()
        let watchdog = ManualClock()
        let logURL = FileManager.default.temporaryDirectory
            .appending(path: "reconnect-park-over-connect-\(UUID().uuidString).jsonl")
        defer {
            try? FileManager.default.removeItem(at: logURL)
            try? FileManager.default.removeItem(at: logURL.appendingPathExtension("1"))
        }
        let appLog = AppLog(fileURL: logURL)
        let projection = NoopGatewayLifecycleProjection()
        try await withRecordedCoordinator(
            sockets: [ScriptedGatewaySocket()],
            clock: clock, watchdogClock: watchdog.clock, appLog: appLog, projection: projection
        ) { coordinator, _, sockets in
            let start = Task { await coordinator.start() }
            try await sockets[0].waitUntilSent(count: 1)
            #expect(coordinator.connectionState == .connecting)
            // The hint arrives while the connect owns the attempt: parking would
            // publish `.reconnecting` over `.connecting` and trade a live attempt
            // for a bound it does not need.
            coordinator.notePathHint(satisfied: false)
            for _ in 0..<20 { await Task.yield() }
            #expect(coordinator.connectionState == .connecting)
            #expect(!projection.diagnostics.contains { $0.hasPrefix("reconnect.parked ") })
            #expect(clock.activeSleeperCount() == 0)

            await sockets[0].enqueue(helloFrame())
            await start.value
            #expect(coordinator.connectionState == .connected)
            #expect(!projection.diagnostics.contains { $0.hasPrefix("reconnect.parked ") })
        }
    }

    @Test("a foreground activation resumes a parked episode whose path hint is stale")
    func foregroundResumesParkedEpisode() async throws {
        let clock = ManualClock()
        let logURL = FileManager.default.temporaryDirectory
            .appending(path: "reconnect-parked-foreground-\(UUID().uuidString).jsonl")
        defer {
            try? FileManager.default.removeItem(at: logURL)
            try? FileManager.default.removeItem(at: logURL.appendingPathExtension("1"))
        }
        let appLog = AppLog(fileURL: logURL)
        let projection = NoopGatewayLifecycleProjection()
        try await withRecordedCoordinator(
            sockets: (0..<2).map { _ in ScriptedGatewaySocket() },
            clock: clock, watchdogClock: clock.clock, appLog: appLog, projection: projection
        ) { coordinator, client, sockets in
            await sockets[0].enqueue(helloFrame())
            await coordinator.start()
            await coordinator.noteDisconnected(connectionID: await client.activeConnectionID())
            coordinator.requestReconnect()
            coordinator.notePathHint(satisfied: false)
            try await clock.waitUntilSleeping(
                count: 1, duration: GatewayLifecycleCoordinator.parkedRetryBound
            )
            #expect(projection.diagnostics.contains { $0.hasPrefix("reconnect.parked ") })

            // Background parks recovery: the bound must not fire a socket for a
            // suspended app, so 60 s of bound time start nothing.
            coordinator.enteredBackground()
            clock.advance(by: .seconds(60))
            for _ in 0..<20 { await Task.yield() }
            #expect(await sockets[1].closeInvocationCount() == 0)

            // Foreground resumes the parked episode with one probe attempt even
            // though the last path hint still says unsatisfied.
            await sockets[1].enqueue(helloFrame())
            await coordinator.becameActive()?.value
            try await sockets[1].waitUntilSent(count: 1)
            while coordinator.connectionState != .connected {
                try Task.checkCancellation()
                await Task.yield()
            }
            #expect(await recordCount(in: appLog, event: "reconnect.stalled") == 0)
        }
    }

    @Test("a slow mounted restoration keeps the connected label and shows the chat's catch-up treatment")
    func slowRestorationKeepsConnectedLabel() async throws {
        let clock = ManualClock()
        try await withFixture(
            sockets: [ScriptedGatewaySocket(), ScriptedGatewaySocket()],
            clock: clock, units: SequenceReconnectUnits([])
        ) { fixture in
            let model = fixture.model
            let replacement = fixture.sockets[1]
            let profile = try #require(model.profiles.selected)
            // The replacement socket is live and this restoration's
            // `session.open` is never answered: the slow server work of the
            // incident. Held until this test answers it.
            let held = try await holdMountedRestoration(fixture)
            var index = held.index
            #expect(model.dashboardServerState(for: profile.id).label == "Connected")
            #expect(!model.noticeCenter.notices.contains { $0.replacement?.key == .sessionCatchUp })

            // The chat's own catch-up treatment appears once the restoration
            // outlasts its grace; the label never moves off the live socket.
            clock.advance(by: .seconds(3))
            for _ in 0..<400 {
                if model.noticeCenter.notices.contains(where: { $0.replacement?.key == .sessionCatchUp }) { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            let notice = try #require(model.noticeCenter.notices.first { $0.replacement?.key == .sessionCatchUp })
            #expect(notice.title == SessionPresentationStore.sessionCatchUpNotice)
            #expect(notice.scope == .session(id: held.target.sessionID, generation: held.target.generation))
            #expect(model.connectionState == .connected)
            #expect(model.dashboardServerState(for: profile.id).label == "Connected")
            #expect(model.mountedPresentationTarget == held.target)

            // The restoration completing retires the treatment; the socket
            // that admitted it is still the connection.
            let recovered = held.openID
            await replacement.enqueue(successResponse(id: recovered, result: .object([
                "session": try JSONValue.encode(held.snapshot),
                "syncToken": .string("slow-restoration-sync"),
                "subscriptionToken": .string("slow-restoration-subscription"),
            ])))
            var syncID: String?
            while syncID == nil {
                try await replacement.waitUntilSent(count: index + 1)
                let request = try requestFrame(await replacement.sentFrames()[index])
                index += 1
                switch request.method {
                case "session.sync": syncID = request.id
                case "session.list", "notification.inbox.list": break // Optional owners stay pending.
                default:
                    Issue.record("Unexpected request after mounted restoration: \(request.method)")
                    throw CancellationError()
                }
            }
            await replacement.enqueue(successResponse(id: try #require(syncID), result: .object(["synchronized": .bool(true)])))
            for _ in 0..<400 {
                if !model.isReconcilingForeground, !model.noticeCenter.notices.contains(where: { $0.replacement?.key == .sessionCatchUp }) {
                    break
                }
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(!model.isReconcilingForeground)
            #expect(!model.noticeCenter.notices.contains { $0.replacement?.key == .sessionCatchUp })
            #expect(model.connectionState == .connected)
            #expect(model.dashboardServerState(for: profile.id).label == "Connected")
            #expect(model.mountedPresentationTarget == held.target)
        }
    }

    @Test("leaving the chat inside the restoration grace never posts the catch-up notice")
    func leavingChatInsideRestorationGraceDropsTheTreatment() async throws {
        let clock = ManualClock()
        try await withFixture(
            sockets: [ScriptedGatewaySocket(), ScriptedGatewaySocket()],
            clock: clock, units: SequenceReconnectUnits([])
        ) { fixture in
            let model = fixture.model
            let held = try await holdMountedRestoration(fixture)

            // The user leaves the chat while its restoration still holds
            // `session.open`. The treatment belongs to the chat that left: it
            // must post neither into that chat's retired scope nor its
            // app-wide fallback.
            await model.closeSessionPresentation(held.target.sessionID, generation: held.target.generation)
            #expect(model.mountedPresentationTarget == nil)

            // The restoration's grace expires with the chat gone. The sleeper
            // is observed first, so the absence asserted next is the timer's
            // own decision rather than a wake-up that never happened.
            try await clock.waitUntilSleeping(count: 1, duration: .seconds(2))
            clock.advance(by: .seconds(3))
            for _ in 0..<50 { await Task.yield() }
            #expect(!model.noticeCenter.notices.contains { $0.replacement?.key == .sessionCatchUp })
            #expect(!model.noticeCenter.notices.contains { $0.title == SessionPresentationStore.sessionCatchUpNotice })
        }
    }

    @Test("opening another chat inside the restoration grace posts no catch-up notice into it")
    func openingAnotherChatInsideRestorationGraceDropsTheTreatment() async throws {
        let clock = ManualClock()
        try await withFixture(
            sockets: [ScriptedGatewaySocket(), ScriptedGatewaySocket()],
            clock: clock, units: SequenceReconnectUnits([])
        ) { fixture in
            let model = fixture.model
            let replacement = fixture.sockets[1]
            let held = try await holdMountedRestoration(fixture)
            let other = "scenario-other"
            var otherSnapshot = try SessionScenarioBuilder(seed: 61_205).openingTail(targetEncodedBytes: 2_048)
            otherSnapshot.sessionId = other
            model.sessions = [startupSummary(held.snapshot.sessionId), startupSummary(other)]

            // The abandoned restoration's `session.open` stays unanswered
            // while the user's own open completes: the mounted route is now
            // the other chat.
            var cursor = held.index
            let opening = Task { try await model.openSessionPresentation(other) }
            for _ in 0..<20 {
                if model.mountedPresentationTarget?.sessionID == other { break }
                try await replacement.waitUntilSent(count: cursor + 1)
                let frame = try JSONDecoder.gateway.decode(JSONValue.self, from: await replacement.sentFrames()[cursor])
                cursor += 1
                let method = try #require(frame.objectValue?["method"]?.stringValue)
                let id = try #require(frame.objectValue?["id"]?.stringValue)
                let sessionID = frame.objectValue?["params"]?.objectValue?["sessionId"]?.stringValue
                switch method {
                case "session.open" where sessionID == other:
                    await replacement.enqueue(successResponse(id: id, result: .object([
                        "session": try JSONValue.encode(otherSnapshot),
                        "syncToken": .string("other-sync"),
                        "subscriptionToken": .string("other-subscription"),
                    ])))
                case "session.sync":
                    await replacement.enqueue(successResponse(id: id, result: .object(["synchronized": .bool(true)])))
                case "session.commands":
                    await replacement.enqueue(successResponse(id: id, result: .object(["commands": .array([])])))
                case "session.list", "notification.inbox.list":
                    break // Optional owners stay pending.
                default:
                    Issue.record("Unexpected request while opening another chat: \(method)")
                    throw CancellationError()
                }
                // The mount is published by the client task processing that
                // response, so let the MainActor run before deciding.
                for _ in 0..<40 where model.mountedPresentationTarget?.sessionID != other {
                    try await Task.sleep(for: .milliseconds(1))
                }
            }
            _ = try await opening.value
            #expect(model.mountedPresentationTarget?.sessionID == other)

            try await clock.waitUntilSleeping(count: 1, duration: .seconds(2))
            clock.advance(by: .seconds(3))
            for _ in 0..<50 { await Task.yield() }
            #expect(!model.noticeCenter.notices.contains { $0.replacement?.key == .sessionCatchUp })
            #expect(!model.noticeCenter.notices.contains { $0.title == SessionPresentationStore.sessionCatchUpNotice })
        }
    }

    @Test("a socket drop during a slow mounted restoration starts the next attempt")
    func slowRestorationDoesNotParkRecovery() async throws {
        let clock = ManualClock()
        let logURL = FileManager.default.temporaryDirectory
            .appending(path: "reconnect-slow-restore-\(UUID().uuidString).jsonl")
        defer {
            try? FileManager.default.removeItem(at: logURL)
            try? FileManager.default.removeItem(at: logURL.appendingPathExtension("1"))
        }
        let appLog = AppLog(fileURL: logURL)
        let projection = BlockedRestoreProjection()
        try await withRecordedCoordinator(
            sockets: (0..<3).map { _ in ScriptedGatewaySocket() },
            clock: clock, watchdogClock: clock.clock, appLog: appLog, projection: projection
        ) { coordinator, client, sockets in
            await sockets[0].enqueue(helloFrame())
            await coordinator.start()
            #expect(coordinator.connectionState == .connected)
            await projection.waitForAggregateCompletion(count: 1)
            #expect(projection.aggregateCompletions == [true])

            // The replacement's handshake succeeds and its mounted restoration
            // never returns: the recorded shape of a loop parked in projection.
            await sockets[1].enqueue(helloFrame())
            coordinator.requestReconnect(immediate: true)
            try await projection.waitUntilRestoreStarted()
            // A live socket is Connected while its restoration runs, however
            // slow that restoration is (C-2).
            #expect(coordinator.connectionState == .connected)

            // The socket the handshake established now drops while restoration is
            // still running. The loop already ended at that handshake, so the
            // next attempt starts at once instead of waiting restoration out.
            await coordinator.noteDisconnected(connectionID: await client.activeConnectionID())
            coordinator.requestReconnect(immediate: true)
            try await sockets[2].waitUntilSent(count: 1)
            #expect(coordinator.connectionState == .reconnecting)
            // The stalled projection never published a result over the
            // replacement: its own admission settled as cancelled, so nothing
            // stays marked as reconciling.
            #expect(projection.aggregateCompletions == [true, false])
            // Let the parked restoration unwind before the fixture ends.
            projection.releaseRestore()
        }
    }

    /// A lifecycle coordinator whose attempts and episodes go to a test AppLog
    /// and whose watchdogs tick on their own clock, so a test can advance the
    /// watchdog grid without advancing the lifecycle timeline.
    private func withRecordedCoordinator(
        sockets: [ScriptedGatewaySocket],
        clock: ManualClock,
        watchdogClock: MonotonicClock,
        appLog: AppLog,
        projection: GatewayLifecycleProjectionDelegate = NoopGatewayLifecycleProjection(),
        operation: @escaping @MainActor @Sendable (
            GatewayLifecycleCoordinator, GatewayClient, [ScriptedGatewaySocket]
        ) async throws -> Void
    ) async throws {
        let suiteName = "GatewayConnectionRecordTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let profile = GatewayProfile(
            id: "gateway", label: "Mac", host: "gateway.test", port: 9_847,
            machineId: "machine", deviceId: "device"
        )
        defaults.set(try JSONEncoder.gateway.encode([profile]), forKey: "gatewayProfiles.v1")
        defaults.set(profile.id, forKey: "selectedGateway.v1")
        let factory = ScriptedGatewaySocketFactory(sockets: sockets)
        let client = GatewayClient(socketFactory: factory.factory)
        let coordinator = GatewayLifecycleCoordinator(
            client: client, profiles: GatewayProfileStore(defaults: defaults), clock: clock.clock,
            reconnectDelayPolicy: .standard, uuidSource: .random, pairer: GatewayPairer(),
            pairingCommit: { _, _ in }, profileTokenLookup: { _ in "token" },
            appLog: appLog, watchdogClock: watchdogClock
        )
        coordinator.delegate = projection
        do {
            try await withTestWatchdog {
                try await operation(coordinator, client, sockets)
            }
        } catch {
            await coordinator.teardown()
            await client.close()
            throw error
        }
        await coordinator.teardown()
        await client.close()
    }

    private func recordCount(in log: AppLog, event: String) async -> Int {
        await log.snapshot().filter { $0.event == event }.count
    }

    /// A lifecycle diagnostic the projection delegate received. Parking arms its
    /// bound before it records, so the record is the later half of the park.
    private func waitForDiagnostics(
        _ projection: NoopGatewayLifecycleProjection, prefix: String, count: Int
    ) async throws {
        for _ in 0..<600 {
            if projection.diagnostics.filter({ $0.hasPrefix(prefix) }).count >= count { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        Issue.record("timed out waiting for \(count) \(prefix) diagnostic(s)")
    }

    private func waitForRecords(
        in log: AppLog, event: String, count: Int
    ) async throws -> [AppLogRecord] {
        for _ in 0..<600 {
            let values = await log.snapshot().filter { $0.event == event }
            if values.count >= count { return values }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("timed out waiting for \(count) \(event) record(s)")
        return await log.snapshot().filter { $0.event == event }
    }

    private func withStartupCoordinator(
        cacheGate: TestReadGate? = nil,
        sockets: [ScriptedGatewaySocket]? = nil,
        operation: @escaping @MainActor @Sendable (
            GatewayLifecycleCoordinator, NoopGatewayLifecycleProjection,
            ScriptedGatewaySocketFactory, ScriptedGatewaySocket
        ) async throws -> Void
    ) async throws {
        let suiteName = "GatewayColdStartupTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let profile = GatewayProfile(id: "gateway", label: "Mac", host: "gateway.test", port: 9_847,
                                     machineId: "machine", deviceId: "device")
        defaults.set(profile.id, forKey: "selectedGateway.v1")
        let replacement = GatewayProfile(
            id: "replacement", label: "Replacement", host: "replacement.gateway.test", port: 9_847,
            machineId: "replacement-machine", deviceId: "replacement-device"
        )
        defaults.set(try JSONEncoder.gateway.encode([profile, replacement]), forKey: "gatewayProfiles.v1")
        let socket = sockets?.first ?? ScriptedGatewaySocket()
        if sockets == nil { await socket.enqueue(helloFrame()) }
        let factory = ScriptedGatewaySocketFactory(sockets: sockets ?? [socket])
        let client = GatewayClient(socketFactory: factory.factory)
        let projection = NoopGatewayLifecycleProjection(cacheGate: cacheGate)
        let coordinator = GatewayLifecycleCoordinator(
            client: client, profiles: GatewayProfileStore(defaults: defaults), clock: .continuous,
            reconnectDelayPolicy: .standard, uuidSource: .random, pairer: GatewayPairer(),
            pairingCommit: { _, _ in }, profileTokenLookup: { "token-for-\($0.id)" }
        )
        coordinator.delegate = projection
        do {
            try await withTestWatchdog {
                try await operation(coordinator, projection, factory, socket)
            }
        } catch {
            await cacheGate?.release()
            await coordinator.teardown()
            throw error
        }
        await cacheGate?.release()
        await coordinator.teardown()
    }

    private func withFixture(
        sockets: [ScriptedGatewaySocket],
        clock: ManualClock,
        units: SequenceReconnectUnits,
        recoveryClock: ManualClock? = nil,
        appLog: AppLog = .shared,
        operation: @escaping @MainActor @Sendable (ReconnectFixture) async throws -> Void
    ) async throws {
        let fixture = makeFixture(sockets: sockets, clock: clock, units: units, recoveryClock: recoveryClock, appLog: appLog)
        do {
            try await withTestWatchdog {
                try await operation(fixture)
            }
        } catch {
            await fixture.cleanup()
            throw error
        }
        await fixture.cleanup()
    }

    private func makeFixture(
        sockets: [ScriptedGatewaySocket],
        clock: ManualClock,
        units: SequenceReconnectUnits,
        recoveryClock: ManualClock? = nil,
        appLog: AppLog = .shared
    ) -> ReconnectFixture {
        let suiteName = "AppModelReconnectTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let profile = GatewayProfile(
            id: "gateway",
            label: "Mac",
            host: "gateway.test",
            port: 9_847,
            machineId: "machine",
            deviceId: "device"
        )
        defaults.set(try! JSONEncoder.gateway.encode([profile]), forKey: "gatewayProfiles.v1")
        defaults.set(profile.id, forKey: "selectedGateway.v1")
        let store = GatewayProfileStore(defaults: defaults)
        let socketFactory = ScriptedGatewaySocketFactory(sockets: sockets)
        let client = GatewayClient(socketFactory: socketFactory.factory)
        let cacheRoot = FileManager.default.temporaryDirectory.appending(path: suiteName, directoryHint: .isDirectory)
        let model = AppModel(
            client: client,
            profiles: store,
            cache: SnapshotCache(root: cacheRoot),
            clock: clock.clock,
            recoveryDisplayClock: recoveryClock?.clock ?? .continuous,
            reconnectDelayPolicy: ReconnectDelayPolicy(nextUnitInterval: units.next),
            profileTokenLookup: { _ in "token" },
            appLog: appLog
        )
        return ReconnectFixture(
            suiteName: suiteName,
            defaults: defaults,
            cacheRoot: cacheRoot,
            sockets: sockets,
            socketFactory: socketFactory,
            client: client,
            model: model
        )
    }
}

@MainActor
private final class NoopGatewayLifecycleProjection: GatewayLifecycleProjectionDelegate {
    private(set) var aggregateCompletions: [Bool] = []
    private var aggregateWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private(set) var cacheLoads = 0
    private var restoreResult = true
    private(set) var refreshCount = 0
    private var refreshWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private(set) var diagnostics: [String] = []
    private(set) var failures: [String] = []
    private let cacheGate: TestReadGate?

    init(cacheGate: TestReadGate? = nil) { self.cacheGate = cacheGate }

    func lifecycleLoadCache(profileID: String, admission: GatewayLifecycleCoordinator.Admission) async {
        cacheLoads += 1
        await cacheGate?.wait()
    }
    func lifecycleInvalidateSessionConnectionOwnership() {}
    func lifecycleBeginReconciliationAggregate(admission: GatewayLifecycleCoordinator.Admission) {}
    func lifecycleCompleteReconciliationAggregate(
        admission: GatewayLifecycleCoordinator.Admission,
        succeeded: Bool
    ) {
        aggregateCompletions.append(succeeded)
        let ready = aggregateWaiters.filter { aggregateCompletions.count >= $0.count }
        aggregateWaiters.removeAll { aggregateCompletions.count >= $0.count }
        for waiter in ready { waiter.continuation.resume() }
    }
    func lifecycleRecordDiagnostic(event: String, message: String) {
        diagnostics.append("\(event) \(message)")
    }
    func lifecycleRefreshAll(admission: GatewayLifecycleCoordinator.Admission) async {
        refreshCount += 1
        let ready = refreshWaiters.filter { refreshCount >= $0.count }
        refreshWaiters.removeAll { refreshCount >= $0.count }
        for waiter in ready { waiter.continuation.resume() }
    }
    func waitForRefresh(count: Int) async {
        if refreshCount >= count { return }
        await withCheckedContinuation { continuation in
            refreshWaiters.append((count: count, continuation: continuation))
        }
    }
    func waitForAggregateCompletion(count: Int) async {
        if aggregateCompletions.count >= count { return }
        await withCheckedContinuation { continuation in
            aggregateWaiters.append((count: count, continuation: continuation))
        }
    }
    func setRestoreResult(_ result: Bool) { restoreResult = result }
    func lifecycleRestoreMountedPresentation(admission: GatewayLifecycleCoordinator.Admission) async -> Bool { restoreResult }
    func lifecycleReattachTerminals(admission: GatewayLifecycleCoordinator.Admission) async {}
    func lifecycleReconcileForeground(admission: GatewayLifecycleCoordinator.Admission) async throws {}
    func lifecycleRetireProjection(final: Bool) async {}
    func lifecycleSurface(_ error: Error) { failures.append(error.localizedDescription) }
}

@MainActor
private final class FailFirstMountedRestoreProjection: GatewayLifecycleProjectionDelegate {
    private(set) var restoreCount = 0
    private(set) var aggregateCompletions: [Bool] = []
    private var aggregateWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private let blockRefresh: Bool
    private(set) var refreshStarted = false
    private var releaseRefreshContinuation: CheckedContinuation<Void, Never>?

    init(blockRefresh: Bool = false) { self.blockRefresh = blockRefresh }

    func lifecycleLoadCache(profileID: String, admission: GatewayLifecycleCoordinator.Admission) async {}
    func lifecycleInvalidateSessionConnectionOwnership() {}
    func lifecycleBeginReconciliationAggregate(admission: GatewayLifecycleCoordinator.Admission) {}
    func lifecycleCompleteReconciliationAggregate(
        admission: GatewayLifecycleCoordinator.Admission,
        succeeded: Bool
    ) {
        aggregateCompletions.append(succeeded)
        let ready = aggregateWaiters.filter { aggregateCompletions.count >= $0.count }
        aggregateWaiters.removeAll { aggregateCompletions.count >= $0.count }
        for waiter in ready { waiter.continuation.resume() }
    }

    func waitForAggregateCompletion(count: Int) async {
        if aggregateCompletions.count >= count { return }
        await withCheckedContinuation { continuation in
            aggregateWaiters.append((count: count, continuation: continuation))
        }
    }

    func lifecycleRefreshAll(admission: GatewayLifecycleCoordinator.Admission) async {
        guard blockRefresh else { return }
        refreshStarted = true
        await withCheckedContinuation { continuation in
            releaseRefreshContinuation = continuation
        }
    }

    func releaseRefresh() {
        releaseRefreshContinuation?.resume()
        releaseRefreshContinuation = nil
    }

    func lifecycleRestoreMountedPresentation(
        admission: GatewayLifecycleCoordinator.Admission
    ) async -> Bool {
        restoreCount += 1
        return restoreCount > 1
    }
    func lifecycleReattachTerminals(admission: GatewayLifecycleCoordinator.Admission) async {}
    func lifecycleReconcileForeground(admission: GatewayLifecycleCoordinator.Admission) async throws {}
    func lifecycleRetireProjection(final: Bool) async {}
    func lifecycleSurface(_ error: Error) {}
}

/// A presentation owner whose mounted restoration never returns until the test
/// releases it: the shape of slow projection work on an otherwise connected
/// socket. The initial connect's own restoration completes, so the test begins
/// from a connected lifecycle; the replacement's restoration is the one that
/// stalls.
@MainActor
private final class BlockedRestoreProjection: GatewayLifecycleProjectionDelegate {
    private(set) var aggregateCompletions: [Bool] = []
    private var restoreStartedContinuation: CheckedContinuation<Void, Never>?
    private var restoreContinuation: CheckedContinuation<Void, Never>?
    private var restoreCount = 0
    private var parked = false

    func waitUntilRestoreStarted() async {
        if parked { return }
        await withCheckedContinuation { restoreStartedContinuation = $0 }
    }

    func waitForAggregateCompletion(count: Int) async {
        for _ in 0..<600 {
            if aggregateCompletions.count >= count { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    func releaseRestore() {
        restoreContinuation?.resume()
        restoreContinuation = nil
    }

    func lifecycleLoadCache(profileID: String, admission: GatewayLifecycleCoordinator.Admission) async {}
    func lifecycleInvalidateSessionConnectionOwnership() {}
    func lifecycleBeginReconciliationAggregate(admission: GatewayLifecycleCoordinator.Admission) {}
    func lifecycleCompleteReconciliationAggregate(
        admission: GatewayLifecycleCoordinator.Admission,
        succeeded: Bool
    ) {
        aggregateCompletions.append(succeeded)
    }
    func lifecycleRefreshAll(admission: GatewayLifecycleCoordinator.Admission) async {}
    func lifecycleRestoreMountedPresentation(
        admission: GatewayLifecycleCoordinator.Admission
    ) async -> Bool {
        restoreCount += 1
        guard restoreCount > 1 else { return true }
        parked = true
        restoreStartedContinuation?.resume()
        restoreStartedContinuation = nil
        await withCheckedContinuation { restoreContinuation = $0 }
        return true
    }
    func lifecycleReattachTerminals(admission: GatewayLifecycleCoordinator.Admission) async {}
    func lifecycleReconcileForeground(admission: GatewayLifecycleCoordinator.Admission) async throws {}
    func lifecycleRetireProjection(final: Bool) async {}
    func lifecycleSurface(_ error: Error) {}
}

@MainActor
private final class FailFirstForegroundProjection: GatewayLifecycleProjectionDelegate {
    private(set) var reconciliationCount = 0
    private var reconciliationWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func waitForReconciliation(count: Int) async {
        if reconciliationCount >= count { return }
        await withCheckedContinuation { continuation in
            reconciliationWaiters.append((count, continuation))
        }
    }

    func lifecycleLoadCache(
        profileID: String,
        admission: GatewayLifecycleCoordinator.Admission
    ) async {}
    func lifecycleInvalidateSessionConnectionOwnership() {}
    func lifecycleBeginReconciliationAggregate(admission: GatewayLifecycleCoordinator.Admission) {}
    func lifecycleCompleteReconciliationAggregate(
        admission: GatewayLifecycleCoordinator.Admission,
        succeeded: Bool
    ) {}
    func lifecycleRefreshAll(admission: GatewayLifecycleCoordinator.Admission) async {}
    func lifecycleRestoreMountedPresentation(admission: GatewayLifecycleCoordinator.Admission) async -> Bool { true }
    func lifecycleReattachTerminals(admission: GatewayLifecycleCoordinator.Admission) async {}
    func lifecycleRetireProjection(final: Bool) async {}
    func lifecycleSurface(_ error: Error) {}

    func lifecycleReconcileForeground(
        admission: GatewayLifecycleCoordinator.Admission
    ) async throws {
        reconciliationCount += 1
        let ready = reconciliationWaiters.filter { reconciliationCount >= $0.count }
        reconciliationWaiters.removeAll { reconciliationCount >= $0.count }
        for waiter in ready { waiter.continuation.resume() }
        if reconciliationCount == 1 {
            throw GatewayFailure(
                code: "disconnected",
                message: "synthetic foreground failure",
                retryable: true,
                details: nil
            )
        }
    }
}

private final class SequenceReconnectUnits: Sendable {
    private let values: Mutex<[Double]>

    init(_ values: [Double]) {
        self.values = Mutex(values)
    }

    func next() -> Double {
        values.withLock { values in
            precondition(!values.isEmpty, "Reconnect jitter sequence exhausted")
            return values.removeFirst()
        }
    }
}

@MainActor
private struct ReconnectFixture {
    let suiteName: String
    let defaults: UserDefaults
    let cacheRoot: URL
    let sockets: [ScriptedGatewaySocket]
    let socketFactory: ScriptedGatewaySocketFactory
    let client: GatewayClient
    let model: AppModel

    func cleanup() async {
        await model.teardown()
        await client.close()
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: cacheRoot)
    }
}
