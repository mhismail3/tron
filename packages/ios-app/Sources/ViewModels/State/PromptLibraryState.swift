import Foundation

/// Holds Prompt Library picker state — history page, snippets list, tab
/// selection, search, pagination, and error surface.
///
/// The fixed Prompt Library sheet is only a local composer insertion affordance.
/// Prompt management mutations are rendered from server-authored generated UI
/// surfaces and submitted through `ui::submit_action`.
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
}
