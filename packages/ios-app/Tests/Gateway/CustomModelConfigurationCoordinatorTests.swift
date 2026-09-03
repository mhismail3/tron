import Foundation
import Observation
import Synchronization
import Testing
@testable import TronMobile

@MainActor
@Suite("Custom-model configuration coordinator")
struct CustomModelConfigurationCoordinatorTests {
    @Test("newest load wins, admitted errors surface, and profile clear rejects A-B-A completions")
    func loadAdmission() async throws {
        try await runScenario {
            let harness = try await makeHarness()
            let delegate = ErrorDelegate()
            harness.owner.delegate = delegate
            let older = Task { await harness.owner.load(target: .global) }
            try await harness.socket.waitUntilSent(count: 2)
            let newer = Task { await harness.owner.load(target: .global) }
            try await harness.socket.waitUntilSent(count: 3)
            let olderRequest = try request(await harness.socket.sentFrames()[1])
            let newerRequest = try request(await harness.socket.sentFrames()[2])
            #expect(newerRequest.method == "models.custom.get")
            #expect(newerRequest.params?.isEmpty == true)
            await harness.socket.enqueue(failure(id: olderRequest.id, message: "stale"))
            #expect(!(await older.value))
            #expect(delegate.messages.isEmpty)
            await harness.socket.enqueue(response(id: newerRequest.id, result: models("newer")))
            #expect(await newer.value)
            #expect(harness.owner.models(for: .global) == models("newer"))

            let admittedFailure = Task { await harness.owner.load(target: .global) }
            try await harness.socket.waitUntilSent(count: 4)
            let admittedRequest = try request(await harness.socket.sentFrames()[3])
            await harness.socket.enqueue(failure(id: admittedRequest.id, message: "admitted"))
            #expect(!(await admittedFailure.value))
            #expect(delegate.messages == ["admitted"])

            let pending = Task { await harness.owner.load(target: .global) }
            try await harness.socket.waitUntilSent(count: 5)
            let pendingRequest = try request(await harness.socket.sentFrames()[4])
            harness.owner.clearProfile()
            harness.owner.clearProfile()
            await harness.socket.enqueue(response(id: pendingRequest.id, result: models("late")))
            #expect(!(await pending.value))
            #expect(harness.owner.models(for: .global) == nil)
            #expect(CustomModelConfigurationCoordinator.requestTimeout == .seconds(30))
            await harness.client.close()
        }
    }

    @Test("validation precedes put with exact document and command ID")
    func validateBeforePut() async throws {
        try await runScenario {
            let harness = try await makeHarness(commandIDs: ["00000000-0000-0000-0000-000000000081"])
            let document: JSONValue = .object(["providers": .object([:])])
            let mutation = Task { try await harness.owner.replace(document, target: .global) }
            try await harness.socket.waitUntilSent(count: 2)
            let validation = try request(await harness.socket.sentFrames()[1])
            #expect(validation.method == "models.custom.validate")
            #expect(validation.params?["document"] == document)
            await harness.socket.enqueue(response(id: validation.id, result: .null))
            try await harness.socket.waitUntilSent(count: 3)
            let put = try request(await harness.socket.sentFrames()[2])
            #expect(put.method == "models.custom.put")
            #expect(put.params?["document"] == document)
            #expect(put.params?["commandId"] == .string("00000000-0000-0000-0000-000000000081"))
            await harness.socket.enqueue(response(id: put.id, result: .null))
            try await mutation.value
            await harness.client.close()
        }
    }

    @Test("validation failure and profile retirement never send put")
    func noPutAfterFailureOrRetirement() async throws {
        try await runScenario {
            let failureHarness = try await makeHarness()
            let failed = Task { try await failureHarness.owner.replace(models("document"), target: .global) }
            try await failureHarness.socket.waitUntilSent(count: 2)
            let validation = try request(await failureHarness.socket.sentFrames()[1])
            await failureHarness.socket.enqueue(failure(id: validation.id, message: "invalid"))
            await #expect(throws: GatewayFailure.self) { try await failed.value }
            #expect(await failureHarness.socket.sentFrames().count == 2)
            await failureHarness.client.close()

            let retiredHarness = try await makeHarness()
            let retired = Task { try await retiredHarness.owner.replace(models("document"), target: .global) }
            try await retiredHarness.socket.waitUntilSent(count: 2)
            let retiredValidation = try request(await retiredHarness.socket.sentFrames()[1])
            retiredHarness.owner.clearProfile()
            retiredHarness.owner.clearProfile()
            await retiredHarness.socket.enqueue(failure(id: retiredValidation.id, message: "retired validation failure"))
            await #expect(throws: CancellationError.self) { try await retired.value }
            #expect(await retiredHarness.socket.sentFrames().count == 2)
            await retiredHarness.client.close()
        }
    }

    @Test("older same-target validation errors cannot surface over a newer mutation")
    func supersededValidationErrorCancels() async throws {
        try await runScenario {
            let harness = try await makeHarness()
            let older = Task { try await harness.owner.replace(models("older"), target: .global) }
            try await harness.socket.waitUntilSent(count: 2)
            let olderValidation = try request(await harness.socket.sentFrames()[1])
            let newer = Task { try await harness.owner.replace(models("newer"), target: .global) }
            try await harness.socket.waitUntilSent(count: 3)
            let newerValidation = try request(await harness.socket.sentFrames()[2])
            await harness.socket.enqueue(failure(id: olderValidation.id, message: "older failure"))
            await #expect(throws: CancellationError.self) { try await older.value }
            await harness.socket.enqueue(failure(id: newerValidation.id, message: "newer failure"))
            do {
                try await newer.value
                Issue.record("current validation failure was hidden")
            } catch let failure as GatewayFailure {
                #expect(failure.message == "newer failure")
            }
            await harness.client.close()
        }
    }

    @Test("put failures preserve only the current mutation error")
    func putFailureAdmission() async throws {
        try await runScenario {
            let retiredHarness = try await makeHarness()
            let retired = Task { try await retiredHarness.owner.replace(models("retired"), target: .global) }
            try await retiredHarness.socket.waitUntilSent(count: 2)
            let retiredValidation = try request(await retiredHarness.socket.sentFrames()[1])
            await retiredHarness.socket.enqueue(response(id: retiredValidation.id, result: .null))
            try await retiredHarness.socket.waitUntilSent(count: 3)
            let retiredPut = try request(await retiredHarness.socket.sentFrames()[2])
            retiredHarness.owner.clearProfile()
            retiredHarness.owner.clearProfile()
            await retiredHarness.socket.enqueue(failure(id: retiredPut.id, message: "retired put failure"))
            await #expect(throws: CancellationError.self) { try await retired.value }
            await retiredHarness.client.close()

            let currentHarness = try await makeHarness()
            let current = Task { try await currentHarness.owner.replace(models("current"), target: .global) }
            try await currentHarness.socket.waitUntilSent(count: 2)
            let currentValidation = try request(await currentHarness.socket.sentFrames()[1])
            await currentHarness.socket.enqueue(response(id: currentValidation.id, result: .null))
            try await currentHarness.socket.waitUntilSent(count: 3)
            let currentPut = try request(await currentHarness.socket.sentFrames()[2])
            await currentHarness.socket.enqueue(failure(id: currentPut.id, message: "current put failure"))
            do {
                try await current.value
                Issue.record("current custom-model error was hidden")
            } catch let failure as GatewayFailure {
                #expect(failure.message == "current put failure")
            }
            await currentHarness.client.close()
        }
    }

    @Test("receipt uncertainty after profile retirement becomes cancellation")
    func retiredReceiptUncertainty() async throws {
        try await runScenario {
            let harness = try await makeHarness()
            let mutation = Task { try await harness.owner.replace(models("retired"), target: .global) }
            try await harness.socket.waitUntilSent(count: 2)
            let validation = try request(await harness.socket.sentFrames()[1])
            await harness.socket.failNextSend(GatewayFailure(
                code: "disconnected",
                message: "synthetic",
                retryable: true,
                details: nil
            ))
            await harness.socket.enqueue(response(id: validation.id, result: .null))
            try await harness.socket.waitUntilSent(count: 3)
            let status = try request(await harness.socket.sentFrames()[2])
            #expect(status.method == "command.status")
            harness.owner.clearProfile()
            harness.owner.clearProfile()
            await harness.lifecycle.teardown()
            await #expect(throws: CancellationError.self) { try await mutation.value }
        }
    }

    @Test("possibly-sent put uses centralized receipts and one stable command ID")
    func receiptResolution() async throws {
        try await runScenario {
            let harness = try await makeHarness(commandIDs: ["00000000-0000-0000-0000-000000000082"])
            let mutation = Task { try await harness.owner.replace(models("document"), target: .global) }
            try await harness.socket.waitUntilSent(count: 2)
            let validation = try request(await harness.socket.sentFrames()[1])
            await harness.socket.failNextSend(GatewayFailure(code: "disconnected", message: "synthetic", retryable: true, details: nil))
            await harness.socket.enqueue(response(id: validation.id, result: .null))
            try await harness.socket.waitUntilSent(count: 3)
            let status = try request(await harness.socket.sentFrames()[2])
            #expect(status.method == "command.status")
            #expect(status.params?["method"] == .string("models.custom.put"))
            #expect(status.params?["commandId"] == .string("00000000-0000-0000-0000-000000000082"))
            await harness.socket.enqueue(response(id: status.id, result: .object(["status": .string("missing")])))
            try await harness.socket.waitUntilSent(count: 4)
            let replay = try request(await harness.socket.sentFrames()[3])
            #expect(replay.method == "models.custom.put")
            #expect(replay.params?["commandId"] == status.params?["commandId"])
            await harness.socket.enqueue(response(id: replay.id, result: .null))
            try await mutation.value
            await harness.client.close()
        }
    }

    @Test("invalidation is event-only and AppModel observes nested custom-model state")
    func invalidationAndObservation() async throws {
        let model = AppModel()
        let projectionChanged = Mutex(false)
        let invalidationChanged = Mutex(false)
        withObservationTracking {
            _ = model.customModels(for: .global)
        } onChange: {
            projectionChanged.withLock { $0 = true }
        }
        withObservationTracking {
            _ = model.customModelInvalidationGeneration
        } onChange: {
            invalidationChanged.withLock { $0 = true }
        }
        model.installHostedCustomModels(models("installed"), for: .global)
        #expect(projectionChanged.withLock { $0 })
        #expect(model.customModelInvalidationGeneration == 0)
        await model.handle(GatewayEvent(type: "event", topic: "models.customChanged", sessionId: nil, payload: .object([:])))
        #expect(invalidationChanged.withLock { $0 })
        #expect(model.customModelInvalidationGeneration == 1)
    }

    @Test("save and restart share one lifecycle admission")
    func saveRestartLifecycle() async throws {
        try await runScenario {
            let socket = ScriptedGatewaySocket()
            let client = GatewayClient(socketFactory: ScriptedGatewaySocketFactory(socket: socket).factory)
            let ids = SequenceUUIDSource((83...85).map {
                UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", $0))!
            })
            let model = AppModel(client: client, uuidSource: ids.source)
            await socket.enqueue(helloFrame())
            try await model.connectHostedGateway(profile: profile, token: "token")
            let operation = Task { try await model.replaceCustomModelsAndRestart(models("document"), target: .global) }
            try await socket.waitUntilSent(count: 2)
            let validation = try request(await socket.sentFrames()[1])
            await socket.enqueue(response(id: validation.id, result: .null))
            try await socket.waitUntilSent(count: 3)
            let put = try request(await socket.sentFrames()[2])
            #expect(put.params?["commandId"] == .string("00000000-0000-0000-0000-000000000083"))
            await socket.enqueue(response(id: put.id, result: .null))
            try await socket.waitUntilSent(count: 4)
            let restart = try request(await socket.sentFrames()[3])
            #expect(restart.method == "gateway.restart")
            #expect(restart.params?["commandId"] == .string("00000000-0000-0000-0000-000000000084"))
            await socket.enqueue(response(id: restart.id, result: .object([
                "restarting": .bool(true),
                "scheduled": .bool(false),
                "activeSessionIds": .array([]),
            ])))
            try await operation.value
            #expect(ids.consumedCount == 3)
            await model.teardown()
        }
    }

    @Test("restart failure after lifecycle retirement becomes cancellation")
    func retirementPreventsRestartError() async throws {
        try await runScenario {
            let socket = ScriptedGatewaySocket()
            let client = GatewayClient(socketFactory: ScriptedGatewaySocketFactory(socket: socket).factory)
            let model = AppModel(client: client)
            await socket.enqueue(helloFrame())
            try await model.connectHostedGateway(profile: profile, token: "token")
            let operation = Task { try await model.replaceCustomModelsAndRestart(models("document"), target: .global) }
            defer { operation.cancel() }
            try await socket.waitUntilSent(count: 2)
            let validation = try request(await socket.sentFrames()[1])
            await socket.enqueue(response(id: validation.id, result: .null))
            try await socket.waitUntilSent(count: 3)
            let put = try request(await socket.sentFrames()[2])
            await socket.enqueue(response(id: put.id, result: .null))
            try await socket.waitUntilSent(count: 4)
            let restart = try request(await socket.sentFrames()[3])
            #expect(restart.method == "gateway.restart")
            await model.teardown()
            await #expect(throws: CancellationError.self) { try await operation.value }
        }
    }

    @Test("configuration presentation ignores cancellation but retains current errors")
    func configurationErrorPresentation() {
        let model = AppModel()
        model.presentError("existing")
        model.presentConfigurationActionError(CancellationError())
        #expect(model.visibleNotices.last?.title == "existing")
        model.presentConfigurationActionError(GatewayFailure(
            code: "synthetic",
            message: "current failure",
            retryable: false,
            details: nil
        ))
        #expect(model.visibleNotices.last?.title == "current failure")
    }

    @Test("draft save admission changes synchronously and clears only the exact submitted revision")
    func draftRevision() {
        var owner = CustomModelDraftOwner()
        let ignoredUnchangedValue = owner.markEdited(from: "same", to: "same")
        #expect(!ignoredUnchangedValue)
        #expect(!owner.isDirty)
        let admittedEdit = owner.markEdited(from: "before", to: "after")
        #expect(admittedEdit)
        #expect(owner.isDirty)
        let submitted = owner.beginSave()
        owner.markEdited()
        let staleCompleted = owner.completeSave(revision: submitted)
        #expect(!staleCompleted)
        #expect(owner.isDirty)
        let latest = owner.beginSave()
        let latestCompleted = owner.completeSave(revision: latest)
        #expect(latestCompleted)
        #expect(!owner.isDirty)
        #expect(owner.admitsPublication)
    }

    private final class ErrorDelegate: CustomModelConfigurationCoordinatorDelegate {
        var messages: [String] = []
        func customModelConfigurationCoordinatorSurface(_ error: Error) {
            messages.append(error.localizedDescription)
        }
    }

    private struct Harness {
        let socket: ScriptedGatewaySocket
        let client: GatewayClient
        let lifecycle: GatewayLifecycleCoordinator
        let owner: CustomModelConfigurationCoordinator
    }

    private struct Request {
        let id: String
        let method: String
        let params: [String: JSONValue]?
    }

    private func runScenario(_ operation: @escaping @MainActor @Sendable () async throws -> Void) async throws {
        let task = Task { @MainActor in try await operation() }
        defer { task.cancel() }
        try await withTestWatchdog { try await valueOfOwnedTask(task) }
    }

    private func makeHarness(commandIDs: [String] = []) async throws -> Harness {
        let socket = ScriptedGatewaySocket()
        let client = GatewayClient(socketFactory: ScriptedGatewaySocketFactory(socket: socket).factory)
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
        let owner = CustomModelConfigurationCoordinator(
            client: client,
            mutationExecutor: ConfirmedMutationExecutor(
                client: client,
                lifecycle: lifecycle,
                clock: .continuous,
                performanceSignposts: RecordingPerformanceSignposts()
            ),
            uuidSource: commandIDs.isEmpty
                ? .random
                : SequenceUUIDSource(commandIDs.compactMap(UUID.init(uuidString:))).source
        )
        await socket.enqueue(helloFrame())
        try await lifecycle.connectHosted(profile: profile, token: "token")
        return Harness(socket: socket, client: client, lifecycle: lifecycle, owner: owner)
    }

    private func request(_ data: Data) throws -> Request {
        let object = try #require(JSONDecoder.gateway.decode(JSONValue.self, from: data).objectValue)
        return Request(
            id: try #require(object["id"]?.stringValue),
            method: try #require(object["method"]?.stringValue),
            params: object["params"]?.objectValue
        )
    }

    private func models(_ marker: String) -> JSONValue {
        .object(["document": .object(["marker": .string(marker)])])
    }

    private func response(id: String, result: JSONValue) -> Data {
        try! JSONEncoder.gateway.encode(JSONValue.object([
            "type": .string("response"),
            "id": .string(id),
            "ok": .bool(true),
            "result": result,
        ]))
    }

    private func failure(id: String, message: String) -> Data {
        try! JSONEncoder.gateway.encode(JSONValue.object([
            "type": .string("response"),
            "id": .string(id),
            "ok": .bool(false),
            "error": .object([
                "code": .string("synthetic"),
                "message": .string(message),
                "retryable": .bool(false),
            ]),
        ]))
    }

    private var profile: GatewayProfile {
        GatewayProfile(id: "machine", label: "Mac", host: "gateway.test", port: 9_847, machineId: "machine", deviceId: "device")
    }

    private func helloFrame() -> Data {
        Data(#"{"type":"hello","gatewayVersion":"1.0.0","piVersion":"1.0.0","protocolVersion":4,"minProtocolVersion":4,"machineId":"machine","machineName":"Mac","gatewayChannel":"stable","capabilities":["sessions.v1","restart-drain.v1","restart-supervised.v1"]}"#.utf8)
    }
}
