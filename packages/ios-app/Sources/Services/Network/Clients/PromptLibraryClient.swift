import Foundation

/// Client for Prompt Library RPC methods.
///
/// Handles two server-persisted datasets:
/// - History (auto-captured prompts, deduped by normalized text)
/// - Snippets (user-authored named quick prompts, full CRUD)
final class PromptLibraryClient: RPCDomainClient {

    // MARK: - History

    /// Paginated history list (newest first). Optional substring search.
    func listHistory(limit: Int? = nil, cursor: String? = nil, query: String? = nil) async throws -> PromptHistoryListResult {
        let ws = try requireTransport().requireConnection()
        let params = PromptHistoryListParams(limit: limit, cursor: cursor, query: query)
        return try await ws.send(method: "promptHistory.list", params: params)
    }

    /// Delete a single history entry. Idempotent.
    @discardableResult
    func deleteHistory(id: String) async throws -> PromptHistoryDeleteResult {
        let ws = try requireTransport().requireConnection()
        let params = PromptHistoryDeleteParams(id: id)
        return try await ws.send(method: "promptHistory.delete", params: params)
    }

    /// Clear every history row.
    @discardableResult
    func clearHistory() async throws -> PromptHistoryClearResult {
        let ws = try requireTransport().requireConnection()
        let empty: [String: String] = [:]
        return try await ws.send(method: "promptHistory.clear", params: empty)
    }

    // MARK: - Snippets

    /// List all snippets, sorted by `updated_at DESC`.
    func listSnippets() async throws -> PromptSnippetListResult {
        let ws = try requireTransport().requireConnection()
        let empty: [String: String] = [:]
        return try await ws.send(method: "promptSnippet.list", params: empty)
    }

    /// Fetch a single snippet by id.
    func getSnippet(id: String) async throws -> PromptSnippetGetResult {
        let ws = try requireTransport().requireConnection()
        let params = PromptSnippetGetParams(id: id)
        return try await ws.send(method: "promptSnippet.get", params: params)
    }

    /// Create a new snippet.
    func createSnippet(name: String, text: String) async throws -> PromptSnippetCreateResult {
        let ws = try requireTransport().requireConnection()
        let params = PromptSnippetCreateParams(name: name, text: text)
        return try await ws.send(method: "promptSnippet.create", params: params)
    }

    /// Partial-update an existing snippet. Requires at least one of `name`/`text`.
    func updateSnippet(id: String, name: String? = nil, text: String? = nil) async throws -> PromptSnippetUpdateResult {
        let ws = try requireTransport().requireConnection()
        let params = PromptSnippetUpdateParams(id: id, name: name, text: text)
        return try await ws.send(method: "promptSnippet.update", params: params)
    }

    /// Delete a snippet by id. Idempotent.
    @discardableResult
    func deleteSnippet(id: String) async throws -> PromptSnippetDeleteResult {
        let ws = try requireTransport().requireConnection()
        let params = PromptSnippetDeleteParams(id: id)
        return try await ws.send(method: "promptSnippet.delete", params: params)
    }
}
