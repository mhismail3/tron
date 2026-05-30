use rusqlite::{Connection, params};
use serde_json::{Value, json};

pub(super) fn query_json_column(conn: &Connection, sql: &str) -> Result<Vec<Value>, String> {
    let mut stmt = conn
        .prepare(sql)
        .map_err(|error| format!("prepare json query: {error}"))?;
    let rows = stmt
        .query_map([], |row| row.get::<_, String>(0))
        .map_err(|error| format!("query json rows: {error}"))?;
    let mut values = Vec::new();
    for row in rows {
        let raw = row.map_err(|error| format!("read json row: {error}"))?;
        values
            .push(serde_json::from_str(&raw).map_err(|error| format!("decode json row: {error}"))?);
    }
    Ok(values)
}

pub(super) fn query_bindings(conn: &Connection) -> Result<Vec<Value>, String> {
    let mut stmt = conn
        .prepare(
            "SELECT contract_id, scope_kind, scope_value, selected_implementation,
                    selection_policy, secondary_implementations_json, enabled, priority, updated_at
             FROM capability_bindings
             ORDER BY scope_kind, scope_value, contract_id, priority DESC",
        )
        .map_err(|error| format!("prepare binding query: {error}"))?;
    let rows = stmt
        .query_map([], |row| {
            let secondary_json: String = row.get(5)?;
            Ok(json!({
                "contractId": row.get::<_, String>(0)?,
                "scopeKind": row.get::<_, String>(1)?,
                "scopeValue": row.get::<_, String>(2)?,
                "selectedImplementation": row.get::<_, String>(3)?,
                "selectionPolicy": row.get::<_, String>(4)?,
                "secondaryImplementations": serde_json::from_str::<Value>(&secondary_json).unwrap_or_else(|_| json!([])),
                "enabled": row.get::<_, i64>(6)? == 1,
                "priority": row.get::<_, i64>(7)?,
                "updatedAt": row.get::<_, String>(8)?,
            }))
        })
        .map_err(|error| format!("query capability bindings: {error}"))?;
    collect_value_rows(rows)
}

pub(super) fn query_implementations(conn: &Connection) -> Result<Vec<Value>, String> {
    let mut stmt = conn
        .prepare(
            "SELECT implementation_id, contract_id, function_id, plugin_id, worker_id,
                    schema_digest, catalog_revision, trust_tier, health, visibility,
                    conformance_state, signature_status, updated_at
             FROM capability_implementations
             ORDER BY contract_id, implementation_id",
        )
        .map_err(|error| format!("prepare implementation query: {error}"))?;
    let rows = stmt
        .query_map([], implementation_row)
        .map_err(|error| format!("query implementations: {error}"))?;
    collect_value_rows(rows)
}

pub(super) fn query_implementations_for_plugin(
    conn: &Connection,
    plugin_id: &str,
) -> Result<Vec<Value>, String> {
    let mut stmt = conn
        .prepare(
            "SELECT implementation_id, contract_id, function_id, plugin_id, worker_id,
                    schema_digest, catalog_revision, trust_tier, health, visibility,
                    conformance_state, signature_status, updated_at
             FROM capability_implementations
             WHERE plugin_id = ?1
             ORDER BY contract_id, implementation_id",
        )
        .map_err(|error| format!("prepare plugin implementation query: {error}"))?;
    let rows = stmt
        .query_map(params![plugin_id], implementation_row)
        .map_err(|error| format!("query plugin implementations: {error}"))?;
    collect_value_rows(rows)
}

fn implementation_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<Value> {
    Ok(json!({
        "implementationId": row.get::<_, String>(0)?,
        "contractId": row.get::<_, String>(1)?,
        "functionId": row.get::<_, String>(2)?,
        "pluginId": row.get::<_, String>(3)?,
        "workerId": row.get::<_, String>(4)?,
        "schemaDigest": row.get::<_, String>(5)?,
        "catalogRevision": row.get::<_, i64>(6)?,
        "trustTier": row.get::<_, String>(7)?,
        "health": row.get::<_, String>(8)?,
        "visibility": row.get::<_, String>(9)?,
        "conformanceState": row.get::<_, String>(10)?,
        "signatureStatus": row.get::<_, String>(11)?,
        "updatedAt": row.get::<_, String>(12)?,
    }))
}

fn collect_value_rows<F>(rows: rusqlite::MappedRows<'_, F>) -> Result<Vec<Value>, String>
where
    F: FnMut(&rusqlite::Row<'_>) -> rusqlite::Result<Value>,
{
    let mut values = Vec::new();
    for row in rows {
        values.push(row.map_err(|error| format!("read value row: {error}"))?);
    }
    Ok(values)
}

pub(super) fn json_from_row(raw: String) -> Value {
    serde_json::from_str::<Value>(&raw).unwrap_or(Value::Null)
}

pub(super) fn redact_audit_event(mut event: Value, reveal_payloads: bool) -> Value {
    if reveal_payloads {
        event["redacted"] = json!(false);
        return event;
    }
    let payload = event.get("payload").cloned().unwrap_or(Value::Null);
    event["payloadSummary"] = audit_payload_summary(&payload);
    event["payload"] = json!({
        "redacted": true,
        "keys": payload.as_object()
            .map(|object| object.keys().cloned().collect::<Vec<_>>())
            .unwrap_or_default()
    });
    event["redacted"] = json!(true);
    event
}

pub(super) fn merge_record_payload(mut base: Value, extra: Value) -> Value {
    match (base.as_object_mut(), extra.as_object()) {
        (Some(base), Some(extra)) => {
            for (key, value) in extra {
                base.insert(key.clone(), value.clone());
            }
            Value::Object(base.clone())
        }
        _ => extra,
    }
}

pub(super) fn redact_program_run(mut run: Value, reveal_payloads: bool) -> Value {
    if reveal_payloads {
        run["redacted"] = json!(false);
        return run;
    }
    let log_count = run
        .get("logs")
        .and_then(Value::as_array)
        .map(Vec::len)
        .unwrap_or_default();
    let artifact_count = run
        .get("artifacts")
        .and_then(Value::as_array)
        .map(Vec::len)
        .unwrap_or_default();
    let compensation_count = run
        .get("compensationAttempts")
        .and_then(Value::as_array)
        .map(Vec::len)
        .unwrap_or_default();
    run["payloadSummary"] = json!({
        "programRunId": run.get("programRunId").cloned().unwrap_or(Value::Null),
        "status": run.get("status").cloned().unwrap_or(Value::Null),
        "traceId": run.get("traceId").cloned().unwrap_or(Value::Null),
        "parentInvocationId": run.get("parentInvocationId").cloned().unwrap_or(Value::Null),
        "rootInvocationId": run.get("rootInvocationId").cloned().unwrap_or(Value::Null),
        "bindingDecisionId": run.get("bindingDecisionId").cloned().unwrap_or(Value::Null),
        "codeHash": run.get("codeHash").cloned().unwrap_or(Value::Null),
        "argsHash": run.get("argsHash").cloned().unwrap_or(Value::Null),
        "childInvocations": run.get("childInvocations").cloned().unwrap_or_else(|| json!([])),
        "selectedImplementations": run.get("selectedImplementations").cloned().unwrap_or_else(|| json!([])),
        "approvalState": run.get("approvalState").cloned().unwrap_or(Value::Null),
        "logCount": log_count,
        "artifactCount": artifact_count,
        "compensationCount": compensation_count,
    });
    run["logs"] = json!({"redacted": true, "count": log_count});
    run["artifacts"] = json!({"redacted": true, "count": artifact_count});
    run["error"] = run
        .get("error")
        .cloned()
        .filter(|value| !value.is_null())
        .map(|error| audit_payload_summary(&error))
        .unwrap_or(Value::Null);
    run["compensationAttempts"] = json!({"redacted": true, "count": compensation_count});
    run["redacted"] = json!(true);
    run
}

fn audit_payload_summary(payload: &Value) -> Value {
    let Some(object) = payload.as_object() else {
        return json!({"type": payload_type(payload)});
    };
    let interesting = [
        "status",
        "contractId",
        "implementationId",
        "functionId",
        "pluginId",
        "workerId",
        "catalogRevision",
        "schemaDigest",
        "error",
    ];
    let mut summary = serde_json::Map::new();
    for key in interesting {
        if let Some(value) = object.get(key) {
            summary.insert(key.to_owned(), value.clone());
        }
    }
    summary.insert("keyCount".to_owned(), json!(object.len()));
    Value::Object(summary)
}

fn payload_type(payload: &Value) -> &'static str {
    match payload {
        Value::Null => "null",
        Value::Bool(_) => "boolean",
        Value::Number(_) => "number",
        Value::String(_) => "string",
        Value::Array(_) => "array",
        Value::Object(_) => "object",
    }
}
