import Testing
import Foundation
@testable import TronMobile

@MainActor
@Suite("BlobClient Tests")
struct BlobClientTests {

    @Test("getBlob throws when webSocket is nil")
    func getBlobNoConnection() async {
        let transport = MockRPCTransport()
        transport.webSocket = nil
        let client = BlobClient(transport: transport)
        await #expect(throws: RPCClientError.self) { _ = try await client.getBlob(blobId: "blob-1") }
    }

    @Test("getImageData throws when webSocket is nil")
    func getImageDataNoConnection() async {
        let transport = MockRPCTransport()
        transport.webSocket = nil
        let client = BlobClient(transport: transport)
        await #expect(throws: RPCClientError.self) { _ = try await client.getImageData(blobId: "blob-1") }
    }
}
