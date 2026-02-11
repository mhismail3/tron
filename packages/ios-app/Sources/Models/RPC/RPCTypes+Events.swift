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

// MARK: - Memory Ledger Methods

struct MemoryGetLedgerParams: Encodable {
    let workingDirectory: String
    let limit: Int?
    let offset: Int?
    let tags: [String]?

    init(workingDirectory: String, limit: Int? = nil, offset: Int? = nil, tags: [String]? = nil) {
        self.workingDirectory = workingDirectory
        self.limit = limit
        self.offset = offset
        self.tags = tags
    }
}

struct LedgerFileEntry: Codable {
    let path: String
    let op: String
    let why: String
}

struct LedgerDecision: Codable {
    let choice: String
    let reason: String
}

struct LedgerTokenCost: Codable {
    let input: Int?
    let output: Int?
}

struct LedgerEntryDTO: Codable, Identifiable {
    let id: String
    let sessionId: String
    let timestamp: String
    let title: String?
    let entryType: String?
    let input: String?
    let actions: [String]
    let decisions: [LedgerDecision]
    let lessons: [String]
    let insights: [String]
    let tags: [String]
    let files: [LedgerFileEntry]
    let model: String?
    let tokenCost: LedgerTokenCost?
}

struct MemoryGetLedgerResult: Decodable {
    let entries: [LedgerEntryDTO]
    let hasMore: Bool
    let totalCount: Int
}

// MARK: - Memory Update Ledger

struct MemoryUpdateLedgerParams: Encodable {
    let sessionId: String
}

struct MemoryUpdateLedgerResult: Decodable {
    let written: Bool
    let title: String?
    let entryType: String?
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
    let tailscaleIp: String?
}

struct ContainerActionParams: Encodable {
    let name: String
}

struct ContainerActionResult: Decodable {
    let success: Bool
}
