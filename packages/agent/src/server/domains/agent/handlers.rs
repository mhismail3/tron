//! Operation binding for the agent worker.

use super::operations::*;
use super::*;

pub(crate) async fn handle(
    method: &str,
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let payload = &invocation.payload;
    match method {
        "agent::prompt" => prompt_value(invocation, deps).await,
        "agent::prompt_apply" => prompt_apply_value(Some(payload), invocation, deps).await,
        "agent::run_turn" => run_turn_value(Some(payload), invocation, deps).await,
        "agent::prompt_queue_drain" => {
            prompt_queue_drain_value(Some(payload), invocation, deps).await
        }
        "agent::status" => status_value(Some(payload), deps).await,
        "agent::abort" => abort_value(Some(payload), deps).await,
        "agent::abort_tool" => abort_tool_value(Some(payload), deps).await,
        "agent::queue_prompt" => queue_prompt_value(Some(payload), invocation, deps).await,
        "agent::dequeue_prompt" => dequeue_prompt_value(Some(payload), invocation, deps).await,
        "agent::clear_queue" => clear_queue_value(Some(payload), invocation, deps).await,
        "agent::deliver_subagent_results" => {
            deliver_subagent_results_value(Some(payload), deps).await
        }
        "agent::submit_confirmation" => submit_confirmation_value(Some(payload), deps).await,
        "agent::submit_answers" => submit_answers_value(Some(payload), deps).await,
        _ => Err(CapabilityError::Internal {
            message: format!("agent method {method} is not engine-owned"),
        }),
    }
}
