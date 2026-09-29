import Foundation
import Observation
import TronMobileCore

// The knowledge surface's bounded presentation stores. The wire projections
// they present stay in Models; only the stores that own a read generation,
// cursor or byte buffer live here.

/// Owns the bounded coverage projection and its cursor. Pages are requested by
/// disposition, so the projection holds cuts that need attention rather than the
/// settled majority of the ledger. A continuation appends to that projection
/// across a revision change (deduplicating re-recorded cuts) so paging always
/// advances instead of restarting at the head.
@MainActor @Observable
final class KnowledgeCoveragePresentationStore {
    private(set) var cuts: [KnowledgeObservationCoverage] = []
    private(set) var nextCursor: String?
    private(set) var stateRevision: Int?
    private(set) var loading = false
    private(set) var error: String?
    private var generation = 0
    private var identity: KnowledgePresentationIdentity?
    private var requestedCursor: String?
    var showsInitialLoading: Bool { loading && stateRevision == nil }

    func suspend() { generation &+= 1; loading = false }
    func reset() { generation &+= 1; cuts = []; nextCursor = nil; stateRevision = nil; error = nil; loading = false; identity = nil; requestedCursor = nil }

    func load(
        identity: KnowledgePresentationIdentity,
        cursor: String? = nil,
        expectedStateRevision: Int? = nil,
        request: @Sendable (String?) async throws -> KnowledgeCoveragePage,
        isCurrent: @MainActor () -> Bool
    ) async {
        guard !Task.isCancelled, isCurrent() else { return }
        guard !loading || self.identity != identity || requestedCursor != cursor else { return }
        if self.identity != identity { reset() }
        if cursor == nil, let expectedStateRevision, stateRevision == expectedStateRevision, error == nil { return }
        self.identity = identity; requestedCursor = cursor; generation &+= 1
        let ticket = generation
        // A same-Gateway refresh replaces the page only after it arrives. A
        // covered/uncovered sheet must not flash an empty coverage container.
        loading = true; error = nil
        do {
            let page = try await request(cursor)
            guard !Task.isCancelled, ticket == generation, isCurrent() else { return }
            if cursor == nil {
                cuts = page.coverage
            } else {
                // The coverage ledger is ordered by recordedAt and only ever
                // appends a cut or moves one forward (new and re-recorded cuts
                // are stamped with the current time), so a continuation stays
                // coherent across a revision change. A cut that was re-recorded
                // after this page started replaces its retained copy rather than
                // appearing twice; a page of already-known cuts still advances
                // the cursor instead of restarting at the head.
                let refreshed = Set(page.coverage.map(\.id))
                cuts = cuts.filter { !refreshed.contains($0.id) } + page.coverage
            }
            nextCursor = page.nextCursor; stateRevision = page.stateRevision; loading = false
        } catch is CancellationError {
            if ticket == generation { loading = false }
        }
        catch {
            guard !Task.isCancelled, ticket == generation, isCurrent() else { return }
            self.error = error.localizedDescription; loading = false
        }
    }

    func loadMore(
        identity: KnowledgePresentationIdentity,
        request: @Sendable (String?) async throws -> KnowledgeCoveragePage,
        isCurrent: @MainActor () -> Bool
    ) async {
        guard let cursor = nextCursor else { return }
        await load(identity: identity, cursor: cursor, request: request, isCurrent: isCurrent)
    }
}
/// Owns linked-record reads for the active detail. A late response cannot
/// navigate after a newer citation, dismissal, or Gateway profile change.
@MainActor @Observable
final class KnowledgeLinkedRecordReaderStore {
    private(set) var record: KnowledgeRecord?
    private(set) var loading = false
    private(set) var error: String?
    private var generation = 0

    func suspend() { generation &+= 1; loading = false }
    func clear() { record = nil }
    func load(id: String, revisionID: String?, request: @Sendable (String, String?) async throws -> KnowledgeRecord?, isCurrent: @MainActor () -> Bool) async {
        guard !Task.isCancelled, isCurrent() else { return }
        generation &+= 1; let ticket = generation; let ownerGeneration = generation
        record = nil; error = nil; loading = true
        do {
            let value = try await request(id, revisionID)
            guard !Task.isCancelled, ticket == generation, generation == ownerGeneration, isCurrent() else { return }
            loading = false
            if let value { record = value } else { error = "Linked record is unavailable, excluded, or forgotten. Retry from this detail." }
        } catch is CancellationError {
            if ticket == generation, generation == ownerGeneration { loading = false }
        }
        catch {
            guard !Task.isCancelled, ticket == generation, generation == ownerGeneration, isCurrent() else { return }
            loading = false; self.error = error.localizedDescription
        }
    }
}

/// Coalesces keystrokes into one settled query. A cancelled schedule never
/// publishes its value, so a superseded query cannot replace a newer one.
@MainActor
final class KnowledgeSearchDebouncer {
    private var task: Task<Void, Never>?
    private let delay: Duration

    init(delay: Duration = KnowledgeSearchPolicy.debounce) { self.delay = delay }

    func schedule(_ value: String, apply: @escaping @MainActor (String) -> Void) {
        task?.cancel()
        task = Task { @MainActor in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            apply(KnowledgeSearchPolicy.effectiveQuery(value))
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}
