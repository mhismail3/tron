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
        #expect(coordinator.connectionState == .connected)

        await coordinator.teardown()
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
            #expect(fixture.model.lastError == nil)
            #expect(fixture.socketFactory.requests.count == 2)
            #expect(await active.closeTransitionCount() == 1)
        }
    }

    private func helloFrame() -> Data {
        Data(#"{"type":"hello","gatewayVersion":"1.0.0","piVersion":"1.0.0","protocolVersion":3,"minProtocolVersion":3,"machineId":"machine","machineName":"Mac","capabilities":["sessions.v1"]}"#.utf8)
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
    func lifecycleLoadCache(profileID: String, admission: GatewayLifecycleCoordinator.Admission) async {}
    func lifecycleInvalidateSessionConnectionOwnership() {}
    func lifecycleRefreshAll(admission: GatewayLifecycleCoordinator.Admission) async {}
    func lifecycleRestoreMountedPresentation(admission: GatewayLifecycleCoordinator.Admission) async {}
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
    func lifecycleRefreshAll(admission: GatewayLifecycleCoordinator.Admission) async {}
    func lifecycleRestoreMountedPresentation(admission: GatewayLifecycleCoordinator.Admission) async {}
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
