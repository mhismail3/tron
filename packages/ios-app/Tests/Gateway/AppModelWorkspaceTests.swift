import Foundation
import Testing
@testable import TronMobile

@MainActor
@Suite("AppModel workspace request admission")
struct AppModelWorkspaceTests {
    @Test("late folder creation cannot refresh over newer navigation")
    func folderRefreshRespectsNewerNavigation() async throws {
        let socket = ScriptedGatewaySocket()
        let client = GatewayClient(socketFactory: ScriptedGatewaySocketFactory(socket: socket).factory)
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let model = AppModel(client: client, cache: SnapshotCache(root: root))
        let profile = GatewayProfile(
            id: "profile", label: "Mac", host: "gateway.test", port: 9_847,
            machineId: "machine", deviceId: "device"
        )
        await socket.enqueue(helloFrame())
        try await model.connectHostedGateway(profile: profile, token: "token")
        defer { try? FileManager.default.removeItem(at: root) }

        let creating = Task { try await model.createFolder(parent: "/parent", name: "new") }
        let mkdir = try await request(socket, index: 1)
        #expect(mkdir.method == "filesystem.mkdir")

        let navigating = Task { try await model.loadWorkspace(path: "/newer") }
        let list = try await request(socket, index: 2)
        #expect(list.method == "filesystem.list")
        await socket.enqueue(successResponse(
            id: list.id,
            result: .object([
                "path": .string("/newer"),
                "parent": .string("/"),
                "entries": .array([]),
            ])
        ))
        try await navigating.value
        #expect(model.workspace?.path == "/newer")

        await socket.enqueue(successResponse(
            id: mkdir.id,
            result: .object(["path": .string("/parent/new")])
        ))
        try await creating.value
        #expect(model.workspace?.path == "/newer")
        #expect(await socket.sentFrames().count == 3)

        await model.teardown()
        await client.close()
    }

    private func request(_ socket: ScriptedGatewaySocket, index: Int) async throws -> Request {
        try await socket.waitUntilSent(count: index + 1)
        return try JSONDecoder.gateway.decode(Request.self, from: await socket.sentFrames()[index])
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
        Data(#"{"type":"hello","gatewayVersion":"1.0.0","piVersion":"1.0.0","protocolVersion":4,"minProtocolVersion":4,"machineId":"machine","machineName":"Mac","gatewayChannel":"stable","capabilities":["sessions.v1"]}"#.utf8)
    }

    private struct Request: Decodable {
        let id: String
        let method: String
    }
}
