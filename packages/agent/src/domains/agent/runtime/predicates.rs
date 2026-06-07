//! Prompt runtime predicate helpers.

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
