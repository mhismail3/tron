import Foundation
import Testing
@testable import TronMobile

@Suite("App model custom-model mutations")
struct AppModelCustomModelTests {
    private let profile = GatewayProfile(
        id: "machine",
        label: "Mac",
        host: "gateway.test",
        port: 9_847,
        machineId: "machine",
        deviceId: "device"
    )

    @Test("custom-model replacement uses the AppModel UUID source command ID")
    func suppliedCommandID() async throws {
        try await withTestWatchdog {
            let socket = ScriptedGatewaySocket()
            let client = GatewayClient(
                socketFactory: ScriptedGatewaySocketFactory(socket: socket).factory,
                uuidSource: SequenceUUIDSource([
                    UUID(uuidString: "00000000-0000-0000-0000-000000000061")!,
                    UUID(uuidString: "00000000-0000-0000-0000-000000000062")!,
                    UUID(uuidString: "00000000-0000-0000-0000-000000000063")!,
                ]).source
            )
            await socket.enqueue(helloFrame())
            _ = try await client.connect(profile: profile, token: "token")

            let document: JSONValue = .object(["providers": .object([:])])
            let replacement = Task { @MainActor in
                let model = AppModel(
                    client: client,
                    uuidSource: SequenceUUIDSource([
                        UUID(uuidString: "00000000-0000-0000-0000-000000000099")!,
                    ]).source
                )
                try await model.replaceCustomModels(document)
            }
            defer { replacement.cancel() }

            try await socket.waitUntilSent(count: 2)
            let validation = try await decodedObject(in: socket, index: 1)
            #expect(validation["method"] == .string("models.custom.validate"))
            await socket.enqueue(responseFrame(id: "00000000-0000-0000-0000-000000000062"))

            try await socket.waitUntilSent(count: 3)
            let put = try await decodedObject(in: socket, index: 2)
            #expect(put["method"] == .string("models.custom.put"))
            #expect(put["params"]?.objectValue?["document"] == document)
            #expect(put["params"]?.objectValue?["commandId"] == .string("00000000-0000-0000-0000-000000000099"))
            await socket.enqueue(responseFrame(id: "00000000-0000-0000-0000-000000000063"))

            try await valueOfOwnedTask(replacement)
            await client.close()
        }
    }

    private func decodedObject(in socket: ScriptedGatewaySocket, index: Int) async throws -> [String: JSONValue] {
        let frames = await socket.sentFrames()
        return try JSONDecoder.gateway.decode(JSONValue.self, from: frames[index]).objectValue ?? [:]
    }

    private func helloFrame() -> Data {
        Data(#"{"type":"hello","gatewayVersion":"1.0.0","piVersion":"1.0.0","protocolVersion":2,"minProtocolVersion":2,"machineId":"machine","machineName":"Mac","capabilities":["sessions.v1"]}"#.utf8)
    }

    private func responseFrame(id: String) -> Data {
        try! JSONEncoder.gateway.encode(JSONValue.object([
            "type": .string("response"),
            "id": .string(id),
            "ok": .bool(true),
            "result": .null,
        ]))
    }
}
