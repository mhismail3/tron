use crate::runtime::errors::StopReason;

pub(super) fn determine_turn_stop_reason(
    stop_turn_requested: bool,
    tool_call_count: usize,
    llm_stop_reason: &str,
) -> Option<StopReason> {
    if stop_turn_requested {
        Some(StopReason::ToolStop)
    } else if tool_call_count == 0 {
        if llm_stop_reason == "end_turn" {
            Some(StopReason::EndTurn)
        } else {
            Some(StopReason::NoToolCalls)
        }
    } else {
        None
    }
}
