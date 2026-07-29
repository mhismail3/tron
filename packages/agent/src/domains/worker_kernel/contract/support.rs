//! Shared builders and bounded validation for fixed worker contracts.

use serde_json::{Value, json};

use super::{CONTEXT_SUMMARY_MAX_ESTIMATED_TOKENS, CONTEXT_SUMMARY_MAX_NARRATIVE_BYTES, WORKER};
use crate::domains::registration::contract::FunctionContract;
use crate::engine::{
    EffectClass, FunctionDefinition, IdempotencyContract, ModelToolAudience, ModelToolContract,
    RiskLevel,
};

/// Estimate semantic-summary tokens with the same cheap pre-call heuristic
/// used by the agent context budget. Provider-reported usage remains the
/// source of truth for completed model calls.
#[must_use]
pub(crate) fn estimate_context_summary_tokens(narrative: &str) -> usize {
    narrative.len().div_ceil(4)
}

pub(crate) fn validate_context_summary_narrative(narrative: &str) -> Result<(), String> {
    if narrative.trim().is_empty() {
        return Err("context-summary narrative must not be empty".to_owned());
    }
    let estimated_tokens = estimate_context_summary_tokens(narrative);
    if estimated_tokens > CONTEXT_SUMMARY_MAX_ESTIMATED_TOKENS {
        return Err(format!(
            "context-summary narrative is estimated at {estimated_tokens} tokens; the ceiling is {CONTEXT_SUMMARY_MAX_ESTIMATED_TOKENS} tokens"
        ));
    }
    if narrative.len() > CONTEXT_SUMMARY_MAX_NARRATIVE_BYTES {
        return Err(format!(
            "context-summary narrative is {} UTF-8 bytes; the storage ceiling is {} bytes",
            narrative.len(),
            CONTEXT_SUMMARY_MAX_NARRATIVE_BYTES
        ));
    }
    Ok(())
}

pub(super) fn expected_sha256_schema(allow_absent: bool) -> Value {
    let (pattern, description) = if allow_absent {
        (
            "^(?:absent|(?:sha256:)?[0-9A-Fa-f]{64})$",
            "Optional compare-and-swap precondition. Omit for an unconditional write, use the exact string `absent` to require a new file, or supply sha256:<hex> / raw 64-digit hex after reading an existing file.",
        )
    } else {
        (
            "^(?:sha256:)?[0-9A-Fa-f]{64}$",
            "Optional compare-and-swap precondition from filesystem_read or a prior mutation. Omit it instead of sending an empty string.",
        )
    };
    json!({"type":"string","pattern":pattern,"description":description})
}

pub(super) fn spec(
    function: &'static str,
    effect: EffectClass,
    risk: RiskLevel,
    request: Value,
    description: &'static str,
) -> crate::engine::Result<FunctionDefinition> {
    let mut contract = FunctionContract::new(function, WORKER, effect, risk)
        .request_schema(request)
        .response_schema(super::response::response_schema(function))
        .description(description);
    if effect.requires_idempotency() {
        contract = contract.idempotency(if profile_owned_worker_operation(function) {
            IdempotencyContract::profile()
        } else {
            IdempotencyContract::session()
        });
    }
    contract.build()
}

#[allow(clippy::too_many_arguments)]
pub(super) fn model_spec(
    function: &'static str,
    effect: EffectClass,
    risk: RiskLevel,
    request: Value,
    description: &'static str,
    model_name: &'static str,
    audience: ModelToolAudience,
    order: u16,
    group: &'static str,
) -> crate::engine::Result<FunctionDefinition> {
    spec(function, effect, risk, request, description).map(|definition| {
        definition.with_model_tool(ModelToolContract {
            name: model_name.to_owned(),
            audience,
            order: Some(order),
            group: Some(group.to_owned()),
            worker: None,
        })
    })
}

fn profile_owned_worker_operation(function: &str) -> bool {
    matches!(
        function,
        "worker_kernel::upsert"
            | "worker_kernel::notification_device_upsert"
            | "worker_kernel::notification_device_disable"
            | "worker_kernel::notification_delivery_acknowledge"
            | "worker_kernel::invoke"
            | "worker_kernel::detach"
            | "worker_kernel::cancel"
            | "worker_kernel::stop"
            | "worker_kernel::disable"
            | "worker_kernel::enable"
            | "worker_kernel::retire"
            | "worker_kernel::purge"
            | "worker_kernel::rollback"
            | "worker_kernel::webhook_rotate"
            | "worker_kernel::stop_all"
    )
}
