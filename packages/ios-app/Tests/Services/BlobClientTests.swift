import Testing
import Foundation
@testable import TronMobile

@MainActor
@Suite("BlobClient Tests")
struct BlobClientTests {

    @Test("getBlob throws when engineConnection is nil")
    func getBlobNoConnection() async {
        let transport = MockEngineTransport()
        transport.engineConnection = nil
        let client = BlobClient(transport: transport)
        await #expect(throws: EngineClientError.self) { _ = try await client.getBlob(blobId: "blob-1") }
    }

    @Test("getImageData throws when engineConnection is nil")
    func getImageDataNoConnection() async {
        let transport = MockEngineTransport()
        transport.engineConnection = nil
        let client = BlobClient(transport: transport)
        await #expect(throws: EngineClientError.self) { _ = try await client.getImageData(blobId: "blob-1") }
    }
}
