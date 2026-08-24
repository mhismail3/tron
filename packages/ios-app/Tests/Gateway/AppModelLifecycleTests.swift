import Foundation
import Synchronization
import Testing
@testable import TronMobile

@MainActor
@Suite("AppModel connection lifecycle ownership", .serialized)
struct AppModelLifecycleTests {
    @Test("the lifecycle owner revokes exact admissions across transitions and teardown")
    func coordinatorRevokesAdmissions() async throws {
        let suiteName = "GatewayLifecycleCoordinatorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let coordinator = GatewayLifecycleCoordinator(
            client: GatewayClient(),
            profiles: GatewayProfileStore(defaults: defaults),
            clock: .continuous,
            reconnectDelayPolicy: .standard,
            uuidSource: .random,
            pairer: GatewayPairer(),
            pairingCommit: { _, _ in },
            profileTokenLookup: { _ in nil }
        )

        let initial = try #require(coordinator.generationAdmission)
        #expect(initial.connectionID == nil)
        #expect(coordinator.admits(initial))

        #expect(await coordinator.forgetCurrentGateway())
        let replacement = try #require(coordinator.generationAdmission)
        #expect(replacement.generation > initial.generation)
        #expect(!coordinator.admits(initial))
        #expect(coordinator.admits(replacement))

        await coordinator.teardown()
        #expect(coordinator.generationAdmission == nil)
        #expect(!coordinator.admits(replacement))
        defaults.removePersistentDomain(forName: suiteName)
    }

    @Test("concurrent profile transitions cannot connect before an earlier retirement closes")
    func concurrentTransitionsSerializeRetirement() async throws {
        try await withTestWatchdog {
            try await performConcurrentTransitions()
        }
    }

    private func performConcurrentTransitions() async throws {
        let suiteName = "GatewayLifecycleTransitionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let initial = profile(id: "initial", host: "initial.gateway.test")
        let first = profile(id: "first", host: "first.gateway.test")
        let second = profile(id: "second", host: "second.gateway.test")
        defaults.set(
            try JSONEncoder.gateway.encode([initial, first, second]),
            forKey: "gatewayProfiles.v1"
        )
        defaults.set(initial.id, forKey: "selectedGateway.v1")
        let store = GatewayProfileStore(defaults: defaults)
        let socket = ScriptedGatewaySocket()
        let socketFactory = ScriptedGatewaySocketFactory(socket: socket)
        let client = GatewayClient(socketFactory: socketFactory.factory)
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
        let retirement = SuspendedLifecycleRetirement()
        coordinator.delegate = retirement

        let older = Task { await coordinator.switchGateway(first) }
        await retirement.waitUntilFirstRetirement()
        let newer = Task { await coordinator.switchGateway(second) }
        await Task.yield()
        #expect(socketFactory.requests.isEmpty)

        retirement.releaseFirstRetirement()
        await older.value
        try await socket.waitUntilSent(count: 1)
        #expect(store.selected?.id == second.id)
        #expect(socketFactory.requests.map { $0.url?.host } == [second.host])

        await coordinator.teardown()
        await newer.value
        await client.close()
        defaults.removePersistentDomain(forName: suiteName)
    }

    @Test("the AppModel lifecycle façade remains observable")
    func lifecycleFacadeObservation() async {
        let suiteName = "AppModelLifecycleObservationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let model = AppModel(
            client: GatewayClient(),
            profiles: GatewayProfileStore(defaults: defaults),
            cache: SnapshotCache(
                root: FileManager.default.temporaryDirectory.appending(path: suiteName)
            )
        )
        let changed = Mutex(false)
        withObservationTracking {
            _ = model.hasResolvedLaunchState
        } onChange: {
            changed.withLock { $0 = true }
        }

        await model.start()
        #expect(changed.withLock { $0 })
        #expect(model.hasResolvedLaunchState)
        await model.teardown()
        defaults.removePersistentDomain(forName: suiteName)
    }

    @Test("forget awaits transport close and prevents the retired connect from restarting")
    func forgetOwnsConnectionShutdown() async throws {
        try await withFixture(socketCount: 1) { fixture in
            let start = Task { await fixture.model.start() }
            defer { start.cancel() }
            try await fixture.sockets[0].waitUntilSent(count: 1)

            await fixture.model.forgetCurrentGateway()

            #expect(await fixture.sockets[0].closed())
            #expect(await fixture.sockets[0].closeTransitionCount() == 1)
            #expect(fixture.store.selected == nil)
            #expect(fixture.model.connectionState == .unpaired)
            fixture.model.becameActive()
            await Task.yield()
            #expect(fixture.socketFactory.requests.count == 1)
            await start.value
        }
    }

    @Test("switch closes the previous transport before the replacement connect starts")
    func switchSerializesProfileReplacement() async throws {
        try await withFixture(socketCount: 2) { fixture in
            let start = Task { await fixture.model.start() }
            defer { start.cancel() }
            try await fixture.sockets[0].waitUntilSent(count: 1)

            let switching = Task { await fixture.model.switchGateway(fixture.replacementProfile) }
            defer { switching.cancel() }
            try await fixture.sockets[0].waitUntilClosed()
            try await fixture.sockets[1].waitUntilSent(count: 1)

            #expect(await fixture.sockets[0].closeTransitionCount() == 1)
            #expect(fixture.store.selected?.id == fixture.replacementProfile.id)
            #expect(fixture.socketFactory.requests.map { $0.url?.host } == [
                fixture.initialProfile.host,
                fixture.replacementProfile.host,
            ])

            await fixture.model.teardown()
            await start.value
            await switching.value
            #expect(await fixture.sockets[1].closed())
        }
    }

    @Test("revoking the current device uses the same awaited lifecycle boundary")
    func currentDeviceRevokeOwnsShutdown() async throws {
        try await withFixture(socketCount: 1) { fixture in
            let connecting = Task {
                try await fixture.client.connect(profile: fixture.initialProfile, token: "token")
            }
            defer { connecting.cancel() }
            try await fixture.sockets[0].waitUntilSent(count: 1)
            await fixture.sockets[0].enqueue(helloFrame())
            _ = try await connecting.value

            let revoking = Task {
                try await fixture.model.revokeDevice(fixture.initialProfile.deviceId!)
            }
            defer { revoking.cancel() }
            try await fixture.sockets[0].waitUntilSent(count: 2)
            let frame = try #require(await fixture.sockets[0].sentFrames().last)
            let request = try JSONDecoder.gateway.decode(JSONValue.self, from: frame)
            let requestID = try #require(request.objectValue?["id"]?.stringValue)
            #expect(request.objectValue?["method"] == .string("device.revoke"))
            await fixture.sockets[0].enqueue(successResponse(
                id: requestID,
                result: .object(["revoked": .bool(true)])
            ))
            try await fixture.sockets[0].waitUntilClosed()
            try await revoking.value

            #expect(fixture.store.selected == nil)
            #expect(fixture.model.connectionState == .unpaired)
            #expect(await fixture.sockets[0].closeTransitionCount() == 1)
        }
    }

    @Test("profile teardown stops uncertain legacy import before replacement-profile receipt work")
    func legacyImportCannotCrossProfileBoundary() async throws {
        try await withFixture(socketCount: 1) { fixture in
            let connecting = Task {
                try await fixture.client.connect(profile: fixture.initialProfile, token: "token")
            }
            defer { connecting.cancel() }
            try await fixture.sockets[0].waitUntilSent(count: 1)
            await fixture.sockets[0].enqueue(helloFrame())
            _ = try await connecting.value

            let importing = Task { try await fixture.model.importLegacySessions() }
            defer { importing.cancel() }
            try await fixture.sockets[0].waitUntilSent(count: 2)
            await fixture.model.teardown()
            do {
                try await importing.value
                Issue.record("retired profile import unexpectedly completed")
            } catch let failure as GatewayFailure {
                #expect(failure.code == "outcome_unknown")
            } catch {
                Issue.record("unexpected import error: \(error)")
            }

            #expect(fixture.model.legacyImportedCount == 0)
            #expect(fixture.model.visibleNotices.isEmpty)
            #expect(fixture.socketFactory.requests.count == 1)
        }
    }

    @Test("profile teardown rejects a late legacy inspection failure")
    func legacyInspectionCannotPublishAfterTeardown() async throws {
        try await withFixture(socketCount: 1) { fixture in
            let connecting = Task {
                try await fixture.client.connect(profile: fixture.initialProfile, token: "token")
            }
            defer { connecting.cancel() }
            try await fixture.sockets[0].waitUntilSent(count: 1)
            await fixture.sockets[0].enqueue(helloFrame())
            _ = try await connecting.value

            let inspection = Task { await fixture.model.inspectLegacyImport() }
            defer { inspection.cancel() }
            try await fixture.sockets[0].waitUntilSent(count: 2)
            await fixture.model.teardown()
            await inspection.value

            #expect(!fixture.model.legacyImportAvailable)
            #expect(fixture.model.legacyImportedCount == 0)
            #expect(fixture.model.visibleNotices.isEmpty)
        }
    }

    @Test("concurrent teardown callers share the same close completion")
    func concurrentTeardownSharesCompletion() async throws {
        try await withFixture(socketCount: 1, suspendsClose: true) { fixture in
            let start = Task { await fixture.model.start() }
            defer { start.cancel() }
            try await fixture.sockets[0].waitUntilSent(count: 1)

            let first = Task { await fixture.model.teardown() }
            defer { first.cancel() }
            try await fixture.sockets[0].waitUntilCloseInvoked()
            var secondCompleted = false
            let second = Task {
                await fixture.model.teardown()
                secondCompleted = true
            }
            defer { second.cancel() }
            await Task.yield()
            #expect(!secondCompleted)

            await fixture.sockets[0].releaseClose()
            await first.value
            await second.value
            await start.value
            #expect(secondCompleted)
            #expect(await fixture.sockets[0].closeTransitionCount() == 1)
        }
    }

    @Test("final teardown is idempotent and rejects subsequent events and reconnect requests")
    func finalTeardownIsTerminal() async throws {
        try await withFixture(socketCount: 1) { fixture in
            let start = Task { await fixture.model.start() }
            defer { start.cancel() }
            try await fixture.sockets[0].waitUntilSent(count: 1)

            await fixture.model.teardown()
            await fixture.model.teardown()
            let settingsGeneration = fixture.model.settingsInvalidationGeneration
            await fixture.model.handle(GatewayEvent(
                type: "event",
                topic: "settings.changed",
                sessionId: nil,
                payload: .object([:])
            ))
            fixture.model.becameActive()
            await Task.yield()

            #expect(await fixture.sockets[0].closeTransitionCount() == 1)
            #expect(fixture.socketFactory.requests.count == 1)
            #expect(fixture.model.settingsInvalidationGeneration == settingsGeneration)
            await start.value
        }
    }

    @Test("settings restart surfaces current actionable failures")
    func settingsRestartSurfacesFailure() async throws {
        try await withFixture(socketCount: 1) { fixture in
            await fixture.model.requestGatewayRestart()
            #expect(fixture.model.visibleNotices.last?.title == "This Gateway is not supervised for remote restart. Install or relaunch the managed Tron Mac app, then retry; direct foreground Gateway processes must be restarted from their supervisor.")
        }
    }

    private func withFixture(
        socketCount: Int,
        suspendsClose: Bool = false,
        operation: @escaping @MainActor @Sendable (LifecycleFixture) async throws -> Void
    ) async throws {
        let fixture = makeFixture(socketCount: socketCount, suspendsClose: suspendsClose)
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

    private func makeFixture(socketCount: Int, suspendsClose: Bool) -> LifecycleFixture {
        let suiteName = "AppModelLifecycleTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let initial = profile(id: "initial", host: "initial.gateway.test")
        let replacement = profile(id: "replacement", host: "replacement.gateway.test")
        let profiles = socketCount > 1 ? [initial, replacement] : [initial]
        defaults.set(try! JSONEncoder.gateway.encode(profiles), forKey: "gatewayProfiles.v1")
        defaults.set(initial.id, forKey: "selectedGateway.v1")
        let store = GatewayProfileStore(defaults: defaults)
        let sockets = (0..<socketCount).map { _ in ScriptedGatewaySocket(suspendsClose: suspendsClose) }
        let socketFactory = ScriptedGatewaySocketFactory(sockets: sockets)
        let client = GatewayClient(socketFactory: socketFactory.factory)
        let cacheRoot = FileManager.default.temporaryDirectory.appending(path: suiteName, directoryHint: .isDirectory)
        let model = AppModel(
            client: client,
            profiles: store,
            cache: SnapshotCache(root: cacheRoot),
            profileTokenLookup: { profile in "token-for-\(profile.id)" }
        )
        return LifecycleFixture(
            suiteName: suiteName,
            defaults: defaults,
            cacheRoot: cacheRoot,
            store: store,
            sockets: sockets,
            socketFactory: socketFactory,
            client: client,
            model: model,
            initialProfile: initial,
            replacementProfile: replacement,
            setupDefaults: SetupDefaults.capture()
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

    private func helloFrame() -> Data {
        Data(#"{"type":"hello","gatewayVersion":"1.0.0","piVersion":"1.0.0","protocolVersion":3,"minProtocolVersion":3,"machineId":"machine","machineName":"Mac","gatewayChannel":"stable","capabilities":["sessions.v1"]}"#.utf8)
    }

    private func profile(id: String, host: String) -> GatewayProfile {
        GatewayProfile(
            id: id,
            label: id.capitalized,
            host: host,
            port: 9_847,
            machineId: "machine-\(id)",
            deviceId: "device-\(id)"
        )
    }
}

@MainActor
private final class SuspendedLifecycleRetirement: GatewayLifecycleProjectionDelegate {
    private var firstRetirementStarted = false
    private var firstRetirementStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstRetirementContinuation: CheckedContinuation<Void, Never>?
    private var retirementCount = 0

    func waitUntilFirstRetirement() async {
        if firstRetirementStarted { return }
        await withCheckedContinuation { continuation in
            firstRetirementStartWaiters.append(continuation)
        }
    }

    func releaseFirstRetirement() {
        firstRetirementContinuation?.resume()
        firstRetirementContinuation = nil
    }

    func lifecycleLoadCache(
        profileID: String,
        admission: GatewayLifecycleCoordinator.Admission
    ) async {}
    func lifecycleInvalidateSessionConnectionOwnership() {}
    func lifecycleRefreshAll(admission: GatewayLifecycleCoordinator.Admission) async {}
    func lifecycleRestoreMountedPresentation(admission: GatewayLifecycleCoordinator.Admission) async -> Bool { true }
    func lifecycleReattachTerminals(admission: GatewayLifecycleCoordinator.Admission) async {}
    func lifecycleReconcileForeground(admission: GatewayLifecycleCoordinator.Admission) async throws {}
    func lifecycleSurface(_ error: Error) {}

    func lifecycleRetireProjection(final: Bool) async {
        retirementCount += 1
        guard retirementCount == 1 else { return }
        firstRetirementStarted = true
        let waiters = firstRetirementStartWaiters
        firstRetirementStartWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { continuation in
            firstRetirementContinuation = continuation
        }
    }
}

@MainActor
private struct LifecycleFixture {
    let suiteName: String
    let defaults: UserDefaults
    let cacheRoot: URL
    let store: GatewayProfileStore
    let sockets: [ScriptedGatewaySocket]
    let socketFactory: ScriptedGatewaySocketFactory
    let client: GatewayClient
    let model: AppModel
    let initialProfile: GatewayProfile
    let replacementProfile: GatewayProfile
    let setupDefaults: SetupDefaults

    func cleanup() async {
        await model.teardown()
        await client.close()
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: cacheRoot)
        setupDefaults.restore()
    }
}

private struct SetupDefaults: Sendable {
    private struct Value: Sendable {
        let existed: Bool
        let bool: Bool
    }

    private let tronSetup: Value
    private let legacySetup: Value

    static func capture() -> SetupDefaults {
        let defaults = UserDefaults.standard
        return SetupDefaults(
            tronSetup: Value(
                existed: defaults.object(forKey: "tronSetupComplete.v1") != nil,
                bool: defaults.bool(forKey: "tronSetupComplete.v1")
            ),
            legacySetup: Value(
                existed: defaults.object(forKey: "piSetupComplete.v1") != nil,
                bool: defaults.bool(forKey: "piSetupComplete.v1")
            )
        )
    }

    @MainActor
    func restore() {
        restore(tronSetup, key: "tronSetupComplete.v1")
        restore(legacySetup, key: "piSetupComplete.v1")
    }

    @MainActor
    private func restore(_ value: Value, key: String) {
        if value.existed {
            UserDefaults.standard.set(value.bool, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}
