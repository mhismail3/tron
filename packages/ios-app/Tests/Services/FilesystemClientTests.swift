import Testing
import Foundation
@testable import TronMobile

@MainActor
@Suite("FilesystemClient Tests")
struct FilesystemClientTests {

    @Test("listDirectory throws when engineConnection is nil")
    func listDirectoryNoConnection() async {
        let transport = MockEngineTransport()
        transport.engineConnection = nil
        let client = FilesystemClient(transport: transport)

        await #expect(throws: EngineClientError.self) {
            _ = try await client.listDirectory(path: "/tmp")
        }
    }
}
