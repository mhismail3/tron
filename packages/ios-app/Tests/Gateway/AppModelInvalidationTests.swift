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

    private func runPublicationScenario() async throws {
        let socket = ScriptedGatewaySocket()
        let client = GatewayClient(
            socketFactory: ScriptedGatewaySocketFactory(socket: socket).factory
        )
        await socket.enqueue(helloFrame())
        _ = try await client.connect(profile: profile, token: "token")
        do {
            try await exercisePublications(client: client, socket: socket)
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
        model.settingsInvalidationGeneration = 11
        model.packageInvalidationGeneration = 12
        model.customModelInvalidationGeneration = 13
        model.providerInvalidationGeneration = 14

        let settings = Task { await model.refreshSettings(useSelectedProject: false) }
        try await socket.waitUntilSent(count: 2)
        let settingsRequest = try await requestObject(at: 1, on: socket)
        #expect(settingsRequest["params"]?.objectValue?["scope"] == .string("global"))
        #expect(settingsRequest["params"]?.objectValue?["cwd"] == nil)
        try await respond(
            toFrameAt: 1,
            on: socket,
            result: .object(["effective": .object([:])])
        )
        await settings.value

        let packages = Task { await model.loadPackages() }
        try await socket.waitUntilSent(count: 3)
        try await respond(
            toFrameAt: 2,
            on: socket,
            result: .object(["packages": .array([]), "resources": .object([:])])
        )
        await packages.value

        let customModels = Task { await model.loadCustomModels() }
        try await socket.waitUntilSent(count: 4)
        try await respond(toFrameAt: 3, on: socket, result: .object(["providers": .object([:])]))
        await customModels.value

        let providers = Task { await model.refreshProviders(useSelectedProject: false) }
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
        await providers.value

        #expect(model.settingsInvalidationGeneration == 11)
        #expect(model.packageInvalidationGeneration == 12)
        #expect(model.customModelInvalidationGeneration == 13)
        #expect(model.providerInvalidationGeneration == 14)
        #expect(model.settings == .object(["effective": .object([:])]))
        #expect(model.packageState?.packages.isEmpty == true)
        #expect(model.customModels == .object(["providers": .object([:])]))
        #expect(model.providers.isEmpty)
        #expect(model.models.isEmpty)
        #expect(model.lastError == nil)
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

    private func requestObject(
        at index: Int,
        on socket: ScriptedGatewaySocket
    ) async throws -> [String: JSONValue] {
        let frames = await socket.sentFrames()
        return try JSONDecoder.gateway.decode(JSONValue.self, from: frames[index]).objectValue ?? [:]
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
