use chrono::{DateTime, Utc};
use serde_json::{Value, json};

use crate::domains::agent::context::token_estimator::estimate_message_tokens;
use crate::engine::{EngineResourceScope, ListResources};
use crate::shared::server::errors::CapabilityError;

use super::projection::event_ref;
use super::records::{SnapshotInput, snapshot_record};
use super::validation::{engine_error, store_error};
use super::{
    CONTEXT_CONTROL_ACTION_KIND, CONTEXT_CONTROL_EPOCH_KIND, CONTEXT_CONTROL_SNAPSHOT_KIND, Deps,
};

pub(super) async fn build_snapshot_record(
    deps: &Deps,
    session_id: &str,
    scope: &EngineResourceScope,
    snapshot_id: &str,
    operation_at: DateTime<Utc>,
) -> Result<Value, CapabilityError> {
    let state = deps
        .event_store
        .get_state_at_head(session_id)
        .map_err(store_error)?;
    let context_window =
        crate::domains::model::routing::models::registry::model_context_window(&state.model);
    let estimated_message_tokens: u64 = state
        .messages_with_event_ids
        .iter()
        .filter_map(|entry| {
            serde_json::to_value(&entry.message).ok().and_then(|value| {
                serde_json::from_value::<crate::shared::protocol::messages::Message>(value).ok()
            })
        })
        .map(|message| u64::from(estimate_message_tokens(&message)))
        .sum();
    let system_tokens = state
        .system_prompt
        .as_ref()
        .map_or(0, |prompt| prompt.len().div_ceil(4) as u64);
    let estimated_tokens = estimated_message_tokens.saturating_add(system_tokens);
    let message_count = state.messages_with_event_ids.len();
    let role_counts = role_counts(&state.messages_with_event_ids);
    let resource_refs = session_resource_refs(deps, scope).await?;
    let execution_refs = recent_execution_refs(deps, session_id)?;
    let current_epoch = latest_epoch_id(deps, scope)
        .await?
        .unwrap_or_else(|| "epoch-0".to_owned());
    let prompt_blocks = json!([
        {
            "kind": "system_seed",
            "label": "Hidden system/soul prompt",
            "estimatedTokens": system_tokens,
            "bodyExcluded": true
        },
        {
            "kind": "capability_schema",
            "label": "Provider-visible capability schema",
            "estimatedTokens": 0,
            "bodyExcluded": true
        },
        {
            "kind": "session_history",
            "label": "Current reconstructed provider history",
            "estimatedTokens": estimated_message_tokens,
            "messageCount": message_count,
            "roleCounts": role_counts,
            "rawContentExcluded": true
        },
        {
            "kind": "memory_refs",
            "label": "Read-only memory prompt refs",
            "estimatedTokens": 0,
            "rawContentExcluded": true
        }
    ]);
    let memory = json!({
        "status": "read_only",
        "policy": "memory refs only in Context Control v1",
        "promptTraceRefs": [],
        "redactedMemoryRefs": [],
        "retainEditTombstoneAvailable": false
    });
    let now = operation_at.to_rfc3339();
    Ok(snapshot_record(SnapshotInput {
        snapshot_id,
        scope,
        session_id,
        model: &state.model,
        context_window,
        estimated_tokens,
        turn_count: state.turn_count as u32,
        message_count,
        prompt_blocks,
        memory,
        resource_refs,
        execution_refs,
        epoch_id: &current_epoch,
        created_at: &now,
    }))
}

fn role_counts(
    messages: &[crate::domains::session::event_store::types::state::MessageWithEventId],
) -> Value {
    let mut user = 0;
    let mut assistant = 0;
    let mut capability_result = 0;
    for entry in messages {
        match entry.message.role.as_str() {
            "user" => user += 1,
            "assistant" => assistant += 1,
            "capabilityResult" | "capability_result" => capability_result += 1,
            _ => {}
        }
    }
    json!({
        "user": user,
        "assistant": assistant,
        "capabilityResult": capability_result
    })
}

async fn session_resource_refs(
    deps: &Deps,
    scope: &EngineResourceScope,
) -> Result<Vec<Value>, CapabilityError> {
    let mut refs = Vec::new();
    for kind in [
        CONTEXT_CONTROL_SNAPSHOT_KIND,
        CONTEXT_CONTROL_ACTION_KIND,
        CONTEXT_CONTROL_EPOCH_KIND,
    ] {
        let count = deps
            .engine_host
            .list_resources(ListResources {
                kind: Some(kind.to_owned()),
                scope: Some(scope.clone()),
                lifecycle: None,
                limit: 10,
            })
            .await
            .map_err(engine_error)?
            .len();
        refs.push(json!({"kind": kind, "count": count, "rawPayloadsExcluded": true}));
    }
    Ok(refs)
}

fn recent_execution_refs(deps: &Deps, session_id: &str) -> Result<Vec<Value>, CapabilityError> {
    let events = deps
        .event_store
        .get_latest_events(session_id, Some(20))
        .map_err(store_error)?;
    Ok(events
        .into_iter()
        .filter(|event| {
            matches!(
                event.event_type.as_str(),
                "capability.invocation.started"
                    | "capability.invocation.completed"
                    | "compact.boundary"
                    | "context.cleared"
            )
        })
        .take(10)
        .map(|event| event_ref(&event.id, event.sequence, &event.event_type))
        .collect())
}

async fn latest_epoch_id(
    deps: &Deps,
    scope: &EngineResourceScope,
) -> Result<Option<String>, CapabilityError> {
    Ok(deps
        .engine_host
        .list_resources(ListResources {
            kind: Some(CONTEXT_CONTROL_EPOCH_KIND.to_owned()),
            scope: Some(scope.clone()),
            lifecycle: Some("active".to_owned()),
            limit: 1,
        })
        .await
        .map_err(engine_error)?
        .first()
        .map(|resource| resource.resource_id.clone()))
}
