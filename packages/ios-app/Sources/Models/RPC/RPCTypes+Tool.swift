import Foundation

// MARK: - Message Methods

struct MessageDeleteParams: Encodable {
    let sessionId: String
    let targetEventId: String
    let reason: String?

    init(sessionId: String, targetEventId: String, reason: String? = "user_request") {
        self.sessionId = sessionId
        self.targetEventId = targetEventId
        self.reason = reason
    }
}

struct MessageDeleteResult: Decodable {
    let success: Bool
    let deletionEventId: String
    let targetType: String
}

// MARK: - Tool Result Methods

/// Send tool result for interactive tools like AskUserQuestion
struct ToolResultParams: Encodable {
    let sessionId: String
    let toolCallId: String
    let result: AskUserQuestionResult
}

struct ToolResultResponse: Decodable {
    let success: Bool
}

// MARK: - Skill Methods

struct SkillListParams: Encodable {
    let sessionId: String?
    let source: String?
    let autoInjectOnly: Bool?
    let includeContent: Bool?

    init(sessionId: String? = nil, source: String? = nil, autoInjectOnly: Bool? = nil, includeContent: Bool? = nil) {
        self.sessionId = sessionId
        self.source = source
        self.autoInjectOnly = autoInjectOnly
        self.includeContent = includeContent
    }
}

struct SkillGetParams: Encodable {
    let sessionId: String?
    let name: String

    init(sessionId: String? = nil, name: String) {
        self.sessionId = sessionId
        self.name = name
    }
}

struct SkillRefreshParams: Encodable {
    let sessionId: String?

    init(sessionId: String? = nil) {
        self.sessionId = sessionId
    }
}

struct SkillRemoveParams: Encodable {
    let sessionId: String
    let skillName: String
}

// MARK: - Canvas Methods

struct CanvasGetParams: Encodable {
    let canvasId: String
}

struct CanvasArtifactData: Decodable {
    let canvasId: String
    let sessionId: String
    let title: String?
    let ui: [String: AnyCodable]
    let state: [String: AnyCodable]?
    let savedAt: String
}

struct CanvasGetResult: Decodable {
    let found: Bool
    let canvas: CanvasArtifactData?
}
