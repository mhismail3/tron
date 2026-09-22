import Foundation
import Observation
import Synchronization
import Testing
@testable import TronMobile

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
        try await withStartupCoordinator { coordinator, projection, factory, budget, _ in
            // Production starts NWPathMonitor before the root task, and sends
            // another path hint before awaiting notification badge cleanup.
            coordinator.notePathHint(satisfied: true)
            await coordinator.becameActive()?.value
            #expect(budget["gateway"]?.automaticAttempts ?? 0 == 0)
            #expect(budget["gateway"]?.firstFailureCode == nil)

            await coordinator.start()

            #expect(coordinator.connectionState == .connected)
            #expect(coordinator.hasResolvedLaunchState)
            #expect(factory.requests.count == 1)
            #expect(projection.cacheLoads == 1)
            #expect(projection.refreshCount == 1)
            #expect(projection.failures.isEmpty)
        }
    }

    @Test("pre-hello background retirement refunds its owner without exhausting foreground recovery")
    func repeatedPreHelloRetirement() async throws {
        let sockets = (0..<5).map { _ in ScriptedGatewaySocket() }
        try await withStartupCoordinator(sockets: sockets) { coordinator, projection, factory, budget, _ in
            let startup = Task { await coordinator.start() }
            for index in 0..<4 {
                if index > 0 { await coordinator.becameActive()?.value }
                try await sockets[index].waitUntilSent(count: 1)
                #expect(budget["gateway"]?.automaticAttempts == 1)
                coordinator.retryReconnect()
                // Retry must not rearm accounting while this hello owns it.
                #expect(budget["gateway"]?.automaticAttempts == 1)
                coordinator.enteredBackground()
                try await sockets[index].waitUntilClosed()
                while budget["gateway"]?.automaticAttempts != 0 {
                    try Task.checkCancellation()
                    await Task.yield()
                }
                #expect(budget["gateway"]?.firstFailureCode == nil)
            }
            await startup.value
            await sockets[4].enqueue(helloFrame())
            await coordinator.becameActive()?.value
            while projection.aggregateCompletions.isEmpty {
                try Task.checkCancellation()
                await Task.yield()
            }
            #expect(coordinator.connectionState == .connected)
            #expect(factory.requests.count == 5)
            #expect(budget["gateway"]?.automaticAttempts == 1)
        }
    }

    @Test("initial projection failure retains the live socket and settles reconciliation")
    func initialProjectionFailureKeepsTransport() async throws {
        try await withStartupCoordinator { coordinator, projection, factory, _, _ in
            projection.setRestoreResult(false)
            await coordinator.start()
            #expect(coordinator.connectionState == .connected)
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
            let catalog: (id: String, method: String)
            while true {
                try await socket.waitUntilSent(count: index + 1)
                let request = try requestFrame(await socket.sentFrames()[index])
                index += 1
                if request.method == "session.list" {
                    catalog = request
                    break
                }
                #expect(request.method == "notification.inbox.list")
            }
            #expect(fixture.model.sessionCatalogIsLoading)
            let startedMethods = try await socket.sentFrames().dropFirst().map { try requestFrame($0).method }
            #expect(Set(startedMethods).isSubset(of: ["session.list", "notification.inbox.list"]))
            let sessions = try JSONValue.encode([startupSummary("loaded")])
            let reply = Task {
                await socket.enqueue(successResponse(id: catalog.id, result: .object([
                    "sessions": sessions, "nextCursor": .null, "listRevision": .number(1)
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
                            "listRevision": .number(1), "nextCursor": .string("next-page"),
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
                case "provider.list", "model.list", "settings.get", "device.list", "notification.inbox.list":
                    break // These optional reads must not gate mounted readiness either.
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
        try await withStartupCoordinator(cacheGate: gate) { coordinator, projection, factory, budget, _ in
            let target = switching ? coordinator.profiles.profiles[1] : coordinator.profiles.selected!
            let start = Task {
                if switching { await coordinator.switchGateway(target) }
                else { await coordinator.start() }
            }
            do {
                try await gate.waitForEntry()
                let attemptsBeforeHint = budget[target.id]?.automaticAttempts ?? 0
                coordinator.notePathHint(satisfied: true)
                await coordinator.becameActive()?.value
                #expect(factory.requests.isEmpty)
                #expect(budget[target.id]?.automaticAttempts ?? 0 == attemptsBeforeHint)
                #expect(budget[target.id]?.firstFailureCode == nil)
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
        try await withStartupCoordinator(cacheGate: gate) { coordinator, projection, factory, _, _ in
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
        try await withStartupCoordinator(cacheGate: gate) { coordinator, projection, factory, budget, socket in
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
                #expect(budget["gateway"]?.automaticAttempts == 1)
                #expect(budget["gateway"]?.firstFailureCode == nil)
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
            #expect(clock.recordedSleeps() == [.seconds(1.6), .seconds(2)])

            clock.advance(by: .seconds(2))
            try await failHandshake(fixture.sockets[2])
            try await fixture.sockets[2].waitUntilClosed()
            for _ in 0..<20 { await Task.yield() }
            #expect(clock.recordedSleeps() == [.seconds(1.6), .seconds(2)])
            #expect(fixture.socketFactory.requests.count == 3)
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

    @Test("automatic recovery stops after three failed handshakes until explicit retry")
    func automaticRecoveryStopsUntilExplicitRetry() async throws {
        let clock = ManualClock()
        let sockets = (0..<5).map { _ in ScriptedGatewaySocket() }
        let units = SequenceReconnectUnits([0, 0.5, 1, 0.5])
        try await withFixture(sockets: sockets, clock: clock, units: units) { fixture in
            let start = Task { await fixture.model.start() }
            try await failHandshake(sockets[0])
            try await clock.waitUntilSleeping(count: 1)
            await start.value

            clock.advance(by: .seconds(1.6))
            try await failHandshake(sockets[1])
            try await clock.waitUntilSleeping(count: 1)
            clock.advance(by: .seconds(2))

            try await failHandshake(sockets[2])
            try await sockets[2].waitUntilClosed()
            for _ in 0..<20 { await Task.yield() }
            #expect(fixture.socketFactory.requests.count == 3)
            #expect(fixture.model.connectionState == .offline(GatewayRecoveryBudget.stoppedMessage))
            fixture.model.enteredBackground()
            fixture.model.becameActive()
            for _ in 0..<20 { await Task.yield() }
            await fixture.model.start()
            #expect(fixture.socketFactory.requests.count == 3)
            #expect(fixture.model.connectionState == .offline(GatewayRecoveryBudget.stoppedMessage))

            let profile = GatewayProfile(
                id: "gateway", label: "Mac", host: "gateway.test", port: 9_847,
                machineId: "machine", deviceId: "device"
            )
            fixture.model.retryGatewayConnection(for: profile)
            try await sockets[3].waitUntilSent(count: 1)
        }
    }

    @Test("no-path parking permits one fallback and explicit Retry despite a missed return callback")
    func noPathParkingAndExplicitRetry() async throws {
        let clock = ManualClock()
        let sockets = (0..<3).map { _ in ScriptedGatewaySocket() }
        try await withFixture(sockets: sockets, clock: clock, units: SequenceReconnectUnits([0, 0])) { fixture in
            let start = Task { await fixture.model.start() }
            try await failHandshake(sockets[0])
            try await clock.waitUntilSleeping(count: 1)
            await start.value
            fixture.model.lifecycleNotePathHint(satisfied: false)
            clock.advance(by: .seconds(1.6))
            try await sockets[1].waitUntilSent(count: 1)
            try await failHandshake(sockets[1])
            try await sockets[1].waitUntilClosed()
            await Task.yield()
            #expect(fixture.socketFactory.requests.count == 2)
            clock.advance(by: .seconds(30))
            await Task.yield()
            #expect(fixture.socketFactory.requests.count == 2)

            // The OS return callback is intentionally omitted. Explicit Retry
            // clears the stale path hint and owns the exact new attempt.
            let profile = GatewayProfile(
                id: "gateway", label: "Mac", host: "gateway.test", port: 9_847,
                machineId: "machine", deviceId: "device"
            )
            fixture.model.retryGatewayConnection(for: profile)
            try await sockets[2].waitUntilSent(count: 1)
            #expect(fixture.socketFactory.requests.count == 3)
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
            for _ in 0..<50 where projection.aggregateCompletions.isEmpty {
                await Task.yield()
            }
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

    @Test("background retirement serializes one fresh foreground connection")
    func backgroundRetirementOwnsForegroundReconnect() async throws {
        let suiteName = "GatewayLifecycleBackgroundTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let profile = GatewayProfile(
            id: "gateway", label: "Mac", host: "gateway.test", port: 9_847,
            machineId: "machine", deviceId: "device"
        )
        defaults.set(try JSONEncoder.gateway.encode([profile]), forKey: "gatewayProfiles.v1")
        defaults.set(profile.id, forKey: "selectedGateway.v1")
        let oldSocket = ScriptedGatewaySocket()
        let replacementSocket = ScriptedGatewaySocket()
        let factory = ScriptedGatewaySocketFactory(sockets: [oldSocket, replacementSocket])
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
        let projection = NoopGatewayLifecycleProjection()
        coordinator.delegate = projection

        let initial = Task { try await coordinator.connectHosted(profile: profile, token: "token") }
        try await oldSocket.waitUntilSent(count: 1)
        await oldSocket.enqueue(helloFrame())
        try await initial.value

        coordinator.enteredBackground()
        for _ in 0..<20 where !(await oldSocket.closed()) { await Task.yield() }
        #expect(await oldSocket.closed())
        #expect(coordinator.connectionState == .connected)

        let foreground = coordinator.becameActive()
        await replacementSocket.enqueue(helloFrame())
        for _ in 0..<20 where coordinator.connectionState != .connected { await Task.yield() }
        await foreground?.value
        #expect(factory.requests.count == 2)
        for _ in 0..<50 where projection.aggregateCompletions.isEmpty {
            await Task.yield()
        }
        #expect(projection.aggregateCompletions == [true])
        #expect(coordinator.connectionState == .connected)

        await coordinator.teardown()
        await client.close()
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
            let budget = GatewayRecoveryAllowanceStore()
            let projection = NoopGatewayLifecycleProjection()
            let coordinator = GatewayLifecycleCoordinator(client: client, profiles: GatewayProfileStore(defaults: defaults),
                clock: clock.clock, reconnectDelayPolicy: .standard, uuidSource: .random, pairer: GatewayPairer(),
                pairingCommit: { _, _ in }, profileTokenLookup: { _ in "fixture" }, recoveryBudgets: budget)
            coordinator.delegate = projection
            do {
                await sockets[0].enqueue(helloFrame())
                await coordinator.start()
                let initial = budget[profile.id]?.automaticAttempts
                coordinator.beginRestarting()
                await coordinator.noteDisconnected(connectionID: await client.activeConnectionID(), countsAsTransportFailure: false)
                coordinator.requestReconnect(immediate: true)
                try await sockets[1].waitUntilSent(count: 1)
                try await clock.waitUntilSleeping(count: 1, duration: .seconds(90))
                #expect(budget[profile.id]?.automaticAttempts == initial)
                clock.advance(by: .seconds(90))
                try await sockets[1].waitUntilClosed()
                #expect(budget[profile.id]?.isStopped == true)
                coordinator.notePathHint(satisfied: true)
                await coordinator.becameActive()?.value
                #expect(factory.requests.count == 2)
                coordinator.retryReconnect()
                try await sockets[2].waitUntilSent(count: 1)
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
                result = .object(["sessions": .array([]), "nextCursor": .null, "listRevision": .number(2)])
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

    private func startupSummary(_ id: String) -> SessionSummary {
        SessionSummary(
            id: id, name: id, cwd: "/workspace", parentSessionId: nil,
            createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:01Z",
            messageCount: 0, firstMessage: id, phase: .idle, summaryRevision: 1
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
            "protocolVersion": .number(5),
            "minProtocolVersion": .number(5),
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

    private func withStartupCoordinator(
        cacheGate: TestReadGate? = nil,
        sockets: [ScriptedGatewaySocket]? = nil,
        operation: @escaping @MainActor @Sendable (
            GatewayLifecycleCoordinator, NoopGatewayLifecycleProjection,
            ScriptedGatewaySocketFactory, GatewayRecoveryAllowanceStore, ScriptedGatewaySocket
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
        let budget = GatewayRecoveryAllowanceStore()
        let projection = NoopGatewayLifecycleProjection(cacheGate: cacheGate)
        let coordinator = GatewayLifecycleCoordinator(
            client: client, profiles: GatewayProfileStore(defaults: defaults), clock: .continuous,
            reconnectDelayPolicy: .standard, uuidSource: .random, pairer: GatewayPairer(),
            pairingCommit: { _, _ in }, profileTokenLookup: { "token-for-\($0.id)" }, recoveryBudgets: budget
        )
        coordinator.delegate = projection
        do {
            try await withTestWatchdog {
                try await operation(coordinator, projection, factory, budget, socket)
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
        operation: @escaping @MainActor @Sendable (ReconnectFixture) async throws -> Void
    ) async throws {
        let fixture = makeFixture(sockets: sockets, clock: clock, units: units)
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
        units: SequenceReconnectUnits
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
            reconnectDelayPolicy: ReconnectDelayPolicy(nextUnitInterval: units.next),
            profileTokenLookup: { _ in "token" }
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
    private(set) var cacheLoads = 0
    private var restoreResult = true
    private(set) var refreshCount = 0
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
    }
    func lifecycleRefreshAll(admission: GatewayLifecycleCoordinator.Admission) async { refreshCount += 1 }
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
