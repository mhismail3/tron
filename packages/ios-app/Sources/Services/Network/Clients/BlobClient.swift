import Foundation

/// Client for fetching blob content from the server.
/// Used by the Display capability to load images stored in blob storage.
final class BlobClient: EngineDomainClient {

    /// Fetch blob content by ID. Returns base64-encoded data and MIME type.
    func getBlob(blobId: String) async throws -> BlobGetResult {
        _ = try requireTransport().requireConnection()

        struct BlobGetParams: Codable {
            let blobId: String
        }

        let params = BlobGetParams(blobId: blobId)
        return try await invokeRead("blob::get", params)
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
