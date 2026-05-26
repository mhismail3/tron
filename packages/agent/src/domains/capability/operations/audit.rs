//! Capability audit query helpers.

use serde_json::{Map, Value, json};

use super::{record_admin_audit, registry_store_error};
use crate::domains::capability::Deps;
use crate::domains::capability::registry::{bool_field, string_field, u64_field};
use crate::engine::Invocation;
use crate::shared::server::context::run_blocking_task;
use crate::shared::server::errors::CapabilityError;

pub(crate) async fn audit_query_value(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let event_type = string_field(&invocation.payload, "eventType");
    let trace_id = string_field(&invocation.payload, "traceId");
    let orchestration_status = string_field(&invocation.payload, "orchestrationStatus");
    let correction_kind = string_field(&invocation.payload, "correctionKind");
    let phase = string_field(&invocation.payload, "phase");
    let orchestration_filters_present =
        orchestration_status.is_some() || correction_kind.is_some() || phase.is_some();
    let limit = u64_field(&invocation.payload, "limit")
        .map(|value| value.clamp(1, 200) as usize)
        .unwrap_or(50);
    let reveal_payloads = bool_field(&invocation.payload, "revealPayloads").unwrap_or(false);
    let store = deps.registry_store.clone();
    let event_type_for_query = event_type
        .clone()
        .or_else(|| orchestration_filters_present.then(|| "capability.orchestration".to_owned()));
    let trace_id_for_query = trace_id.clone();
    let query_limit = if orchestration_filters_present {
        200
    } else {
        limit
    };
    let reveal_for_query = reveal_payloads || orchestration_filters_present;
    let result = run_blocking_task("capability.audit_query", move || {
        let store = store.lock().map_err(|_| CapabilityError::Internal {
            message: "capability registry store mutex poisoned".to_owned(),
        })?;
        store
            .audit_query(
                event_type_for_query.as_deref(),
                trace_id_for_query.as_deref(),
                query_limit,
                reveal_for_query,
            )
            .map_err(registry_store_error)
    })
    .await?;
    let result = if orchestration_filters_present {
        filter_orchestration_audit_result(
            result,
            orchestration_status.as_deref(),
            correction_kind.as_deref(),
            phase.as_deref(),
            limit,
            reveal_payloads,
        )?
    } else {
        result
    };
    record_admin_audit(
        deps,
        invocation,
        "capability.audit_query",
        json!({
            "eventType": event_type,
            "traceId": trace_id,
            "orchestrationStatus": orchestration_status,
            "correctionKind": correction_kind,
            "phase": phase,
            "limit": limit,
            "revealPayloads": reveal_payloads,
        }),
    )
    .await?;
    Ok(result)
}

pub(super) fn filter_orchestration_audit_result(
    result: Value,
    orchestration_status: Option<&str>,
    correction_kind: Option<&str>,
    phase: Option<&str>,
    limit: usize,
    reveal_payloads: bool,
) -> Result<Value, CapabilityError> {
    let events = result
        .get("events")
        .and_then(Value::as_array)
        .ok_or_else(|| CapabilityError::Internal {
            message: "capability audit query returned invalid events".to_owned(),
        })?;
    let mut filtered = Vec::new();
    for event in events {
        if !audit_event_matches_orchestration_filters(
            event,
            orchestration_status,
            correction_kind,
            phase,
        ) {
            continue;
        }
        let event = if reveal_payloads {
            let mut event = event.clone();
            event["redacted"] = json!(false);
            event
        } else {
            redact_orchestration_audit_event(event.clone())
        };
        filtered.push(event);
        if filtered.len() >= limit {
            break;
        }
    }
    Ok(json!({
        "events": filtered,
        "redacted": !reveal_payloads,
        "filters": {
            "orchestrationStatus": orchestration_status,
            "correctionKind": correction_kind,
            "phase": phase,
        }
    }))
}

pub(super) fn audit_event_matches_orchestration_filters(
    event: &Value,
    orchestration_status: Option<&str>,
    correction_kind: Option<&str>,
    phase: Option<&str>,
) -> bool {
    let payload = event.get("payload").unwrap_or(&Value::Null);
    if let Some(expected) = orchestration_status
        && payload.get("status").and_then(Value::as_str) != Some(expected)
    {
        return false;
    }
    if let Some(expected) = phase
        && payload
            .get("phaseDetails")
            .and_then(|details| details.get("phase"))
            .and_then(Value::as_str)
            != Some(expected)
    {
        return false;
    }
    if let Some(expected) = correction_kind {
        let has_correction = payload
            .get("correctionsApplied")
            .and_then(Value::as_array)
            .is_some_and(|corrections| {
                corrections.iter().any(|correction| {
                    correction.get("kind").and_then(Value::as_str) == Some(expected)
                })
            });
        if !has_correction {
            return false;
        }
    }
    true
}

fn redact_orchestration_audit_event(mut event: Value) -> Value {
    let payload = event.get("payload").cloned().unwrap_or(Value::Null);
    let keys = payload
        .as_object()
        .map(|object| object.keys().cloned().collect::<Vec<_>>())
        .unwrap_or_default();
    event["payloadSummary"] = orchestration_audit_payload_summary(&payload);
    event["payload"] = json!({
        "redacted": true,
        "keys": keys,
    });
    event["redacted"] = json!(true);
    event
}

fn orchestration_audit_payload_summary(payload: &Value) -> Value {
    let Some(object) = payload.as_object() else {
        return json!({ "type": audit_payload_type(payload) });
    };
    let mut summary = Map::new();
    for key in [
        "orchestrationId",
        "status",
        "intent",
        "correctionConfidence",
    ] {
        if let Some(value) = object.get(key) {
            summary.insert(key.to_owned(), value.clone());
        }
    }
    if let Some(phase) = object
        .get("phaseDetails")
        .and_then(|details| details.get("phase"))
        .cloned()
    {
        summary.insert("phase".to_owned(), phase);
    }
    let correction_kinds = object
        .get("correctionsApplied")
        .and_then(Value::as_array)
        .map(|corrections| {
            corrections
                .iter()
                .filter_map(|correction| correction.get("kind").and_then(Value::as_str))
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();
    if !correction_kinds.is_empty() {
        summary.insert("correctionKinds".to_owned(), json!(correction_kinds));
    }
    summary.insert("keyCount".to_owned(), json!(object.len()));
    Value::Object(summary)
}

fn audit_payload_type(payload: &Value) -> &'static str {
    match payload {
        Value::Null => "null",
        Value::Bool(_) => "boolean",
        Value::Number(_) => "number",
        Value::String(_) => "string",
        Value::Array(_) => "array",
        Value::Object(_) => "object",
    }
}
