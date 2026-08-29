import Foundation
import Testing
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

    @Test("typed settings targets cannot encode project scope without a path")
    func settingsTargetRequiresProjectPath() {
        #expect(SettingsTarget(scope: .global, projectCWD: "/ignored") == .global)
        #expect(SettingsTarget(scope: .project, projectCWD: nil) == nil)
        #expect(SettingsTarget(scope: .project, projectCWD: "") == nil)
        #expect(SettingsTarget(scope: .project, projectCWD: "/workspace/project") == .project(cwd: "/workspace/project"))
        #expect(SettingsTarget.global.cwd == nil)
        #expect(SettingsTarget.project(cwd: "/workspace/project").scope == .project)

        let initial = SettingsLoadID(target: .global, invalidationGeneration: 0)
        #expect(initial != SettingsLoadID(target: .project(cwd: "/workspace/project"), invalidationGeneration: 0))
        #expect(initial != SettingsLoadID(target: .global, invalidationGeneration: 1))
    }

    @Test("package targets map only nonempty workspace paths")
    func packageTargets() {
        #expect(PackageConfigurationTarget(cwd: nil) == .global)
        #expect(PackageConfigurationTarget(cwd: "") == .global)
        #expect(PackageConfigurationTarget(cwd: "/workspace/project") == .workspace(cwd: "/workspace/project"))
        #expect(PackageConfigurationTarget.global.cwd == nil)
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

    @Test("custom-model draft edits reject automatic publication until saved")
    func customModelDraftAdmission() {
        var owner = CustomModelDraftOwner()
        #expect(owner.admitsPublication)
        owner.markEdited()
        #expect(!owner.admitsPublication)
        owner.markInstalled()
        #expect(owner.admitsPublication)
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
        try await withConnectedClient { client, socket in
            let model = AppModel(client: client)
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
        try await withConnectedClient { client, socket in
            let model = AppModel(client: client)
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
        try await withConnectedClient { client, socket in
            let model = AppModel(client: client)
            let session = ProviderCatalogTarget.session(id: "session-a")

            let globalLoad = Task { await model.refreshProviders(target: .global) }
            try await socket.waitUntilSent(count: 3)
            let sessionLoad = Task { await model.refreshProviders(target: session) }
            try await socket.waitUntilSent(count: 5)
            for index in 1...2 {
                let request = try await requestObject(at: index, on: socket)
                #expect(request["params"]?.objectValue?["sessionId"] == nil)
            }
            for index in 3...4 {
                let request = try await requestObject(at: index, on: socket)
                #expect(request["params"]?.objectValue?["sessionId"] == .string("session-a"))
            }
            try await respondToCatalogRequests(at: 3...4, on: socket, marker: "session")
            _ = await sessionLoad.value
            try await respondToCatalogRequests(at: 1...2, on: socket, marker: "global")
            _ = await globalLoad.value

            #expect(model.providerCatalog(for: .global)?.providers.first?.id == "global")
            #expect(model.providerCatalog(for: .global)?.models.first?.id == "global-model")
            #expect(model.providerCatalog(for: session)?.providers.first?.id == "session")
            #expect(model.providerCatalog(for: session)?.models.first?.id == "session-model")

            let olderLoad = Task { await model.refreshProviders(target: .global) }
            try await socket.waitUntilSent(count: 7)
            let newerLoad = Task { await model.refreshProviders(target: .global) }
            try await socket.waitUntilSent(count: 9)
            try await respondToCatalogRequests(at: 7...8, on: socket, marker: "newer")
            _ = await newerLoad.value
            try await respondToCatalogRequests(at: 5...6, on: socket, marker: "older")
            _ = await olderLoad.value

            #expect(model.providerCatalog(for: .global)?.providers.first?.id == "newer")
            #expect(model.providerCatalog(for: .global)?.models.first?.id == "newer-model")

            let auth = Task {
                try await model.beginAuth(providerID: "session", authType: "api_key", target: session)
            }
            try await socket.waitUntilSent(count: 10)
            try await respond(
                toFrameAt: 9,
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
            try await socket.waitUntilSent(count: 12)
            for index in 10...11 {
                let request = try await requestObject(at: index, on: socket)
                #expect(request["params"]?.objectValue?["sessionId"] == .string("session-a"))
            }
            try await respondToCatalogRequests(at: 10...11, on: socket, marker: "authenticated")
            await completion.value
            #expect(model.providerCatalog(for: session)?.providers.first?.id == "authenticated")

            await model.handle(GatewayEvent(
                type: "event",
                topic: "auth.completed",
                sessionId: nil,
                payload: .object(["operationId": .string("unknown-operation"), "success": .bool(true)])
            ))
            let sentCountAfterUnknownCompletion = await socket.sentFrames().count
            #expect(sentCountAfterUnknownCompletion == 12)

            let secondAuth = Task {
                try await model.beginAuth(providerID: "session", authType: "api_key", target: session)
            }
            try await socket.waitUntilSent(count: 13)
            try await respond(
                toFrameAt: 12,
                on: socket,
                result: .object(["operationId": .string("failed-cancel-operation")])
            )
            try await secondAuth.value

            let cancellation = Task { await model.cancelAuth(operationID: "failed-cancel-operation") }
            try await socket.waitUntilSent(count: 14)
            try await respondFailure(toFrameAt: 13, on: socket)
            await cancellation.value

            let completionAfterFailedCancel = Task {
                await model.handle(GatewayEvent(
                    type: "event",
                    topic: "auth.completed",
                    sessionId: nil,
                    payload: .object(["operationId": .string("failed-cancel-operation"), "success": .bool(true)])
                ))
            }
            try await socket.waitUntilSent(count: 16)
            for index in 14...15 {
                let request = try await requestObject(at: index, on: socket)
                #expect(request["params"]?.objectValue?["sessionId"] == .string("session-a"))
            }
            try await respondToCatalogRequests(at: 14...15, on: socket, marker: "after-failed-cancel")
            await completionAfterFailedCancel.value
            #expect(model.providerCatalog(for: session)?.providers.first?.id == "after-failed-cancel")
        }
    }

    private func withConnectedClient(
        _ operation: (GatewayClient, ScriptedGatewaySocket) async throws -> Void
    ) async throws {
        let socket = ScriptedGatewaySocket()
        let client = GatewayClient(
            socketFactory: ScriptedGatewaySocketFactory(socket: socket).factory
        )
        await socket.enqueue(helloFrame())
        _ = try await client.connect(profile: profile, token: "token")
        do {
            try await operation(client, socket)
        } catch {
            await client.close()
            throw error
        }
        await client.close()
    }

    private func exercisePublications(
        client: GatewayClient,
        socket: ScriptedGatewaySocket
    ) async throws {
        let model = AppModel(client: client)
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
        Data(#"{"type":"hello","gatewayVersion":"1.0.0","piVersion":"1.0.0","protocolVersion":4,"minProtocolVersion":4,"machineId":"machine","machineName":"Mac","gatewayChannel":"stable","capabilities":["sessions.v1"]}"#.utf8)
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
        at indices: ClosedRange<Int>,
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
