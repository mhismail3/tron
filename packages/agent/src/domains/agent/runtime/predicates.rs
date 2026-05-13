//! Prompt runtime predicate helpers.

/// Returns true if a new prompt run for this session should attempt worktree
/// acquisition. Chat sessions (`source == Some("chat")`) are conversational and
/// never get worktrees regardless of global isolation mode or per-session
/// `useWorktree` override.
pub(super) fn should_acquire_worktree_for_source(source: Option<&str>) -> bool {
    source != Some("chat")
}

/// Whether a finished agent run's stop reason represents a coherent
/// conclusion that auto-retain can safely summarize.
pub(super) fn retain_eligible(
    stop_reason: &crate::domains::agent::runner::errors::StopReason,
) -> bool {
    use crate::domains::agent::runner::errors::StopReason;
    matches!(
        stop_reason,
        StopReason::EndTurn | StopReason::NoCapabilityInvocationDrafts | StopReason::MaxTurns
    )
}

#[cfg(test)]
mod retain_eligible_tests {
    use super::retain_eligible;
    use crate::domains::agent::runner::errors::StopReason;

    #[test]
    fn end_turn_is_eligible() {
        assert!(retain_eligible(&StopReason::EndTurn));
    }

    #[test]
    fn no_capability_invocations_is_eligible() {
        assert!(retain_eligible(&StopReason::NoCapabilityInvocationDrafts));
    }

    #[test]
    fn max_turns_is_eligible() {
        assert!(retain_eligible(&StopReason::MaxTurns));
    }

    #[test]
    fn capability_stop_is_not_eligible() {
        assert!(!retain_eligible(&StopReason::CapabilityStop));
    }

    #[test]
    fn interrupted_is_not_eligible() {
        assert!(!retain_eligible(&StopReason::Interrupted));
    }

    #[test]
    fn error_is_not_eligible() {
        assert!(!retain_eligible(&StopReason::Error));
    }
}

#[cfg(test)]
mod should_acquire_worktree_tests {
    use super::should_acquire_worktree_for_source;

    #[test]
    fn chat_source_never_acquires_worktree() {
        assert!(!should_acquire_worktree_for_source(Some("chat")));
    }

    #[test]
    fn project_source_may_acquire_worktree() {
        assert!(should_acquire_worktree_for_source(Some("project")));
    }

    #[test]
    fn missing_source_may_acquire_worktree() {
        assert!(should_acquire_worktree_for_source(None));
    }

    #[test]
    fn unknown_source_may_acquire_worktree() {
        assert!(should_acquire_worktree_for_source(Some("future_source")));
    }

    #[test]
    fn empty_string_source_may_acquire_worktree() {
        assert!(should_acquire_worktree_for_source(Some("")));
    }

    #[test]
    fn uppercase_chat_does_not_match() {
        assert!(should_acquire_worktree_for_source(Some("Chat")));
        assert!(should_acquire_worktree_for_source(Some("CHAT")));
    }
}
