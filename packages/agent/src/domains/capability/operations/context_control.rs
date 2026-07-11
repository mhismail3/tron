//! Context-control execute operation adapters.

use chrono::{DateTime, Utc};
use serde_json::{Value, json};

use super::{Deps, ok_result};
use crate::engine::Invocation;
use crate::shared::protocol::model_capabilities::CapabilityResult;
use crate::shared::server::errors::CapabilityError;

pub(super) async fn context_control_status(
    invocation: &Invocation,
    deps: &Deps,
    operation_at: DateTime<Utc>,
) -> Result<CapabilityResult, CapabilityError> {
    let context_deps = context_deps(deps);
    let details = crate::domains::context_control::service::status_value_at(
        &context_deps,
        invocation,
        &invocation.payload,
        operation_at,
    )
    .await?;
    let content = context_status_content(&details);
    Ok(result(&content, "context_control_status", details))
}

pub(super) async fn context_control_snapshot(
    invocation: &Invocation,
    deps: &Deps,
    operation_at: DateTime<Utc>,
) -> Result<CapabilityResult, CapabilityError> {
    let context_deps = context_deps(deps);
    let details = crate::domains::context_control::service::snapshot_value_at(
        &context_deps,
        invocation,
        &invocation.payload,
        operation_at,
    )
    .await?;
    Ok(result(
        "Context snapshot recorded.",
        "context_control_snapshot",
        details,
    ))
}

pub(super) async fn context_control_compact(
    invocation: &Invocation,
    deps: &Deps,
    operation_at: DateTime<Utc>,
) -> Result<CapabilityResult, CapabilityError> {
    let context_deps = crate::domains::context_control::Deps {
        engine_host: deps.engine_host.clone(),
        event_store: deps.event_store.clone(),
        session_manager: deps.session_manager.clone(),
    };
    let details = crate::domains::context_control::service::compact_value_at(
        &context_deps,
        invocation,
        &invocation.payload,
        operation_at,
    )
    .await?;
    Ok(context_boundary_result(
        "Context compaction action recorded.",
        "context_control_compact",
        details,
    ))
}

pub(super) async fn context_control_clear(
    invocation: &Invocation,
    deps: &Deps,
    operation_at: DateTime<Utc>,
) -> Result<CapabilityResult, CapabilityError> {
    let context_deps = crate::domains::context_control::Deps {
        engine_host: deps.engine_host.clone(),
        event_store: deps.event_store.clone(),
        session_manager: deps.session_manager.clone(),
    };
    let details = crate::domains::context_control::service::clear_value_at(
        &context_deps,
        invocation,
        &invocation.payload,
        operation_at,
    )
    .await?;
    Ok(context_boundary_result(
        "Context clear action recorded.",
        "context_control_clear",
        details,
    ))
}

pub(super) async fn context_control_action_list(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let context_deps = crate::domains::context_control::Deps {
        engine_host: deps.engine_host.clone(),
        event_store: deps.event_store.clone(),
        session_manager: deps.session_manager.clone(),
    };
    let details = crate::domains::context_control::service::action_list_value(
        &context_deps,
        invocation,
        &invocation.payload,
    )
    .await?;
    let count = details
        .pointer("/projection/actions")
        .and_then(Value::as_array)
        .map_or(0, Vec::len);
    Ok(result(
        &format!("Listed {count} context-control action(s)."),
        "context_control_action_list",
        details,
    ))
}

pub(super) async fn context_control_action_inspect(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let context_deps = crate::domains::context_control::Deps {
        engine_host: deps.engine_host.clone(),
        event_store: deps.event_store.clone(),
        session_manager: deps.session_manager.clone(),
    };
    let details = crate::domains::context_control::service::action_inspect_value(
        &context_deps,
        invocation,
        &invocation.payload,
    )
    .await?;
    Ok(result(
        "Inspected context-control action.",
        "context_control_action_inspect",
        details,
    ))
}

pub(super) async fn context_survivor_record(
    invocation: &Invocation,
    deps: &Deps,
    operation_at: DateTime<Utc>,
) -> Result<CapabilityResult, CapabilityError> {
    let context_deps = context_deps(deps);
    let details = crate::domains::context_control::service::survivor_record_value_at(
        &context_deps,
        invocation,
        &invocation.payload,
        operation_at,
    )
    .await?;
    Ok(result(
        "Context survivor policy recorded.",
        "context_survivor_record",
        details,
    ))
}

pub(super) async fn context_survivor_list(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let context_deps = context_deps(deps);
    let details = crate::domains::context_control::service::survivor_list_value(
        &context_deps,
        invocation,
        &invocation.payload,
    )
    .await?;
    let count = details
        .pointer("/projection/records")
        .and_then(Value::as_array)
        .map_or(0, Vec::len);
    Ok(result(
        &format!("Listed {count} context survivor policy record(s)."),
        "context_survivor_list",
        details,
    ))
}

pub(super) async fn context_survivor_disable(
    invocation: &Invocation,
    deps: &Deps,
    operation_at: DateTime<Utc>,
) -> Result<CapabilityResult, CapabilityError> {
    let context_deps = context_deps(deps);
    let details = crate::domains::context_control::service::survivor_disable_value_at(
        &context_deps,
        invocation,
        &invocation.payload,
        operation_at,
    )
    .await?;
    Ok(result(
        "Context survivor policy disabled.",
        "context_survivor_disable",
        details,
    ))
}

pub(super) async fn context_exclusion_record(
    invocation: &Invocation,
    deps: &Deps,
    operation_at: DateTime<Utc>,
) -> Result<CapabilityResult, CapabilityError> {
    let context_deps = context_deps(deps);
    let details = crate::domains::context_control::service::exclusion_record_value_at(
        &context_deps,
        invocation,
        &invocation.payload,
        operation_at,
    )
    .await?;
    Ok(result(
        "Context exclusion policy recorded.",
        "context_exclusion_record",
        details,
    ))
}

pub(super) async fn context_exclusion_list(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let context_deps = context_deps(deps);
    let details = crate::domains::context_control::service::exclusion_list_value(
        &context_deps,
        invocation,
        &invocation.payload,
    )
    .await?;
    let count = details
        .pointer("/projection/records")
        .and_then(Value::as_array)
        .map_or(0, Vec::len);
    Ok(result(
        &format!("Listed {count} context exclusion policy record(s)."),
        "context_exclusion_list",
        details,
    ))
}

pub(super) async fn context_exclusion_disable(
    invocation: &Invocation,
    deps: &Deps,
    operation_at: DateTime<Utc>,
) -> Result<CapabilityResult, CapabilityError> {
    let context_deps = context_deps(deps);
    let details = crate::domains::context_control::service::exclusion_disable_value_at(
        &context_deps,
        invocation,
        &invocation.payload,
        operation_at,
    )
    .await?;
    Ok(result(
        "Context exclusion policy disabled.",
        "context_exclusion_disable",
        details,
    ))
}

pub(super) async fn context_policy_snapshot(
    invocation: &Invocation,
    deps: &Deps,
    operation_at: DateTime<Utc>,
) -> Result<CapabilityResult, CapabilityError> {
    let context_deps = context_deps(deps);
    let details = crate::domains::context_control::service::policy_snapshot_value_at(
        &context_deps,
        invocation,
        &invocation.payload,
        operation_at,
    )
    .await?;
    Ok(result(
        "Context policy snapshot recorded.",
        "context_policy_snapshot",
        details,
    ))
}

fn context_deps(deps: &Deps) -> crate::domains::context_control::Deps {
    crate::domains::context_control::Deps {
        engine_host: deps.engine_host.clone(),
        event_store: deps.event_store.clone(),
        session_manager: deps.session_manager.clone(),
    }
}

fn context_status_content(details: &Value) -> String {
    let status = details
        .pointer("/projection/status")
        .cloned()
        .unwrap_or(Value::Null);
    let session = status.pointer("/session").unwrap_or(&Value::Null);
    let epoch = session
        .get("currentEpoch")
        .and_then(Value::as_str)
        .unwrap_or("unknown");
    let used_tokens = session
        .get("estimatedTokens")
        .and_then(Value::as_u64)
        .unwrap_or(0);
    let window_tokens = session
        .get("contextWindowTokens")
        .and_then(Value::as_u64)
        .unwrap_or(0);
    let remaining_tokens = session
        .get("tokensRemaining")
        .and_then(Value::as_u64)
        .unwrap_or(0);
    let usage_percent = session
        .get("usagePercent")
        .and_then(Value::as_f64)
        .map_or_else(
            || "unknown".to_owned(),
            |usage| format!("{:.1}%", usage * 100.0),
        );
    let message_count = session
        .get("messageCount")
        .and_then(Value::as_u64)
        .unwrap_or(0);
    let turn_count = session
        .get("turnCount")
        .and_then(Value::as_u64)
        .unwrap_or(0);
    let composition = context_status_composition_summary(&status);
    let freshness = status.pointer("/freshness").unwrap_or(&Value::Null);
    let resource_written = freshness
        .get("resourceWritten")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let action_written = freshness
        .get("actionWritten")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let freshness_kind = freshness
        .get("kind")
        .and_then(Value::as_str)
        .unwrap_or("unknown");
    let proof = status.pointer("/proof").unwrap_or(&Value::Null);
    let provider_safe = proof
        .get("providerSafe")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let network_policy = proof
        .get("networkPolicy")
        .and_then(Value::as_str)
        .unwrap_or("unknown");
    format!(
        "Context status inspected without recording a snapshot. Current context: epoch {epoch}; {} of {} estimated tokens used ({usage_percent}), {} remaining; {message_count} message(s) across {turn_count} turn(s). Composition: {composition}. Freshness proof: {freshness_kind}, resourceWritten={resource_written}, actionWritten={action_written}, providerSafe={provider_safe}, networkPolicy={network_policy}.",
        compact_tokens(used_tokens),
        compact_tokens(window_tokens),
        compact_tokens(remaining_tokens),
    )
}

fn context_status_composition_summary(status: &Value) -> String {
    let blocks = status
        .pointer("/composition/promptBlocks")
        .and_then(Value::as_array);
    let (history_tokens, history_messages) = blocks
        .and_then(|blocks| {
            blocks
                .iter()
                .find(|block| block.get("kind").and_then(Value::as_str) == Some("session_history"))
        })
        .map(|block| {
            (
                block
                    .get("estimatedTokens")
                    .and_then(Value::as_u64)
                    .unwrap_or(0),
                block
                    .get("messageCount")
                    .and_then(Value::as_u64)
                    .unwrap_or(0),
            )
        })
        .unwrap_or((0, 0));
    let excluded_blocks = blocks.map_or(0, |blocks| {
        blocks
            .iter()
            .filter(|block| {
                block
                    .get("bodyExcluded")
                    .and_then(Value::as_bool)
                    .unwrap_or(false)
                    || block
                        .get("rawContentExcluded")
                        .and_then(Value::as_bool)
                        .unwrap_or(false)
            })
            .count()
    });
    let resource_refs = status
        .pointer("/composition/resourceRefs")
        .and_then(Value::as_array)
        .map_or(0, Vec::len);
    let execution_refs = status
        .pointer("/composition/executionRefs")
        .and_then(Value::as_array)
        .map_or(0, Vec::len);
    format!(
        "session_history {} across {history_messages} message(s); {excluded_blocks} block(s) have prompt/raw bodies excluded; {resource_refs} resource ref summary item(s); {execution_refs} recent execution ref(s)",
        compact_tokens(history_tokens),
    )
}

fn compact_tokens(tokens: u64) -> String {
    if tokens >= 1_000_000 {
        let tenths = tokens.saturating_mul(10) / 1_000_000;
        format!("{}.{}m", tenths / 10, tenths % 10)
    } else if tokens >= 1_000 {
        let tenths = tokens.saturating_mul(10) / 1_000;
        format!("{}.{}k", tenths / 10, tenths % 10)
    } else {
        tokens.to_string()
    }
}

fn result(text: &str, operation: &str, details: Value) -> CapabilityResult {
    ok_result(
        text.to_owned(),
        json!({
            "primitiveOperation": operation,
            "status": details.get("status").and_then(Value::as_str).unwrap_or("ok"),
            "contextControl": details
        }),
    )
}

fn context_boundary_result(text: &str, operation: &str, details: Value) -> CapabilityResult {
    let mut result = result(text, operation, details);
    if result
        .details
        .as_ref()
        .and_then(|details| details.pointer("/contextControl/boundaryCommittedThisInvocation"))
        .and_then(Value::as_bool)
        == Some(true)
    {
        result.stop_turn = Some(true);
    }
    result
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::{context_boundary_result, context_status_content};

    #[test]
    fn context_status_content_surfaces_agent_needed_context_facts() {
        let details = json!({
            "projection": {
                "status": {
                    "session": {
                        "currentEpoch": "epoch-7",
                        "estimatedTokens": 32356,
                        "contextWindowTokens": 272000,
                        "tokensRemaining": 239644,
                        "usagePercent": 0.11895588235294118,
                        "messageCount": 15,
                        "turnCount": 7
                    },
                    "composition": {
                        "promptBlocks": [
                            {"kind": "system_seed", "estimatedTokens": 50, "bodyExcluded": true},
                            {"kind": "capability_schema", "estimatedTokens": 0, "bodyExcluded": true},
                            {
                                "kind": "session_history",
                                "estimatedTokens": 32306,
                                "messageCount": 15,
                                "rawContentExcluded": true
                            },
                            {"kind": "memory_refs", "estimatedTokens": 0, "rawContentExcluded": true}
                        ],
                        "resourceRefs": [{"kind": "context_control_snapshot", "count": 0}],
                        "executionRefs": [{}, {}]
                    },
                    "freshness": {
                        "kind": "ephemeral_current_head",
                        "resourceWritten": false,
                        "actionWritten": false
                    },
                    "proof": {
                        "providerSafe": true,
                        "networkPolicy": "none"
                    }
                }
            }
        });

        let content = context_status_content(&details);

        assert!(content.contains("epoch epoch-7"));
        assert!(content.contains("32.3k of 272.0k estimated tokens used"));
        assert!(content.contains("11.9%"));
        assert!(content.contains("239.6k remaining"));
        assert!(content.contains("session_history 32.3k across 15 message(s)"));
        assert!(content.contains("resourceWritten=false"));
        assert!(content.contains("actionWritten=false"));
        assert!(content.contains("providerSafe=true"));
        assert!(content.contains("networkPolicy=none"));
        assert!(!content.contains("sessionId"));
    }

    #[test]
    fn compact_and_clear_results_end_the_active_agent_run() {
        for operation in ["context_control_compact", "context_control_clear"] {
            let result = context_boundary_result(
                "recorded",
                operation,
                json!({
                    "status": "ok",
                    "boundaryCommittedThisInvocation": true,
                    "projection": {"result": {"timelineEventWritten": true}}
                }),
            );
            assert_eq!(result.stop_turn, Some(true));
        }
    }

    #[test]
    fn skipped_compaction_does_not_end_the_active_agent_run() {
        let result = context_boundary_result(
            "skipped",
            "context_control_compact",
            json!({
                "status": "skipped",
                "boundaryCommittedThisInvocation": false,
                "projection": {"result": {"timelineEventWritten": false}}
            }),
        );
        assert_eq!(result.stop_turn, None);
    }

    #[test]
    fn idempotent_boundary_replay_does_not_end_a_new_agent_run() {
        let result = context_boundary_result(
            "replayed",
            "context_control_clear",
            json!({
                "status": "succeeded",
                "idempotentReplay": true,
                "boundaryCommittedThisInvocation": false,
                "projection": {"result": {"timelineEventWritten": true}}
            }),
        );
        assert_eq!(result.stop_turn, None);
    }
}
