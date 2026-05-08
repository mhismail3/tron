//! Operation binding for the context worker.

use super::operations;
use super::*;

pub(crate) async fn handle(
    method: &str,
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let payload = &invocation.payload;
    match method {
        "context::get_snapshot" => operations::get_snapshot(payload, deps).await,
        "context::get_detailed_snapshot" => operations::get_detailed_snapshot(payload, deps).await,
        "context::get_audit_trace" => operations::get_audit_trace(payload, deps).await,
        "context::should_compact" => operations::should_compact(payload, deps).await,
        "context::preview_compaction" => operations::preview_compaction(payload, deps).await,
        "context::can_accept_turn" => operations::can_accept_turn(payload, deps).await,
        "context::confirm_compaction" => operations::confirm_compaction(payload, deps).await,
        "context::clear" => operations::clear(payload, deps).await,
        "context::compact" => operations::compact(payload, deps).await,
        _ => Err(CapabilityError::Internal {
            message: format!("context method {method} is not engine-owned"),
        }),
    }
}
