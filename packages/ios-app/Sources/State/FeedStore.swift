import Foundation
import Observation

@MainActor @Observable
final class FeedStore<Page, Cursor: Equatable & Sendable, Identity: PresentationReadIdentity> {
    struct Installed {
        let cursor: Cursor?
        let page: Page
    }

    enum Request: Equatable {
        case reset
        case append(Cursor)
        case refresh(Int)
    }

    private(set) var pages: [Installed] = []
    private(set) var loading = false
    private(set) var error: String?
    private(set) var failed: Request?
    private(set) var identity: Identity?
    private var generation = 0
    private var inFlight: Request?

    var hasPage: Bool { !pages.isEmpty }

    func request(for identity: Identity) -> Request? {
        guard let installed = self.identity, hasPage else { return .reset }
        if installed == identity { return nil }
        return identity.retainsContent(from: installed) ? .refresh(0) : .reset
    }

    func suspend() { generation &+= 1; loading = false; inFlight = nil }

    @discardableResult
    func load(_ request: Request, identity: Identity, isCurrent: @MainActor () -> Bool,
              fetch: (sending Cursor?) async throws -> Page) async -> Bool {
        guard !Task.isCancelled, isCurrent() else { return false }
        if loading, self.identity == identity, request != .reset { return false }
        if loading, inFlight == request, self.identity == identity { return false }
        let cursor: Cursor?
        switch request {
        case .reset: cursor = nil
        case .append(let next): cursor = next
        case .refresh(let index):
            guard pages.indices.contains(index) else { return false }
            cursor = pages[index].cursor
        }
        generation &+= 1
        let ticket = generation
        if self.identity.map({ !identity.retainsContent(from: $0) }) ?? true { pages = [] }
        self.identity = identity
        loading = true; error = nil; failed = nil; inFlight = request
        do {
            let page = try await fetch(cursor)
            guard !Task.isCancelled, ticket == generation, isCurrent() else { return false }
            switch request {
            case .reset: pages = [Installed(cursor: nil, page: page)]
            case .append: pages.append(Installed(cursor: cursor, page: page))
            case .refresh(let index):
                guard pages.indices.contains(index), pages[index].cursor == cursor else { break }
                pages[index] = Installed(cursor: cursor, page: page)
            }
            loading = false; inFlight = nil
            return true
        } catch {
            guard !Task.isCancelled, ticket == generation, isCurrent() else { return false }
            self.error = error.localizedDescription; failed = request
            loading = false; inFlight = nil
            return false
        }
    }
}
