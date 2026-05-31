import Foundation

// MARK: - List Sources

struct ImportListSourcesResult: Decodable {
    let sources: [ImportSource]
}

struct ImportSource: Decodable, Identifiable, Hashable {
    let projectPath: String
    let projectName: String
    let encodedDir: String
    let sessionCount: Int

    var id: String { encodedDir }
}

// MARK: - List Sessions

struct ImportListSessionsParams: Encodable {
    let encodedDir: String
}

struct ImportListSessionsResult: Decodable {
    let sessions: [ImportableSession]
}

struct ImportableSession: Decodable, Identifiable, Hashable {
    let sessionPath: String
    let title: String?
    let slug: String?
    let createdAt: String?
    let lastActivityAt: String?
    let messageCount: Int
    let model: String?
    let inputTokens: Int?
    let outputTokens: Int?
    let alreadyImported: Bool
    let existingTronSessionId: String?

    var id: String { sessionPath }

    var displayTitle: String {
        title ?? slug ?? "Untitled"
    }
}

// MARK: - Preview Session

struct ImportPreviewParams: Encodable {
    let sessionPath: String
}

struct ImportSessionPreview: Decodable {
    let messages: [ImportPreviewMessage]
    let totalMessages: Int
    let stats: ImportSessionStats
}

struct ImportPreviewMessage: Decodable, Identifiable {
    let id: String
    let role: String
    let contentPreview: String
    let hasCapabilityInvocation: Bool?
    let modelPrimitiveName: String?
}

struct ImportSessionStats: Decodable {
    let inputTokens: Int?
    let outputTokens: Int?
    let totalCost: Double?
    let model: String?
    let hasCompaction: Bool
}

// MARK: - Execute Import

struct ImportExecuteParams: Encodable {
    let sessionPath: String
    let workingDirectory: String?
    let tags: [String]?
}

struct ImportExecuteResult: Decodable {
    let sessionId: String?
    let workingDirectory: String?
    let model: String?
    let eventCount: Int?
    let turnCount: Int?
    let messageCount: Int?
    let cost: Double?
    let alreadyImported: Bool
    let existingSessionId: String?
}
