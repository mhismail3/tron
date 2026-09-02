import Foundation
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

        await coordinator.start()
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
            try await clock.waitUntilSleeping(count: 1)
            #expect(clock.recordedSleeps() == [
                .seconds(1.6),
                .seconds(2),
                .seconds(4.08),
            ])
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

        try await replacement.waitUntilSent(count: 6)
        #expect(model.connectionState == .connected)
        let reconnectFrames = await replacement.sentFrames()
        var refreshedMethods = Set<String>()
        for frame in reconnectFrames.dropFirst() {
            let request = try requestFrame(frame)
            refreshedMethods.insert(request.method)
            let result: JSONValue
            switch request.method {
            case "session.list":
                result = .object(["sessions": .array([]), "nextCursor": .null, "listRevision": .number(2)])
            case "provider.list": result = .object(["providers": .array([])])
            case "model.list": result = .object(["models": .array([]), "nextCursor": .null])
            case "settings.get": result = .object(["effective": .object([:])])
            case "device.list": result = .object(["devices": .array([])])
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
        let replacementText = reconnectFrames.compactMap { String(data: $0, encoding: .utf8) }.joined(separator: "\n")
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

    private func helloFrame(
        runtimeEpoch: String? = nil,
        machineID: String = "machine",
        gatewayChannel: String = "stable"
    ) -> Data {
        var value: [String: JSONValue] = [
            "type": .string("hello"),
            "gatewayVersion": .string("1.0.0"),
            "piVersion": .string("1.0.0"),
            "protocolVersion": .number(4),
            "minProtocolVersion": .number(4),
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
    func lifecycleRestoreMountedPresentation(admission: GatewayLifecycleCoordinator.Admission) async -> Bool { true }
    func lifecycleReattachTerminals(admission: GatewayLifecycleCoordinator.Admission) async {}
    func lifecycleReconcileForeground(admission: GatewayLifecycleCoordinator.Admission) async throws {}
    func lifecycleRetireProjection(final: Bool) async {}
    func lifecycleSurface(_ error: Error) {}
}

@MainActor
private final class FailFirstMountedRestoreProjection: GatewayLifecycleProjectionDelegate {
    private(set) var restoreCount = 0
    private(set) var aggregateCompletions: [Bool] = []

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
