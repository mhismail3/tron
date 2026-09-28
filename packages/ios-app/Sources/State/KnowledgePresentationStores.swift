import Foundation
import Observation

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
/// One bounded reader state for the currently selected exact record revision
/// and representation. Continuation offsets are never shared across objects,
/// and changing selection releases the prior representation.
@MainActor @Observable
final class KnowledgeObjectReaderStore {
    // A detail can switch representations, but it only owns one bounded byte
    // buffer at a time. Keeping old revisions here would turn a presentation
    // projection into an unbounded corpus cache.
    private(set) var states: [KnowledgeObjectSelectionKey: KnowledgeObjectReaderState] = [:]
    private var activeKey: KnowledgeObjectSelectionKey?
    private var generation = 0

    func state(for key: KnowledgeObjectSelectionKey) -> KnowledgeObjectReaderState { activeKey == key ? (states[key] ?? KnowledgeObjectReaderState()) : KnowledgeObjectReaderState() }
    func suspend() {
        generation &+= 1
        guard let activeKey, var state = states[activeKey] else { return }
        state.loading = false
        states[activeKey] = state
    }

    func load(
        _ key: KnowledgeObjectSelectionKey,
        offset: Int,
        request: @Sendable (KnowledgeObjectRef, Int) async throws -> KnowledgeObjectRead?,
        isCurrent: @MainActor () -> Bool
    ) async {
        guard !Task.isCancelled, isCurrent() else { return }
        if activeKey != key {
            states.removeAll(keepingCapacity: true)
            activeKey = key
        }
        var current = states[key] ?? KnowledgeObjectReaderState()
        current.generation &+= 1; let ticket = current.generation; let ownerGeneration = generation
        current.loading = true; current.error = nil; states[key] = current
        let requestedOffset = max(0, offset)
        do {
            let value = try await request(key.reference, requestedOffset)
            guard !Task.isCancelled, generation == ownerGeneration, isCurrent(), activeKey == key, states[key]?.generation == ticket else { return }
            guard let value, let bytes = Data(base64Encoded: value.base64),
                  value.hash == key.reference.hash,
                  value.mediaType == key.reference.mediaType,
                  value.bytes >= 0, value.bytes <= 512_000,
                  value.totalBytes == key.reference.bytes, value.totalBytes! >= 0, value.totalBytes! <= 512_000,
                  value.offset == requestedOffset,
                  bytes.count == value.bytes,
                  value.offset! <= value.totalBytes! - value.bytes,
                  (value.nextOffset == nil
                    ? value.offset! + value.bytes == value.totalBytes!
                    : value.nextOffset == value.offset! + value.bytes && value.nextOffset! > value.offset! && value.nextOffset! <= value.totalBytes!) else {
                states[key]?.loading = false
                states[key]?.error = "Retained object response is invalid."
                return
            }
            var updated = states[key] ?? KnowledgeObjectReaderState()
            guard requestedOffset == 0 || requestedOffset == updated.bytes.count else {
                updated.loading = false; updated.error = "The retained object changed while it was being read; reopen this representation."; states[key] = updated; return
            }
            if requestedOffset == 0 { updated.bytes = bytes } else { updated.bytes.append(bytes) }
            updated.totalBytes = value.totalBytes; updated.nextOffset = value.nextOffset; updated.loading = false; states[key] = updated
        } catch is CancellationError {
            // Cancellation must not leave the button disabled when the detail
            // becomes active again. A newer request still owns its own ticket.
            if generation == ownerGeneration, activeKey == key, states[key]?.generation == ticket { states[key]?.loading = false }
        }
        catch {
            guard !Task.isCancelled, generation == ownerGeneration, isCurrent(), activeKey == key, states[key]?.generation == ticket else { return }
            states[key]?.loading = false; states[key]?.error = error.localizedDescription
        }
    }
}
