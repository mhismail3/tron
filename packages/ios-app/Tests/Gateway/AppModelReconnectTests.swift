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
