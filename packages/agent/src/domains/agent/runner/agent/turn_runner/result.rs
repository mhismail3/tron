use crate::domains::agent::runner::errors::StopReason;

pub(super) fn determine_turn_stop_reason(
    stop_turn_requested: bool,
    capability_invocation_count: usize,
    llm_stop_reason: &str,
) -> Option<StopReason> {
    if stop_turn_requested {
        Some(StopReason::CapabilityStop)
    } else if capability_invocation_count == 0 {
        if llm_stop_reason == "end_turn" {
            Some(StopReason::EndTurn)
        } else {
            Some(StopReason::NoCapabilityInvocationDrafts)
        }
    } else {
        None
    }
}
