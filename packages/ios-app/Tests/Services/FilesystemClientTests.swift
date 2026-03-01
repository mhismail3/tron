import Testing
import Foundation
@testable import TronMobile

@MainActor
@Suite("FilesystemClient Tests")
struct FilesystemClientTests {

    @Test("listDirectory throws when webSocket is nil")
    func listDirectoryNoConnection() async {
        let transport = MockRPCTransport()
        transport.webSocket = nil
        let client = FilesystemClient(transport: transport)

        await #expect(throws: RPCClientError.self) {
            _ = try await client.listDirectory(path: "/tmp")
        }
    }
}
