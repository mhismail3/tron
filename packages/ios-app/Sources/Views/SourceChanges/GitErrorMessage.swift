import Foundation

/// Shared friendly-error formatter for git workflow sub-sheets.
///
/// Maps typed `RPCErrorCode` cases (from the Rust handlers' new
/// `map_worktree_error`) to user-facing copy so that every sub-sheet
/// shows an actionable message instead of the bare Rust error string.
///
/// INVARIANT: the switch on `RPCErrorCode` is exhaustive — adding a
/// new case to the enum forces a compile error here. Never add a
/// `default` branch; route the new case through an explicit arm so
/// it gets phrased for a human.
///
/// - Parameters:
///   - error: The error caught from an `rpcClient.*` call.
///   - action: A past-tense verb naming the attempted action ("Push",
///     "Pull", "Commit", "Merge", "Rebase", "Sync", "Resolve"). Used
///     in the fallback "{action} failed: …" phrasing for codes that
///     don't have specific copy.
/// - Returns: A single-line message suitable for display in
///   `tronErrorAlert`. Never an empty string.
func friendlyGitError(_ error: Error, action: String) -> String {
    guard let rpc = error as? RPCError else {
        return "\(action) failed: \(error.localizedDescription)"
    }
    guard let code = rpc.errorCode else {
        // Unknown code from a newer server — pass through the raw
        // message. Better than pretending we understand.
        return "\(action) failed: \(rpc.message)"
    }
    switch code {
    case .protectedBranch:
        return "Cannot \(action.lowercased()) a protected branch. \(rpc.message)"
    case .noRemote:
        return "No remote is configured. Add an `origin` first."
    case .nonFastForward:
        return "Push rejected — the remote has new commits. "
            + "Pull first or enable Force with Lease."
    case .gitAuthFailed:
        return "Git authentication failed. Check your SSH key or credentials."
    case .gitNetworkError:
        return "Network error reaching the remote. Check your connection and retry."
    case .worktreeNotFound:
        return "This session no longer has a worktree. Restart the session and try again."
    case .dirtyWorkingTree:
        return "Working tree has uncommitted changes. Commit or stash them first."
    case .missingBaseBranch:
        return "Session has no base branch — set one in Settings or pass it explicitly."
    case .refNotFound:
        return "A required ref was not found: \(rpc.message)"
    case .branchExists:
        return "That branch already exists: \(rpc.message)"
    case .branchActive:
        return "That branch is currently checked out elsewhere: \(rpc.message)"
    case .notGitRepo:
        return "This directory isn't a git repository."
    case .gitError:
        return "\(action) failed: \(rpc.message)"
    case .invalidParams:
        return rpc.message
    case .sessionNotFound, .agentNotRunning, .methodNotFound, .internalError:
        return "\(action) failed: \(rpc.message)"
    }
}
