use crate::domains::worktree::errors::WorktreeError;

/// Map a `run`-style error from a remote/push operation onto a typed
/// `WorktreeError` variant by pattern-matching on the stderr string.
///
/// Falls back to the original `Git(String)` variant if no pattern matches,
/// so callers still get the raw message for surfacing to the user.
pub(crate) fn classify_remote_error(e: WorktreeError) -> WorktreeError {
    let msg = match &e {
        WorktreeError::Git(m) => m.clone(),
        _ => return e,
    };
    let lower = msg.to_lowercase();
    if lower.contains("authentication failed")
        || lower.contains("could not read username")
        || lower.contains("permission denied (publickey)")
        || lower.contains("permission denied")
        || lower.contains("terminal prompts disabled")
        || lower.contains("403 forbidden")
        || lower.contains("401 unauthorized")
    {
        WorktreeError::AuthFailure(msg)
    } else if lower.contains("could not resolve host")
        || lower.contains("connection refused")
        || lower.contains("connection timed out")
        || lower.contains("connection reset")
        || lower.contains("network is unreachable")
        || lower.contains("operation timed out")
    {
        WorktreeError::NetworkTimeout(msg)
    } else if lower.contains("no such remote")
        || lower.contains("does not appear to be a git repository")
        || lower.contains("no configured push destination")
    {
        WorktreeError::NoRemoteConfigured(msg)
    } else {
        WorktreeError::Git(msg)
    }
}

/// Like `classify_remote_error` but also recognises the non-fast-forward
/// rejection patterns that can come out of `git push`.
pub(crate) fn classify_push_error(stderr: String) -> WorktreeError {
    let lower = stderr.to_lowercase();
    if lower.contains("(non-fast-forward)")
        || lower.contains("rejected")
            && (lower.contains("non-fast-forward") || lower.contains("fetch first"))
    {
        return WorktreeError::NonFastForward(stderr);
    }
    if lower.contains("stale info") || lower.contains("force-with-lease") {
        // Stale force-with-lease — also a non-FF variant. Surface as non-FF.
        return WorktreeError::NonFastForward(stderr);
    }
    // Delegate the rest to the generic remote classifier.
    classify_remote_error(WorktreeError::Git(stderr))
}
