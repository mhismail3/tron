import Foundation

/// Holds Prompt Library UI state — history page, snippets list, tab selection,
/// optimistic mutation bookkeeping, and error surface.
///
/// Written to by `PromptLibrarySheet` and its child views; mutations are
/// optimistic with engine protocol-error rollback. All engine invocations funnel through
/// `EngineClient.promptLibrary`.
@Observable
@MainActor
final class PromptLibraryState {

    /// Library sheet tabs.
    enum Tab: Hashable { case history, snippets }

    var activeTab: Tab = .snippets

    // MARK: - History

    var historyItems: [PromptHistoryItem] = []
    var historyCursor: String?
    var historyHasMore: Bool = false
    var isLoadingHistory: Bool = false
    var isLoadingMoreHistory: Bool = false
    var historySearch: String = ""

    /// Debounced task for `historySearch` → `loadHistory(reset: true)`.
    @ObservationIgnored private var historyReloadTask: Task<Void, Never>?

    // MARK: - Snippets

    var snippets: [PromptSnippet] = []
    var isLoadingSnippets: Bool = false
    var isMutatingSnippet: Set<String> = []

    // MARK: - UI surface

    var errorMessage: String?

    init() {}

    // MARK: - History

    /// Load the first page of history, replacing any prior items when `reset == true`.
    func loadHistory(rpc: EngineClient, reset: Bool) async {
        if reset {
            isLoadingHistory = true
        } else if historyCursor == nil {
            return
        } else {
            isLoadingMoreHistory = true
        }
        defer {
            isLoadingHistory = false
            isLoadingMoreHistory = false
        }

        let cursor = reset ? nil : historyCursor
        let query = historySearch.isEmpty ? nil : historySearch

        do {
            let page = try await rpc.promptLibrary.listHistory(
                limit: 50,
                cursor: cursor,
                query: query
            )
            if reset {
                historyItems = page.items
            } else {
                // Append, dropping any accidental duplicates by id.
                let existingIds = Set(historyItems.map(\.id))
                historyItems.append(contentsOf: page.items.filter { !existingIds.contains($0.id) })
            }
            historyCursor = page.nextCursor
            historyHasMore = page.nextCursor != nil
        } catch {
            errorMessage = "Failed to load history: \(error.localizedDescription)"
        }
    }

    /// Append the next page (no-op if no cursor).
    func loadMoreHistory(rpc: EngineClient) async {
        guard historyCursor != nil, !isLoadingMoreHistory else { return }
        await loadHistory(rpc: rpc, reset: false)
    }

    /// Update the search string and schedule a debounced reload.
    func setSearch(_ text: String, rpc: EngineClient) {
        historySearch = text
        historyReloadTask?.cancel()
        historyReloadTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled, let self else { return }
            await self.loadHistory(rpc: rpc, reset: true)
        }
    }

    /// Optimistically remove a history item; restore on failure.
    func deleteHistory(id: String, rpc: EngineClient) async {
        guard let idx = historyItems.firstIndex(where: { $0.id == id }) else { return }
        let removed = historyItems.remove(at: idx)
        do {
            _ = try await rpc.promptLibrary.deleteHistory(
                id: id,
                idempotencyKey: .userAction("promptLibrary.historyDelete")
            )
        } catch {
            historyItems.insert(removed, at: idx)
            errorMessage = "Failed to delete: \(error.localizedDescription)"
        }
    }

    /// Clear every history row server-side, then locally.
    func clearHistory(rpc: EngineClient) async {
        do {
            _ = try await rpc.promptLibrary.clearHistory(
                idempotencyKey: .userAction("promptLibrary.historyClear")
            )
            historyItems = []
            historyCursor = nil
            historyHasMore = false
        } catch {
            errorMessage = "Failed to clear history: \(error.localizedDescription)"
        }
    }

    // MARK: - Snippets

    func loadSnippets(rpc: EngineClient) async {
        isLoadingSnippets = true
        defer { isLoadingSnippets = false }
        do {
            let result = try await rpc.promptLibrary.listSnippets()
            snippets = result.items
        } catch {
            errorMessage = "Failed to load snippets: \(error.localizedDescription)"
        }
    }

    /// Create a snippet and insert at the top. Returns the created snippet.
    @discardableResult
    func createSnippet(name: String, text: String, rpc: EngineClient) async -> PromptSnippet? {
        do {
            let result = try await rpc.promptLibrary.createSnippet(
                name: name,
                text: text,
                idempotencyKey: .userAction("promptLibrary.snippetCreate")
            )
            snippets.insert(result.snippet, at: 0)
            return result.snippet
        } catch {
            errorMessage = "Failed to create snippet: \(error.localizedDescription)"
            return nil
        }
    }

    /// Update a snippet (partial). Moves it to the top of the list on success.
    @discardableResult
    func updateSnippet(id: String, name: String?, text: String?, rpc: EngineClient) async -> Bool {
        isMutatingSnippet.insert(id)
        defer { isMutatingSnippet.remove(id) }
        do {
            let result = try await rpc.promptLibrary.updateSnippet(
                id: id,
                name: name,
                text: text,
                idempotencyKey: .userAction("promptLibrary.snippetUpdate")
            )
            snippets.removeAll { $0.id == id }
            snippets.insert(result.snippet, at: 0)
            return true
        } catch {
            errorMessage = "Failed to update snippet: \(error.localizedDescription)"
            return false
        }
    }

    /// Optimistically delete a snippet; restore on failure.
    func deleteSnippet(id: String, rpc: EngineClient) async {
        guard let idx = snippets.firstIndex(where: { $0.id == id }) else { return }
        let removed = snippets.remove(at: idx)
        isMutatingSnippet.insert(id)
        defer { isMutatingSnippet.remove(id) }
        do {
            _ = try await rpc.promptLibrary.deleteSnippet(
                id: id,
                idempotencyKey: .userAction("promptLibrary.snippetDelete")
            )
        } catch {
            snippets.insert(removed, at: idx)
            errorMessage = "Failed to delete snippet: \(error.localizedDescription)"
        }
    }
}
