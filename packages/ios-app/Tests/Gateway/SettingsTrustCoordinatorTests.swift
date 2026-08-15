import Foundation
import Observation
import Synchronization
import Testing
@testable import TronMobile

@MainActor
@Suite("Settings and trust coordinator")
struct SettingsTrustCoordinatorTests {
    @Test("different targets admit independently and newer same-target reads win")
    func targetKeyedReadAdmission() async throws {
        try await runScenario {
            let harness = try await makeHarness()
            let project = SettingsTarget.project(cwd: "/workspace/project")

            let global = Task { await harness.owner.refreshSettings(target: .global) }
            try await harness.socket.waitUntilSent(count: 2)
            let projectLoad = Task { await harness.owner.refreshSettings(target: project) }
            try await harness.socket.waitUntilSent(count: 3)
            let first = try request(await harness.socket.sentFrames()[1])
            let second = try request(await harness.socket.sentFrames()[2])
            #expect(first.params?["scope"] == .string("global"))
            #expect(second.params?["scope"] == .string("project"))

            await harness.socket.enqueue(response(id: second.id, result: settingsValue("project")))
            await harness.socket.enqueue(response(id: first.id, result: settingsValue("global")))
            #expect(await global.value)
            #expect(await projectLoad.value)
            #expect(harness.owner.settings(for: .global) == settingsValue("global"))
            #expect(harness.owner.settings(for: project) == settingsValue("project"))

            let older = Task { await harness.owner.refreshSettings(target: .global) }
            try await harness.socket.waitUntilSent(count: 4)
            let newer = Task { await harness.owner.refreshSettings(target: .global) }
            try await harness.socket.waitUntilSent(count: 5)
            let olderRequest = try request(await harness.socket.sentFrames()[3])
            let newerRequest = try request(await harness.socket.sentFrames()[4])
            await harness.socket.enqueue(response(id: newerRequest.id, result: settingsValue("newer")))
            #expect(await newer.value)
            await harness.socket.enqueue(response(id: olderRequest.id, result: settingsValue("older")))
            #expect(!(await older.value))
            #expect(harness.owner.settings(for: .global) == settingsValue("newer"))
            await harness.client.close()
        }
    }

    @Test("profile clear atomically clears projections and rejects suspended reads")
    func profileClearRejectsLateRead() async throws {
        try await runScenario {
            let harness = try await makeHarness()
            harness.owner.installHostedSettings(settingsValue("retired"), for: .global)
            let load = Task { await harness.owner.refreshSettings(target: .global) }
            defer { load.cancel() }
            try await harness.socket.waitUntilSent(count: 2)
            let pending = try request(await harness.socket.sentFrames()[1])

            harness.owner.clearProfile()
            #expect(harness.owner.settings(for: .global) == nil)
            await harness.socket.enqueue(response(id: pending.id, result: settingsValue("late")))
            #expect(!(await load.value))
            #expect(harness.owner.settings(for: .global) == nil)
            await harness.client.close()
        }
    }

    @Test("profile clear rejects a suspended settings mutation before refresh")
    func profileClearRejectsSuspendedSettingsMutation() async throws {
        try await runScenario {
            let harness = try await makeHarness()
            harness.owner.installHostedSettings(settingsValue("retired"), for: .global)
            let update = Task {
                try await harness.owner.updateSettings(.object(["theme": .string("dark")]), target: .global)
            }
            defer { update.cancel() }
            try await harness.socket.waitUntilSent(count: 2)
            let pending = try request(await harness.socket.sentFrames()[1])
            #expect(pending.method == "settings.update")

            harness.owner.clearProfile()
            await harness.socket.enqueue(response(id: pending.id, result: .object(["updated": .bool(true)])))

            await #expect(throws: CancellationError.self) {
                try await update.value
            }
            #expect(harness.owner.settings(for: .global) == nil)
            #expect(await harness.socket.sentFrames().count == 2)
            await harness.client.close()
        }
    }

    @Test("profile clear rejects settings update while its post-mutation refresh is suspended")
    func profileClearRejectsPostMutationRefresh() async throws {
        try await runScenario {
            let harness = try await makeHarness()
            harness.owner.installHostedSettings(settingsValue("retired"), for: .global)
            let update = Task {
                try await harness.owner.updateSettings(.object(["theme": .string("dark")]), target: .global)
            }
            defer { update.cancel() }
            try await harness.socket.waitUntilSent(count: 2)
            let mutation = try request(await harness.socket.sentFrames()[1])
            await harness.socket.enqueue(response(id: mutation.id, result: .object(["updated": .bool(true)])))
            try await harness.socket.waitUntilSent(count: 3)
            let refresh = try request(await harness.socket.sentFrames()[2])
            #expect(refresh.method == "settings.get")

            harness.owner.clearProfile()
            await harness.socket.enqueue(response(id: refresh.id, result: settingsValue("late")))

            await #expect(throws: CancellationError.self) {
                try await update.value
            }
            #expect(harness.owner.settings(for: .global) == nil)
            await harness.client.close()
        }
    }

    @Test("profile clear rejects a suspended trust inspection")
    func profileClearRejectsSuspendedTrustInspection() async throws {
        try await runScenario {
            let harness = try await makeHarness()
            harness.owner.installHostedSettings(settingsValue("retired"), for: .global)
            let target = try #require(TrustTarget(cwd: "/workspace/project"))
            let inspection = Task { try await harness.owner.inspectTrust(target: target) }
            defer { inspection.cancel() }
            try await harness.socket.waitUntilSent(count: 2)
            let pending = try request(await harness.socket.sentFrames()[1])
            #expect(pending.method == "trust.inspect")

            harness.owner.clearProfile()
            await harness.socket.enqueue(response(id: pending.id, result: .object(["trusted": .bool(true)])))

            await #expect(throws: CancellationError.self) {
                _ = try await inspection.value
            }
            #expect(harness.owner.settings(for: .global) == nil)
            await harness.client.close()
        }
    }

    @Test("profile clear rejects a suspended trust mutation")
    func profileClearRejectsSuspendedTrustMutation() async throws {
        try await runScenario {
            let harness = try await makeHarness()
            harness.owner.installHostedSettings(settingsValue("retired"), for: .global)
            let target = try #require(TrustTarget(cwd: "/workspace/project"))
            let mutation = Task { try await harness.owner.setTrust(target: target, decision: true) }
            defer { mutation.cancel() }
            try await harness.socket.waitUntilSent(count: 2)
            let pending = try request(await harness.socket.sentFrames()[1])
            #expect(pending.method == "trust.set")

            harness.owner.clearProfile()
            await harness.socket.enqueue(response(id: pending.id, result: .object(["trusted": .bool(true)])))

            await #expect(throws: CancellationError.self) {
                _ = try await mutation.value
            }
            #expect(harness.owner.settings(for: .global) == nil)
            await harness.client.close()
        }
    }

    @Test("trust mutations encode true, false, and clear as exact wire values")
    func trustDecisionWireValues() async throws {
        try await runScenario {
            let harness = try await makeHarness()
            let target = try #require(TrustTarget(cwd: "/workspace/project"))
            let expected: [(Bool?, JSONValue)] = [
                (true, .bool(true)),
                (false, .bool(false)),
                (nil, .null),
            ]

            for (index, pair) in expected.enumerated() {
                let mutation = Task { try await harness.owner.setTrust(target: target, decision: pair.0) }
                defer { mutation.cancel() }
                try await harness.socket.waitUntilSent(count: index + 2)
                let pending = try request(await harness.socket.sentFrames()[index + 1])
                #expect(pending.method == "trust.set")
                #expect(pending.params?["cwd"] == .string("/workspace/project"))
                #expect(pending.params?["decision"] == pair.1)
                #expect(pending.params?["commandId"]?.stringValue != nil)
                await harness.socket.enqueue(response(id: pending.id, result: .object(["trusted": pair.1])))
                _ = try await mutation.value
            }
            await harness.client.close()
        }
    }

    @Test("successful reads and writes do not advance event-only invalidations")
    func requestsDoNotSelfInvalidate() async throws {
        try await runScenario {
            let harness = try await makeHarness()
            harness.owner.noteSettingsChanged()
            harness.owner.noteTrustChanged()
            let settingsGeneration = harness.owner.settingsInvalidationGeneration
            let trustRevision = harness.owner.trustRevision

            let read = Task { await harness.owner.refreshSettings(target: .global) }
            try await harness.socket.waitUntilSent(count: 2)
            let readRequest = try request(await harness.socket.sentFrames()[1])
            await harness.socket.enqueue(response(id: readRequest.id, result: settingsValue("read")))
            #expect(await read.value)

            let update = Task { try await harness.owner.updateSettings(.object(["defaultProvider": .string("provider")]), target: .global) }
            try await harness.socket.waitUntilSent(count: 3)
            let updateRequest = try request(await harness.socket.sentFrames()[2])
            #expect(updateRequest.method == "settings.update")
            #expect(updateRequest.params?["scope"] == .string("global"))
            #expect(updateRequest.params?["cwd"] == nil)
            #expect(updateRequest.params?["commandId"]?.stringValue != nil)
            await harness.socket.enqueue(response(id: updateRequest.id, result: .object(["updated": .bool(true)])))
            try await harness.socket.waitUntilSent(count: 4)
            let refreshRequest = try request(await harness.socket.sentFrames()[3])
            #expect(refreshRequest.method == "settings.get")
            await harness.socket.enqueue(response(id: refreshRequest.id, result: settingsValue("updated")))
            try await update.value

            let trustTarget = try #require(TrustTarget(cwd: "/workspace/project"))
            let inspect = Task { try await harness.owner.inspectTrust(target: trustTarget) }
            try await harness.socket.waitUntilSent(count: 5)
            let inspectRequest = try request(await harness.socket.sentFrames()[4])
            #expect(inspectRequest.method == "trust.inspect")
            #expect(inspectRequest.params?["cwd"] == .string("/workspace/project"))
            await harness.socket.enqueue(response(id: inspectRequest.id, result: .object(["trusted": .bool(false)])))
            _ = try await inspect.value

            let trust = Task { try await harness.owner.setTrust(target: trustTarget, decision: true) }
            try await harness.socket.waitUntilSent(count: 6)
            let trustRequest = try request(await harness.socket.sentFrames()[5])
            #expect(trustRequest.method == "trust.set")
            #expect(trustRequest.params?["decision"] == .bool(true))
            #expect(trustRequest.params?["commandId"]?.stringValue != nil)
            await harness.socket.enqueue(response(id: trustRequest.id, result: .object(["trusted": .bool(true)])))
            _ = try await trust.value

            #expect(harness.owner.settingsInvalidationGeneration == settingsGeneration)
            #expect(harness.owner.trustRevision == trustRevision)
            #expect(harness.owner.settings(for: .global) == settingsValue("updated"))
            await harness.client.close()
        }
    }

    @Test("trust events advance trust and settings invalidations exactly once")
    func trustEventSemantics() {
        let owner = makeDisconnectedOwner()
        owner.noteSettingsChanged()
        #expect(owner.settingsInvalidationGeneration == 1)
        #expect(owner.trustRevision == 0)
        owner.noteTrustChanged()
        #expect(owner.settingsInvalidationGeneration == 2)
        #expect(owner.trustRevision == 1)
    }

    @Test("facade consumers observe invalidations owned by the nested coordinator")
    func nestedObservationReachesFacadeConsumers() async {
        let model = AppModel()
        let didObserve = Mutex(false)
        withObservationTracking {
            _ = model.settingsInvalidationGeneration
            _ = model.trustRevision
        } onChange: {
            didObserve.withLock { $0 = true }
        }

        await model.handle(GatewayEvent(
            type: "event",
            topic: "trust.changed",
            sessionId: nil,
            payload: .object([:])
        ))
        #expect(didObserve.withLock { $0 })
        #expect(model.settingsInvalidationGeneration == 1)
        #expect(model.trustRevision == 1)
    }

    @Test("settings mutations use centralized receipt resolution and replay a stable command ID")
    func settingsMutationUsesReceipts() async throws {
        try await runScenario {
            let harness = try await makeHarness()
            await harness.socket.failNextSend(GatewayFailure(
                code: "disconnected",
                message: "synthetic send failure",
                retryable: true,
                details: nil
            ))
            let update = Task {
                try await harness.owner.updateSettings(.object(["theme": .string("dark")]), target: .global)
            }
            defer { update.cancel() }

            try await harness.socket.waitUntilSent(count: 2)
            let status = try request(await harness.socket.sentFrames()[1])
            #expect(status.method == "command.status")
            #expect(status.params?["method"] == .string("settings.update"))
            let stableID = try #require(status.params?["commandId"]?.stringValue)
            await harness.socket.enqueue(response(id: status.id, result: .object(["status": .string("missing")])))

            try await harness.socket.waitUntilSent(count: 3)
            let replay = try request(await harness.socket.sentFrames()[2])
            #expect(replay.method == "settings.update")
            #expect(replay.params?["commandId"] == .string(stableID))
            await harness.socket.enqueue(response(id: replay.id, result: .object(["updated": .bool(true)])))

            try await harness.socket.waitUntilSent(count: 4)
            let refresh = try request(await harness.socket.sentFrames()[3])
            #expect(refresh.method == "settings.get")
            await harness.socket.enqueue(response(id: refresh.id, result: settingsValue("confirmed")))
            try await update.value
            #expect(harness.owner.settings(for: .global) == settingsValue("confirmed"))
            await harness.client.close()
        }
    }


    private func runScenario(
        _ operation: @escaping @MainActor @Sendable () async throws -> Void
    ) async throws {
        let scenario = Task { @MainActor in try await operation() }
        defer { scenario.cancel() }
        try await withTestWatchdog {
            try await valueOfOwnedTask(scenario)
        }
    }

    private struct Harness {
        let socket: ScriptedGatewaySocket
        let client: GatewayClient
        let owner: SettingsTrustCoordinator
    }

    private struct Request {
        let id: String
        let method: String
        let params: [String: JSONValue]?
    }

    private func makeHarness() async throws -> Harness {
        let socket = ScriptedGatewaySocket()
        let client = GatewayClient(socketFactory: ScriptedGatewaySocketFactory(socket: socket).factory)
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        let lifecycle = GatewayLifecycleCoordinator(
            client: client,
            profiles: GatewayProfileStore(defaults: defaults),
            clock: .continuous,
            reconnectDelayPolicy: .standard,
            uuidSource: .random,
            pairer: GatewayPairer(),
            pairingCommit: { _, _ in },
            profileTokenLookup: { _ in nil }
        )
        let executor = ConfirmedMutationExecutor(
            client: client,
            lifecycle: lifecycle,
            clock: .continuous,
            performanceSignposts: RecordingPerformanceSignposts()
        )
        let owner = SettingsTrustCoordinator(
            client: client,
            mutationExecutor: executor,
            uuidSource: .random
        )
        await socket.enqueue(helloFrame())
        try await lifecycle.connectHosted(profile: profile, token: "token")
        return Harness(socket: socket, client: client, owner: owner)
    }

    private func makeDisconnectedOwner() -> SettingsTrustCoordinator {
        let client = GatewayClient()
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let lifecycle = GatewayLifecycleCoordinator(
            client: client,
            profiles: GatewayProfileStore(defaults: defaults),
            clock: .continuous,
            reconnectDelayPolicy: .standard,
            uuidSource: .random,
            pairer: GatewayPairer(),
            pairingCommit: { _, _ in },
            profileTokenLookup: { _ in nil }
        )
        return SettingsTrustCoordinator(
            client: client,
            mutationExecutor: ConfirmedMutationExecutor(
                client: client,
                lifecycle: lifecycle,
                clock: .continuous,
                performanceSignposts: RecordingPerformanceSignposts()
            ),
            uuidSource: .random
        )
    }

    private func request(_ data: Data) throws -> Request {
        let object = try #require(JSONDecoder.gateway.decode(JSONValue.self, from: data).objectValue)
        return Request(
            id: try #require(object["id"]?.stringValue),
            method: try #require(object["method"]?.stringValue),
            params: object["params"]?.objectValue
        )
    }

    private func settingsValue(_ marker: String) -> JSONValue {
        .object(["effective": .object(["marker": .string(marker)])])
    }

    private func response(id: String, result: JSONValue) -> Data {
        try! JSONEncoder.gateway.encode(JSONValue.object([
            "type": .string("response"),
            "id": .string(id),
            "ok": .bool(true),
            "result": result,
        ]))
    }

    private var profile: GatewayProfile {
        GatewayProfile(
            id: "machine",
            label: "Mac",
            host: "gateway.test",
            port: 9_847,
            machineId: "machine",
            deviceId: "device"
        )
    }

    private func helloFrame() -> Data {
        Data(#"{"type":"hello","gatewayVersion":"1.0.0","piVersion":"1.0.0","protocolVersion":2,"minProtocolVersion":2,"machineId":"machine","machineName":"Mac","capabilities":["sessions.v1"]}"#.utf8)
    }
}
