import Foundation

/// Raw persisted event returned by `session::reconstruct`.
struct RawEvent: Decodable, EventTransformable {
    let id: String
    let parentId: String?
    let sessionId: String
    let workspaceId: String
    let type: String
    let timestamp: String
    let sequence: Int
    let payload: [String: AnyCodable]
}
