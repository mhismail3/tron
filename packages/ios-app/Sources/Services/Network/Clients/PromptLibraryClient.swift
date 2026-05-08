import Foundation

/// Client for Prompt Library engine capabilities.
///
/// Handles two server-persisted datasets:
/// - History (auto-captured prompts, deduped by normalized text)
/// - Snippets (user-authored named quick prompts, full CRUD)
final class PromptLibraryClient: EngineDomainClient {

    // MARK: - History

    /// Paginated history list (newest first). Optional substring search.
    func listHistory(limit: Int? = nil, cursor: String? = nil, query: String? = nil) async throws -> PromptHistoryListResult {
        _ = try requireTransport().requireConnection()
        let params = PromptHistoryListParams(limit: limit, cursor: cursor, query: query)
        return try await invokeRead("prompt_library::history_list", params)
    }

    /// Delete a single history entry. Idempotent.
    @discardableResult
    func deleteHistory(id: String, idempotencyKey: EngineIdempotencyKey) async throws -> PromptHistoryDeleteResult {
        _ = try requireTransport().requireConnection()
        let params = PromptHistoryDeleteParams(id: id)
        return try await invokeWrite("prompt_library::history_delete", params, idempotencyKey: idempotencyKey)
    }

    /// Clear every history row.
    @discardableResult
    func clearHistory(idempotencyKey: EngineIdempotencyKey) async throws -> PromptHistoryClearResult {
        _ = try requireTransport().requireConnection()
        let empty: [String: String] = [:]
        return try await invokeWrite("prompt_library::history_clear", empty, idempotencyKey: idempotencyKey)
    }

    // MARK: - Snippets

    /// List all snippets, sorted by `updated_at DESC`.
    func listSnippets() async throws -> PromptSnippetListResult {
        _ = try requireTransport().requireConnection()
        let empty: [String: String] = [:]
        return try await invokeRead("prompt_library::snippet_list", empty)
    }

    /// Fetch a single snippet by id.
    func getSnippet(id: String) async throws -> PromptSnippetGetResult {
        _ = try requireTransport().requireConnection()
        let params = PromptSnippetGetParams(id: id)
        return try await invokeRead("prompt_library::snippet_get", params)
    }

    /// Create a new snippet.
    func createSnippet(
        name: String,
        text: String,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> PromptSnippetCreateResult {
        _ = try requireTransport().requireConnection()
        let params = PromptSnippetCreateParams(name: name, text: text)
        return try await invokeWrite("prompt_library::snippet_create", params, idempotencyKey: idempotencyKey)
    }

    /// Partial-update an existing snippet. Requires at least one of `name`/`text`.
    func updateSnippet(
        id: String,
        name: String? = nil,
        text: String? = nil,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> PromptSnippetUpdateResult {
        _ = try requireTransport().requireConnection()
        let params = PromptSnippetUpdateParams(id: id, name: name, text: text)
        return try await invokeWrite("prompt_library::snippet_update", params, idempotencyKey: idempotencyKey)
    }

    /// Delete a snippet by id. Idempotent.
    @discardableResult
    func deleteSnippet(id: String, idempotencyKey: EngineIdempotencyKey) async throws -> PromptSnippetDeleteResult {
        _ = try requireTransport().requireConnection()
        let params = PromptSnippetDeleteParams(id: id)
        return try await invokeWrite("prompt_library::snippet_delete", params, idempotencyKey: idempotencyKey)
    }
}
