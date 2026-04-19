import Foundation

/// Action verb used in friendly git error messages. Replaces free-form
/// strings so a typo can't reach `tronErrorAlert`. Each variant carries
/// both the title-case form (used in "{Push} failed") and the lower-
/// case imperative (used in "Cannot {push} a protected branch").
enum GitActionVerb: String {
    case push, commit, merge, rebase, sync, spawn, abort, stage, unstage, discard, prune, load

    /// Title-case form for "{Verb} failed" sentences.
    var titleCase: String { rawValue.capitalized }

    /// Lower-case imperative for "Cannot {verb}" sentences.
    var imperativeLower: String { rawValue }
}

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
/// Convention: do NOT pass `error.localizedDescription` directly to
/// user-visible alerts for an RPC error. Always route through this
/// function so typed codes get human copy.
///
/// - Parameters:
///   - error: The error caught from an `rpcClient.*` call.
///   - action: Typed verb naming the attempted action. Used in the
///     "{Action} failed: …" fallback for codes without specific copy
///     and in the "Cannot {action} ..." protected-branch arm.
/// - Returns: A single-line message suitable for display in
///   `tronErrorAlert`. Never an empty string.
func friendlyGitError(_ error: Error, action: GitActionVerb) -> String {
    let verb = action.titleCase
    guard let rpc = error as? RPCError else {
        return "\(verb) failed: \(error.localizedDescription)"
    }
    guard let code = rpc.errorCode else {
        // Unknown code from a newer server — pass through the raw
        // message. Better than pretending we understand.
        return "\(verb) failed: \(rpc.message)"
    }
    switch code {
    case .protectedBranch:
        return "Cannot \(action.imperativeLower) a protected branch. \(rpc.message)"
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
        return "\(verb) failed: \(rpc.message)"
    case .invalidParams:
        return rpc.message
    case .eventNotFound:
        return "Couldn't find that event."
    case .workspaceNotFound:
        return "Couldn't find that workspace."
    case .blobNotFound:
        return "Couldn't find that file."
    // Cron / auth / import codes pass through to the standard
    // "{verb} failed: {message}" — these RPCs aren't called from git
    // sub-sheets, but the case-iterable contract requires every code to
    // produce a message so we route them to the same fallback.
    case .cronNotFound, .cronDuplicateName, .cronInvalidExpression,
         .cronInvalidTimezone, .cronTimedOut, .cronCancelled,
         .authNotConfigured, .authTokenExpired, .authOauthError,
         .importSessionNotFound, .importAlreadyImported,
         .importEmptySession, .importNoClaudeDirectory:
        return "\(verb) failed: \(rpc.message)"
    case .sessionNotFound, .agentNotRunning, .methodNotFound, .internalError:
        return "\(verb) failed: \(rpc.message)"
    }
}
