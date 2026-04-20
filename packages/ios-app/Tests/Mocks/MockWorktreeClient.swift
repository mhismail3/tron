import Foundation
@testable import TronMobile

/// Test double for the worktree status fetch used by `WorktreeStatusCache`.
/// Captures call history, injects errors/results/delays, and tracks peak
/// concurrent callers for gate-bound tests.
@MainActor
final class MockWorktreeClient {
    var getStatusCallCount = 0
    var getStatusSessionIds: [String] = []
    var getStatusResultBySession: [String: WorktreeGetStatusResult] = [:]
    var getStatusDefaultResult = WorktreeGetStatusResult(hasWorktree: false, worktree: nil)
    var getStatusError: Error?
    /// Nanoseconds to suspend inside each `getStatus` call — simulates latency.
    var getStatusDelay: UInt64 = 0

    private(set) var currentConcurrent = 0
    private(set) var peakConcurrent = 0

    func getStatus(sessionId: String) async throws -> WorktreeGetStatusResult {
        getStatusCallCount += 1
        getStatusSessionIds.append(sessionId)
        currentConcurrent += 1
        peakConcurrent = max(peakConcurrent, currentConcurrent)

        if getStatusDelay > 0 {
            try? await Task.sleep(nanoseconds: getStatusDelay)
        }

        currentConcurrent -= 1
        if let error = getStatusError { throw error }
        return getStatusResultBySession[sessionId] ?? getStatusDefaultResult
    }
}

enum MockWorktreeError: Error { case simulated }

// MARK: - Fixture helpers

extension WorktreeInfo {
    /// Canonical test worktree. Pass any overrides to tune the scenario.
    static func fixture(
        isolated: Bool = true,
        branch: String = "session/alpha",
        baseCommit: String = "abc1234",
        path: String = "/tmp/wt/alpha",
        baseBranch: String? = "main",
        repoRoot: String? = "/tmp/repo",
        hasUncommittedChanges: Bool? = false,
        commitCount: Int? = 0,
        isMerged: Bool? = false
    ) -> WorktreeInfo {
        WorktreeInfo(
            isolated: isolated,
            branch: branch,
            baseCommit: baseCommit,
            path: path,
            baseBranch: baseBranch,
            repoRoot: repoRoot,
            hasUncommittedChanges: hasUncommittedChanges,
            commitCount: commitCount,
            isMerged: isMerged
        )
    }
}

extension WorktreeGetStatusResult {
    static func fixture(
        hasWorktree: Bool = true,
        worktree: WorktreeInfo? = .fixture()
    ) -> WorktreeGetStatusResult {
        WorktreeGetStatusResult(hasWorktree: hasWorktree, worktree: worktree)
    }

    static var empty: WorktreeGetStatusResult {
        WorktreeGetStatusResult(hasWorktree: false, worktree: nil)
    }
}
