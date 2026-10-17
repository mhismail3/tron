import Foundation
import Observation

/// One disposable cursor window. Only a successful explicit navigation replaces
/// the native viewport; refresh, failure and returning from a child retain it.
@MainActor @Observable
final class PagedListStore<Page, Cursor: Equatable, Identity: Equatable> {
    private(set) var page: Page?
    private(set) var pageCursor: Cursor?
    private(set) var loading = false
    private(set) var error: String?
    private(set) var identity: Identity?
    private(set) var viewportGeneration = 0
    private var generation = 0
    private var requestedCursor: Cursor?

    func suspend() { generation &+= 1; loading = false }

    func load(identity: Identity, cursor: Cursor?, resetViewport: Bool = false,
              isCurrent: @MainActor () -> Bool, fetch: () async throws -> Page) async -> Bool {
        guard !Task.isCancelled, isCurrent() else { return false }
        guard !loading || self.identity != identity || requestedCursor != cursor else { return false }
        requestedCursor = cursor
        generation &+= 1
        let ticket = generation
        if self.identity != identity { page = nil; pageCursor = nil }
        self.identity = identity
        loading = true; error = nil
        do {
            let loaded = try await fetch()
            guard !Task.isCancelled, ticket == generation, isCurrent() else { return false }
            page = loaded
            pageCursor = cursor
            if resetViewport { viewportGeneration &+= 1 }
            loading = false
            return true
        } catch {
            guard !Task.isCancelled, ticket == generation, isCurrent() else { return false }
            self.error = error.localizedDescription; loading = false
            return false
        }
    }
}

struct PagedListRequest<Cursor> {
    var revision = 0
    var cursor: Cursor?
    var resetsViewport = false

    mutating func advance(cursor: Cursor?, resetsViewport: Bool) {
        revision &+= 1
        self.cursor = cursor
        self.resetsViewport = resetsViewport
    }
}
