import Foundation
import os

/// Per-session worktree status, shared across the app.
///
/// Hydrated lazily from the worktree status engine protocol and kept live by
/// `EventStoreManager.handleGlobalEventV2` forwarding worktree plugin events
/// here. Both the chat toolbar (`WorktreeIsolationState`) and the session
/// sidebar row read from the same entries.
///
/// Invariants:
/// - Only successful fetches write to `statuses`. Errors never poison.
/// - Concurrent `ensureLoaded(id)` calls coalesce to a single engine protocol.
/// - Parallel cold fetches are capped at 4 via `AsyncSemaphore`.
@Observable
@MainActor
final class WorktreeStatusCache {

    typealias Fetch = @MainActor (_ sessionId: String) async throws -> WorktreeGetStatusResult

    private(set) var statuses: [String: WorktreeGetStatusResult] = [:]

    @ObservationIgnored
    private var inFlight: [String: Task<Void, Never>] = [:]

    @ObservationIgnored
    private let gate = AsyncSemaphore(value: 4)

    @ObservationIgnored
    private let fetch: Fetch

    @ObservationIgnored
    private let logger = Logger(subsystem: "com.tron.mobile", category: "Worktree")

    init(fetch: @escaping Fetch) {
        self.fetch = fetch
    }

    // MARK: Read

    func status(for sessionId: String) -> WorktreeGetStatusResult? {
        statuses[sessionId]
    }

    func shouldShowWorktreeIcon(sessionId: String) -> Bool {
        guard let s = statuses[sessionId], s.hasWorktree, let w = s.worktree else {
            return false
        }
        return !w.isOnBaseBranch
    }

    func shouldShowUncommittedDot(sessionId: String) -> Bool {
        statuses[sessionId]?.worktree?.hasUncommittedChanges == true
    }

    // MARK: Write

    func set(_ result: WorktreeGetStatusResult, for sessionId: String) {
        statuses[sessionId] = result
    }

    func invalidate(sessionId: String) {
        statuses.removeValue(forKey: sessionId)
    }

    func clearAll() {
        statuses.removeAll()
    }

    // MARK: Fetch

    /// Idempotent, deduped, gated fetch. Safe to call repeatedly from
    /// `.task(id:)` or from multiple rows simultaneously.
    func ensureLoaded(sessionId: String) async {
        if statuses[sessionId] != nil { return }
        if let existing = inFlight[sessionId] {
            await existing.value
            return
        }
        let task = Task { @MainActor in
            await performFetch(sessionId: sessionId)
            inFlight[sessionId] = nil
        }
        inFlight[sessionId] = task
        await task.value
    }

    func ensureLoaded(sessionIds: [String]) async {
        var seen: Set<String> = []
        let uniqueIds = sessionIds.filter { seen.insert($0).inserted }
        for sessionId in uniqueIds {
            await ensureLoaded(sessionId: sessionId)
        }
    }

    private func performFetch(sessionId: String) async {
        do {
            try await gate.wait()
        } catch {
            return
        }
        defer { Task { await gate.signal() } }

        do {
            let result = try await fetch(sessionId)
            statuses[sessionId] = result
        } catch {
            // INVARIANT: no negative caching — next caller may retry.
            logger.debug("worktree.getStatus failed for \(sessionId, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: Event application

    func applyAcquired(_ r: WorktreeAcquiredPlugin.Result, sessionId: String) {
        statuses[sessionId] = WorktreeGetStatusResult(
            hasWorktree: true,
            worktree: WorktreeInfo(
                isolated: true,
                branch: r.branch,
                baseCommit: r.baseCommit,
                path: r.path,
                baseBranch: r.baseBranch,
                repoRoot: nil,
                hasUncommittedChanges: false,
                commitCount: 0,
                isMerged: false
            )
        )
    }

    func applyCommit(_ r: WorktreeCommitPlugin.Result, sessionId: String) async {
        guard let existing = statuses[sessionId]?.worktree else {
            // Event is a delta — without a prior snapshot we can't reconstruct
            // the full WorktreeInfo, so pull the full status from the server.
            await ensureLoaded(sessionId: sessionId)
            return
        }
        statuses[sessionId] = WorktreeGetStatusResult(
            hasWorktree: true,
            worktree: WorktreeInfo(
                isolated: existing.isolated,
                branch: existing.branch,
                baseCommit: existing.baseCommit,
                path: existing.path,
                baseBranch: existing.baseBranch,
                repoRoot: existing.repoRoot,
                hasUncommittedChanges: r.hasUncommittedChanges,
                commitCount: r.totalCommitCount,
                isMerged: false
            )
        )
    }

    func applyReleased(sessionId: String) {
        statuses[sessionId] = WorktreeGetStatusResult(hasWorktree: false, worktree: nil)
    }

    /// Used by merge / finalize / rebase / abort events: server state is
    /// authoritative, so drop the cached entry and refetch.
    func refresh(sessionId: String) async {
        invalidate(sessionId: sessionId)
        await ensureLoaded(sessionId: sessionId)
    }

    // MARK: Global event routing

    /// Apply a global worktree-related event to the cache. Returns true if
    /// the event was recognized and handled; false otherwise. Safe to call
    /// for any `ParsedEventV2` — non-worktree events are ignored.
    @discardableResult
    func apply(_ event: ParsedEventV2) -> Bool {
        switch event.eventType {
        case ServerRestartingPlugin.eventType:
            clearAll()
            return true

        case WorktreeAcquiredPlugin.eventType:
            guard let id = event.sessionId,
                  let r = event.getResult() as? WorktreeAcquiredPlugin.Result
            else { return false }
            applyAcquired(r, sessionId: id)
            return true

        case WorktreeCommitPlugin.eventType:
            guard let id = event.sessionId,
                  let r = event.getResult() as? WorktreeCommitPlugin.Result
            else { return false }
            Task { await applyCommit(r, sessionId: id) }
            return true

        case WorktreeReleasedPlugin.eventType:
            guard let id = event.sessionId else { return false }
            applyReleased(sessionId: id)
            return true

        case WorktreeMergedPlugin.eventType,
             WorktreeSessionFinalizedPlugin.eventType,
             WorktreeRebasedOnMainPlugin.eventType,
             WorktreeMergeContinuedPlugin.eventType,
             WorktreeMergeAbortedPlugin.eventType:
            guard let id = event.sessionId else { return false }
            Task { await refresh(sessionId: id) }
            return true

        default:
            return false
        }
    }
}
