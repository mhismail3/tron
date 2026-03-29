import Foundation

/// Client for fetching blob content from the server.
/// Used by the Display tool to load images stored in blob storage.
@MainActor
final class BlobClient {
    private unowned let transport: RPCTransport

    init(transport: RPCTransport) {
        self.transport = transport
    }

    /// Fetch blob content by ID. Returns base64-encoded data and MIME type.
    func getBlob(blobId: String) async throws -> BlobGetResult {
        let ws = try transport.requireConnection()

        struct BlobGetParams: Codable {
            let blobId: String
        }

        let params = BlobGetParams(blobId: blobId)
        return try await ws.send(method: "blob.get", params: params)
    }

    /// Fetch blob content and decode as image data.
    func getImageData(blobId: String) async throws -> Data? {
        let result = try await getBlob(blobId: blobId)
        return Data(base64Encoded: result.data)
    }
}

// MARK: - Response Types

struct BlobGetResult: Codable {
    let blobId: String
    let mimeType: String
    let data: String      // base64-encoded content
    let sizeBytes: Int
}
