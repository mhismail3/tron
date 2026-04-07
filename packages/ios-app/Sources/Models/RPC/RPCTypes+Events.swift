import Foundation

// MARK: - Event Sync Methods

/// Get event history for a session
struct EventsGetHistoryParams: Encodable {
    let sessionId: String
    let types: [String]?
    let limit: Int?
    let beforeEventId: String?

    init(sessionId: String, types: [String]? = nil, limit: Int? = nil, beforeEventId: String? = nil) {
        self.sessionId = sessionId
        self.types = types
        self.limit = limit
        self.beforeEventId = beforeEventId
    }
}

/// Raw event from server (matches core/events/types.ts)
struct RawEvent: Decodable, EventTransformable {
    let id: String
    let parentId: String?
    let sessionId: String
    let workspaceId: String
    let type: String
    let timestamp: String
    let sequence: Int
    let payload: [String: AnyCodable]
    /// Wire-level toolCallId from DB column (tool.call / tool.result events).
    /// Also present inside `payload`, but captured here for robustness.
    let toolCallId: String?
    let toolName: String?
}

struct EventsGetHistoryResult: Decodable {
    let events: [RawEvent]
    let hasMore: Bool
    let oldestEventId: String?
}

/// Get events since a cursor (for sync)
struct EventsGetSinceParams: Encodable {
    let sessionId: String?
    let workspaceId: String?
    let afterEventId: String?
    let afterTimestamp: String?
    let limit: Int?

    init(sessionId: String? = nil, workspaceId: String? = nil, afterEventId: String? = nil, afterTimestamp: String? = nil, limit: Int? = nil) {
        self.sessionId = sessionId
        self.workspaceId = workspaceId
        self.afterEventId = afterEventId
        self.afterTimestamp = afterTimestamp
        self.limit = limit
    }
}

struct EventsGetSinceResult: Decodable {
    let events: [RawEvent]
    let nextCursor: String?
    let hasMore: Bool
}

// MARK: - Tree Methods

struct TreeGetAncestorsParams: Encodable {
    let eventId: String
}

struct TreeGetAncestorsResult: Decodable {
    let events: [RawEvent]
}

struct MemoryRetainParams: Encodable {
    let sessionId: String
}

struct MemoryRetainResult: Decodable {
    let retained: Bool
    let reason: String?
    let title: String?
    let eventId: String?
}

// MARK: - Sandbox Types

struct ContainerDTO: Decodable, Identifiable {
    var id: String { name }
    let name: String
    let image: String
    let status: String
    let ports: [String]
    let purpose: String?
    let createdAt: String
    let createdBySession: String
    let workingDirectory: String
}

struct SandboxListResult: Decodable {
    let containers: [ContainerDTO]
    let hostIp: String?
}

struct ContainerActionParams: Encodable {
    let name: String
}

struct ContainerActionResult: Decodable {
    let success: Bool
}
