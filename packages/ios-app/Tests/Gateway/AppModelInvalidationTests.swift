import Foundation
import Observation
import Testing
@testable import TronMobileCore
@testable import TronMobile

@MainActor
@Suite("App model invalidation ownership")
struct AppModelInvalidationTests {
    @Test("successful publications do not invalidate their visible reload tasks")
    nonisolated func publicationDoesNotInvalidate() async throws {
        let scenario = Task { @MainActor in try await runPublicationScenario() }
        defer { scenario.cancel() }
        try await withTestWatchdog {
            try await valueOfOwnedTask(scenario)
        }
    }

    @Test("trust targets require an explicit nonempty project path")
    func trustTargets() {
        #expect(TrustTarget(cwd: "") == nil)
        let first = TrustTarget(cwd: "/workspace/project")!
        let second = TrustTarget(cwd: "/workspace/other")!
        #expect(first.cwd == "/workspace/project")

        var owner = TrustLoadOwner()
        owner.begin(target: first)
        #expect(!owner.isReady(for: first))
        owner.begin(target: second)
        let admittedStale = owner.admit(target: first)
        #expect(!admittedStale)
        let admittedCurrent = owner.admit(target: second)
        #expect(admittedCurrent)
        #expect(owner.isReady(for: second))
    }

    @Test("trust reads and mutations retain their exact project target")
    nonisolated func trustRequestsRetainTarget() async throws {
        let scenario = Task { @MainActor in try await runTrustTargetScenario() }
        defer { scenario.cancel() }
        try await withTestWatchdog {
            try await valueOfOwnedTask(scenario)
        }
    }

    @Test("out-of-order settings responses respect target and request ownership")
    nonisolated func settingsResponsesRemainKeyed() async throws {
        let scenario = Task { @MainActor in try await runSettingsOrderingScenario() }
        defer { scenario.cancel() }
        try await withTestWatchdog {
            try await valueOfOwnedTask(scenario)
        }
    }

    @Test("out-of-order provider catalogs respect target and request ownership")
    nonisolated func providerCatalogResponsesRemainKeyed() async throws {
        let scenario = Task { @MainActor in try await runProviderOrderingScenario() }
        defer { scenario.cancel() }
        try await withTestWatchdog {
            try await valueOfOwnedTask(scenario)
        }
    }

    private func runTrustTargetScenario() async throws {
        try await withConnectedClient { model, client, socket in
            let target = try #require(TrustTarget(cwd: "/workspace/project"))

            let inspection = Task { try await model.inspectTrust(target: target) }
            try await socket.waitUntilSent(count: 2)
            let inspectRequest = try await requestObject(at: 1, on: socket)
            #expect(inspectRequest["method"] == .string("trust.inspect"))
            #expect(inspectRequest["params"]?.objectValue?["cwd"] == .string("/workspace/project"))
            try await respond(toFrameAt: 1, on: socket, result: .object(["marker": .string("inspect")]))
            let inspectionValue = try await inspection.value
            #expect(inspectionValue == .object(["marker": .string("inspect")]))

            let mutation = Task { try await model.setTrust(target: target, decision: true) }
            try await socket.waitUntilSent(count: 3)
            let mutationRequest = try await requestObject(at: 2, on: socket)
            #expect(mutationRequest["method"] == .string("trust.set"))
            #expect(mutationRequest["params"]?.objectValue?["cwd"] == .string("/workspace/project"))
            #expect(mutationRequest["params"]?.objectValue?["decision"] == .bool(true))
            #expect(mutationRequest["params"]?.objectValue?["commandId"]?.stringValue != nil)
            try await respond(toFrameAt: 2, on: socket, result: .object(["marker": .string("set")]))
            let mutationValue = try await mutation.value
            #expect(mutationValue == .object(["marker": .string("set")]))
        }
    }

    private func runPublicationScenario() async throws {
        try await withConnectedClient(exercisePublications)
    }

    private func runSettingsOrderingScenario() async throws {
        try await withConnectedClient { model, client, socket in
            let project = SettingsTarget.project(cwd: "/workspace/project")
            let globalValue = JSONValue.object(["effective": .object(["marker": .string("global")])])
            let projectValue = JSONValue.object(["effective": .object(["marker": .string("project")])])

            let globalLoad = Task { await model.refreshSettings(target: .global) }
            try await socket.waitUntilSent(count: 2)
            let projectLoad = Task { await model.refreshSettings(target: project) }
            try await socket.waitUntilSent(count: 3)

            let globalRequest = try await requestObject(at: 1, on: socket)
            #expect(globalRequest["params"]?.objectValue?["scope"] == .string("global"))
            #expect(globalRequest["params"]?.objectValue?["cwd"] == nil)
            let projectRequest = try await requestObject(at: 2, on: socket)
            #expect(projectRequest["params"]?.objectValue?["scope"] == .string("project"))
            #expect(projectRequest["params"]?.objectValue?["cwd"] == .string("/workspace/project"))

            try await respond(toFrameAt: 2, on: socket, result: projectValue)
            _ = await projectLoad.value
            try await respond(toFrameAt: 1, on: socket, result: globalValue)
            _ = await globalLoad.value

            #expect(model.settings(for: .global) == globalValue)
            #expect(model.settings(for: project) == projectValue)

            let olderValue = JSONValue.object(["effective": .object(["marker": .string("older")])])
            let newerValue = JSONValue.object(["effective": .object(["marker": .string("newer")])])
            let olderLoad = Task { await model.refreshSettings(target: .global) }
            try await socket.waitUntilSent(count: 4)
            let newerLoad = Task { await model.refreshSettings(target: .global) }
            try await socket.waitUntilSent(count: 5)
            try await respond(toFrameAt: 4, on: socket, result: newerValue)
            _ = await newerLoad.value
            try await respond(toFrameAt: 3, on: socket, result: olderValue)
            _ = await olderLoad.value

            #expect(model.settings(for: .global) == newerValue)
        }
    }

    private func runProviderOrderingScenario() async throws {
        try await withConnectedClient { model, client, socket in
            let reads = ScriptedReadLog(socket: socket)
            let session = ProviderCatalogTarget.session(id: "session-a")

            let globalLoad = Task { await model.refreshProviders(target: .global) }
            let globalPair = try await reads.waitForPair(scope: nil)
            let sessionLoad = Task { await model.refreshProviders(target: session) }
            let sessionPair = try await reads.waitForPair(scope: "session-a")
            try await respondToCatalogRequests(at: sessionPair, on: socket, marker: "session")
            _ = await sessionLoad.value
            // The first completed catalog load warms the picker's Recent rail
            // with one `model.recent` read. A non-empty answer keeps that rail
            // warm, so no later catalog load repeats the warm.
            try await respondToRecentModelsWarm(on: socket, reads: reads)
            try await respondToCatalogRequests(at: globalPair, on: socket, marker: "global")
            _ = await globalLoad.value

            #expect(model.providerCatalog(for: .global)?.providers.first?.id == "global")
            #expect(model.providerCatalog(for: .global)?.models.first?.id == "global-model")
            #expect(model.providerCatalog(for: session)?.providers.first?.id == "session")
            #expect(model.providerCatalog(for: session)?.models.first?.id == "session-model")

            let olderLoad = Task { await model.refreshProviders(target: .global) }
            let olderPair = try await reads.waitForPair(scope: nil)
            let newerLoad = Task { await model.refreshProviders(target: .global) }
            let newerPair = try await reads.waitForPair(scope: nil)
            try await respondToCatalogRequests(at: newerPair, on: socket, marker: "newer")
            _ = await newerLoad.value
            try await respondToCatalogRequests(at: olderPair, on: socket, marker: "older")
            _ = await olderLoad.value

            #expect(model.providerCatalog(for: .global)?.providers.first?.id == "newer")
            #expect(model.providerCatalog(for: .global)?.models.first?.id == "newer-model")

            let auth = Task {
                try await model.beginAuth(providerID: "session", authType: "api_key", target: session)
            }
            try await respond(
                toFrameAt: reads.waitFor(method: "auth.begin", scope: "session-a"),
                on: socket,
                result: .object(["operationId": .string("auth-operation")])
            )
            try await auth.value

            let completion = Task {
                await model.handle(GatewayEvent(
                    type: "event",
                    topic: "auth.completed",
                    sessionId: nil,
                    payload: .object(["operationId": .string("auth-operation"), "success": .bool(true)])
                ))
            }
            let authenticatedPair = try await reads.waitForPair(scope: "session-a")
            let authenticatedPublication = observeProviderPublication(model, target: session)
            try await respondToCatalogRequests(at: authenticatedPair, on: socket, marker: "authenticated")
            await completion.value
            try await awaitPublication(authenticatedPublication)
            #expect(model.providerCatalog(for: session)?.providers.first?.id == "authenticated")

            let sentBeforeUnknownCompletion = await socket.sentFrames().count
            await model.handle(GatewayEvent(
                type: "event",
                topic: "auth.completed",
                sessionId: nil,
                payload: .object(["operationId": .string("unknown-operation"), "success": .bool(true)])
            ))
            #expect(await socket.sentFrames().count == sentBeforeUnknownCompletion)

            let secondAuth = Task {
                try await model.beginAuth(providerID: "session", authType: "api_key", target: session)
            }
            try await respond(
                toFrameAt: reads.waitFor(method: "auth.begin", scope: "session-a"),
                on: socket,
                result: .object(["operationId": .string("failed-cancel-operation")])
            )
            try await secondAuth.value

            let cancellation = Task { await model.cancelAuth(operationID: "failed-cancel-operation") }
            try await respondFailure(
                toFrameAt: reads.waitFor(method: "auth.cancel", scope: nil),
                on: socket
            )
            await cancellation.value

            let completionAfterFailedCancel = Task {
                await model.handle(GatewayEvent(
                    type: "event",
                    topic: "auth.completed",
                    sessionId: nil,
                    payload: .object(["operationId": .string("failed-cancel-operation"), "success": .bool(true)])
                ))
            }
            let afterFailedCancelPair = try await reads.waitForPair(scope: "session-a")
            let completionPublication = observeProviderPublication(model, target: session)
            try await respondToCatalogRequests(at: afterFailedCancelPair, on: socket, marker: "after-failed-cancel")
            await completionAfterFailedCancel.value
            try await awaitPublication(completionPublication)
            #expect(model.providerCatalog(for: session)?.providers.first?.id == "after-failed-cancel")
        }
    }

    private func observeProviderPublication(_ model: AppModel, target: ProviderCatalogTarget) -> AsyncStream<Void> {
        let signal = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        withObservationTracking { _ = model.providerCatalog(for: target) } onChange: {
            signal.continuation.yield(())
            signal.continuation.finish()
        }
        return signal.stream
    }

    private func awaitPublication(_ stream: AsyncStream<Void>) async throws {
        try await withTestWatchdog {
            var iterator = stream.makeAsyncIterator()
            guard await iterator.next() != nil else { throw CancellationError() }
        }
    }

    private func withConnectedClient(
        _ operation: (AppModel, GatewayClient, ScriptedGatewaySocket) async throws -> Void
    ) async throws {
        let socket = ScriptedGatewaySocket()
        let client = GatewayClient(
            socketFactory: ScriptedGatewaySocketFactory(socket: socket).factory
        )
        let defaultsName = "AppModelInvalidationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        let cacheRoot = FileManager.default.temporaryDirectory.appending(path: defaultsName)
        defaults.set(
            try JSONEncoder.gateway.encode([profile]),
            forKey: "gatewayProfiles.v1"
        )
        defaults.set(profile.id, forKey: "selectedGateway.v1")
        let model = AppModel(
            client: client,
            profiles: GatewayProfileStore(defaults: defaults),
            cache: SnapshotCache(root: cacheRoot)
        )
        await socket.enqueue(helloFrame())
        try await model.connectHostedGateway(profile: profile, token: "token")
        do {
            try await operation(model, client, socket)
        } catch {
            await model.teardown()
            await client.close()
            defaults.removePersistentDomain(forName: defaultsName)
            try? FileManager.default.removeItem(at: cacheRoot)
            throw error
        }
        await model.teardown()
        await client.close()
        defaults.removePersistentDomain(forName: defaultsName)
        try? FileManager.default.removeItem(at: cacheRoot)
    }

    private func exercisePublications(
        model: AppModel,
        client: GatewayClient,
        socket: ScriptedGatewaySocket
    ) async throws {
        model.setHostedSettingsInvalidationGeneration(11)
        model.setHostedPackageInvalidationGeneration(12)
        model.setHostedCustomModelInvalidationGeneration(13)
        model.setHostedProviderInvalidationGeneration(14)

        let settings = Task { await model.refreshSettings(target: .global) }
        try await socket.waitUntilSent(count: 2)
        let settingsRequest = try await requestObject(at: 1, on: socket)
        #expect(settingsRequest["params"]?.objectValue?["scope"] == .string("global"))
        #expect(settingsRequest["params"]?.objectValue?["cwd"] == nil)
        try await respond(
            toFrameAt: 1,
            on: socket,
            result: .object(["effective": .object([:])])
        )
        _ = await settings.value

        let packages = Task { await model.loadPackages(target: .global) }
        try await socket.waitUntilSent(count: 3)
        try await respond(
            toFrameAt: 2,
            on: socket,
            result: .object([
                "packages": .array([]),
                "resources": .object([
                    "extensions": .array([]),
                    "skills": .array([]),
                    "prompts": .array([]),
                    "themes": .array([]),
                ]),
            ])
        )
        _ = await packages.value

        let customModels = Task { await model.loadCustomModels(target: .global) }
        try await socket.waitUntilSent(count: 4)
        try await respond(toFrameAt: 3, on: socket, result: .object(["providers": .object([:])]))
        _ = await customModels.value

        let providers = Task { await model.refreshProviders(target: .global) }
        try await socket.waitUntilSent(count: 6)
        for index in 4...5 {
            let request = try await requestObject(at: index, on: socket)
            switch request["method"]?.stringValue {
            case "provider.list":
                try await respond(
                    toFrameAt: index,
                    on: socket,
                    result: .object(["providers": .array([])])
                )
            case "model.list":
                try await respond(
                    toFrameAt: index,
                    on: socket,
                    result: .object(["models": .array([]), "nextCursor": .null])
                )
            default:
                Issue.record("Unexpected catalog request: \(String(describing: request["method"]))")
            }
        }
        _ = await providers.value

        #expect(model.settingsInvalidationGeneration == 11)
        #expect(model.packageInvalidationGeneration == 12)
        #expect(model.customModelInvalidationGeneration == 13)
        #expect(model.providerInvalidationGeneration == 14)
        #expect(model.settings(for: .global) == .object(["effective": .object([:])]))
        #expect(model.packageInventory(for: .global)?.packages.isEmpty == true)
        #expect(model.customModels(for: .global) == .object(["providers": .object([:])]))
        #expect(model.providerCatalog(for: .global)?.providers.isEmpty == true)
        #expect(model.providerCatalog(for: .global)?.models.isEmpty == true)
        #expect(model.visibleNotices.isEmpty)
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
        Data(#"{"type":"hello","gatewayVersion":"1.0.0","piVersion":"1.0.0","protocolVersion":7,"minProtocolVersion":7,"machineId":"machine","machineName":"Mac","gatewayChannel":"stable","capabilities":["sessions.v1"]}"#.utf8)
    }

    private func requestObject(
        at index: Int,
        on socket: ScriptedGatewaySocket
    ) async throws -> [String: JSONValue] {
        let frames = await socket.sentFrames()
        return try JSONDecoder.gateway.decode(JSONValue.self, from: frames[index]).objectValue ?? [:]
    }

    private func respondToPackageRequest(
        at index: Int,
        on socket: ScriptedGatewaySocket,
        marker: String
    ) async throws {
        try await respond(
            toFrameAt: index,
            on: socket,
            result: .object([
                "packages": .array([.object([
                    "source": .string(marker),
                    "scope": .string("user"),
                    "filtered": .bool(false),
                    "installedPath": .null,
                ])]),
                "resources": .object(["marker": .string(marker)]),
            ])
        )
    }

    private func respondToCatalogRequests(
        at indices: [Int],
        on socket: ScriptedGatewaySocket,
        marker: String
    ) async throws {
        for index in indices {
            let request = try await requestObject(at: index, on: socket)
            switch request["method"]?.stringValue {
            case "provider.list":
                try await respond(
                    toFrameAt: index,
                    on: socket,
                    result: .object(["providers": .array([.object([
                        "id": .string(marker),
                        "name": .string(marker),
                        "configured": .bool(false),
                        "authSource": .null,
                        "credentialType": .null,
                        "authMethods": .array([]),
                        "modelCount": .number(1),
                    ])])])
                )
            case "model.list":
                try await respond(
                    toFrameAt: index,
                    on: socket,
                    result: .object([
                        "models": .array([.object([
                            "provider": .string(marker),
                            "id": .string("\(marker)-model"),
                            "name": .string(marker),
                            "reasoning": .bool(false),
                            "input": .array([.string("text")]),
                            "contextWindow": .number(4_096),
                            "maxTokens": .number(1_024),
                            "available": .bool(true),
                        ])]),
                        "nextCursor": .null,
                    ])
                )
            default:
                Issue.record("Unexpected catalog request: \(String(describing: request["method"]))")
            }
        }
    }

    /// A successful catalog load warms the model picker's Recent rail with one
    /// `model.recent` read, which this suite has to account for. The non-empty
    /// answer is the point: it leaves the rail warm, so no later catalog load
    /// repeats the read.
    private func respondToRecentModelsWarm(
        on socket: ScriptedGatewaySocket,
        reads: ScriptedReadLog
    ) async throws {
        let index = try await reads.waitFor(method: "model.recent", scope: nil)
        let request = try await requestObject(at: index, on: socket)
        #expect(request["method"] == .string("model.recent"))
        try await respond(
            toFrameAt: index,
            on: socket,
            result: .object(["models": .array([.object([
                "provider": .string("session"),
                "id": .string("session-model"),
                "lastUsedAt": .string("2026-09-28T00:00:00.000Z"),
            ])])])
        )
    }

    private func respondFailure(
        toFrameAt index: Int,
        on socket: ScriptedGatewaySocket
    ) async throws {
        let request = try await requestObject(at: index, on: socket)
        let id = try #require(request["id"]?.stringValue)
        await socket.enqueue(try JSONEncoder.gateway.encode(JSONValue.object([
            "type": .string("response"),
            "id": .string(id),
            "ok": .bool(false),
            "error": .object([
                "code": .string("cancel_failed"),
                "message": .string("Cancellation failed."),
                "retryable": .bool(true),
            ]),
        ])))
    }

    private func respond(
        toFrameAt index: Int,
        on socket: ScriptedGatewaySocket,
        result: JSONValue
    ) async throws {
        let request = try await requestObject(at: index, on: socket)
        let id = try #require(request["id"]?.stringValue)
        await socket.enqueue(try JSONEncoder.gateway.encode(JSONValue.object([
            "type": .string("response"),
            "id": .string(id),
            "ok": .bool(true),
            "result": result,
        ])))
    }
}

/// The scripted socket's write log addressed by what each read is, not where it
/// lands. A `cancel` control frame (`C-6`) or a read the model appends for a
/// reason the scenario did not pin (the picker's Recent-rail warm) appends a
/// frame, which shifts every later index; answering a shifted index leaves the
/// load the scenario meant to answer waiting forever, and the gate reports that
/// as a wait that ignores cancellation (`F-1`, `T-5`).
///
/// A read is found by method and scope and then reserved, so a second read with
/// the same method and scope is still distinguishable: the scenario answers two
/// `provider.list`/`model.list` pairs for `.global` out of order on purpose.
/// The order of the two requests inside one pair is not fixed (they are spawned
/// concurrently), so each is found by its own method.
@MainActor
private final class ScriptedReadLog {
    private let socket: ScriptedGatewaySocket
    private var reserved: Set<Int> = []

    init(socket: ScriptedGatewaySocket) {
        self.socket = socket
    }

    /// The oldest request frame the scenario has not answered yet whose method
    /// and scope match; a control frame carries no method and is skipped.
    func waitFor(method: String, scope: String?) async throws -> Int {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while true {
            if let index = try await nextIndex(method: method, scope: scope) {
                reserved.insert(index)
                return index
            }
            guard ContinuousClock.now < deadline else { throw ScriptedReadMissing(method: method, scope: scope) }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    /// Both reads of one catalog load for `scope`, oldest first.
    func waitForPair(scope: String?) async throws -> [Int] {
        [
            try await waitFor(method: "provider.list", scope: scope),
            try await waitFor(method: "model.list", scope: scope),
        ]
    }

    private func nextIndex(method: String, scope: String?) async throws -> Int? {
        let frames = await socket.sentFrames()
        for index in frames.indices where !reserved.contains(index) {
            guard let request = try? JSONDecoder.gateway.decode(JSONValue.self, from: frames[index]).objectValue,
                  request["type"] == .string("request"),
                  request["method"] == .string(method),
                  request["params"]?.objectValue?["sessionId"]?.stringValue == scope
            else { continue }
            return index
        }
        return nil
    }
}

/// No request for the read ever reached the scripted socket: the test names the
/// read it was waiting for instead of expiring its watchdog on a load that can
/// never be answered.
private struct ScriptedReadMissing: Error, CustomStringConvertible {
    let method: String
    let scope: String?

    var description: String {
        "the scenario never sent \(method)" + (scope.map { " for \($0)" } ?? "")
    }
}
