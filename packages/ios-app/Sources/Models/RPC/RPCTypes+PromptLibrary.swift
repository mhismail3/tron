import Foundation

// MARK: - Prompt History

/// A single prompt-history entry as returned by the server.
struct PromptHistoryItem: Decodable, Identifiable, Equatable, Hashable {
    let id: String
    let text: String
    let firstUsedAt: String
    let lastUsedAt: String
    let useCount: Int
    let charCount: Int
}

/// Params for `promptHistory.list`.
struct PromptHistoryListParams: Encodable {
    let limit: Int?
    let cursor: String?
    let query: String?
}

struct PromptHistoryListResult: Decodable {
    let items: [PromptHistoryItem]
    let nextCursor: String?
}

struct PromptHistoryDeleteParams: Encodable {
    let id: String
}

struct PromptHistoryDeleteResult: Decodable {
    let deleted: Bool
}

struct PromptHistoryClearResult: Decodable {
    let deletedCount: Int
}

// MARK: - Prompt Snippets

/// A user-authored snippet.
struct PromptSnippet: Decodable, Identifiable, Equatable, Hashable {
    let id: String
    let name: String
    let text: String
    let createdAt: String
    let updatedAt: String
}

struct PromptSnippetListResult: Decodable {
    let items: [PromptSnippet]
}

struct PromptSnippetGetParams: Encodable {
    let id: String
}

struct PromptSnippetGetResult: Decodable {
    let snippet: PromptSnippet
}

struct PromptSnippetCreateParams: Encodable {
    let name: String
    let text: String
}

struct PromptSnippetCreateResult: Decodable {
    let snippet: PromptSnippet
}

struct PromptSnippetUpdateParams: Encodable {
    let id: String
    let name: String?
    let text: String?
}

struct PromptSnippetUpdateResult: Decodable {
    let snippet: PromptSnippet
}

struct PromptSnippetDeleteParams: Encodable {
    let id: String
}

struct PromptSnippetDeleteResult: Decodable {
    let deleted: Bool
}
