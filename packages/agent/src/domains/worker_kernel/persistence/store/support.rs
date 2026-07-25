//! Stateless validation, atomic JSON publication, SQL codecs, row mappings,
//! hashing, and token generation shared by store concerns.

use super::*;

pub(super) use super::super::filesystem::{tree_version, write_json_atomic};

pub(super) fn validate_object_schema(schema: &Value, field: &'static str) -> Result<(), String> {
    if !schema.is_object() || schema.get("type").and_then(Value::as_str) != Some("object") {
        return Err(format!("{field} must be a JSON object schema"));
    }
    let function_id = crate::engine::FunctionId::new("worker_kernel::bundle_schema")
        .map_err(|error| error.to_string())?;
    crate::engine::validate_engine_schema_definition(&function_id, field, schema)
        .map_err(|error| format!("invalid {field}: {error}"))
}

pub(super) fn validate_command(command: &[String]) -> Result<(), String> {
    if command.is_empty() || command[0].trim().is_empty() {
        return Err("worker command must contain a program".to_owned());
    }
    Ok(())
}

pub(super) fn validate_worker_command(command: &WorkerCommand, field: &str) -> Result<(), String> {
    validate_command(&command.command)?;
    if command.timeout_seconds == 0 || command.timeout_seconds > MAX_INVOCATION_SECONDS {
        return Err(format!(
            "worker {field} timeoutSeconds must be between 1 and {}",
            MAX_INVOCATION_SECONDS
        ));
    }
    Ok(())
}

pub(super) fn validate_resident_url(value: &str, field: &str) -> Result<(), String> {
    let url = url::Url::parse(value).map_err(|error| format!("resident {field}: {error}"))?;
    if !matches!(url.scheme(), "http" | "https") {
        return Err(format!("resident {field} must use http or https"));
    }
    let loopback = match url.host() {
        Some(url::Host::Domain(domain)) => domain.eq_ignore_ascii_case("localhost"),
        Some(url::Host::Ipv4(address)) => address.is_loopback(),
        Some(url::Host::Ipv6(address)) => address.is_loopback(),
        None => false,
    };
    if !loopback {
        return Err(format!("resident {field} must target a loopback host"));
    }
    Ok(())
}

pub(super) fn validate_identifier(value: &str, field: &str) -> Result<(), String> {
    if value.is_empty()
        || value.len() > 96
        || !value
            .chars()
            .all(|character| character.is_ascii_alphanumeric() || matches!(character, '-' | '_'))
    {
        return Err(format!(
            "{field} must contain only ASCII letters, numbers, '-' or '_'"
        ));
    }
    Ok(())
}

pub(super) fn validate_content_version(value: &str) -> Result<(), String> {
    if value.len() != 64 || !value.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        return Err("worker version must be a 64-character hexadecimal content hash".to_owned());
    }
    Ok(())
}

pub(super) fn validate_runtime_identifier(
    value: &str,
    field: &str,
    max: usize,
) -> Result<(), String> {
    if value.trim().is_empty() || value.len() > max || value.chars().any(char::is_control) {
        return Err(format!(
            "worker {field} must be non-empty, at most {max} characters, and contain no control characters"
        ));
    }
    Ok(())
}

pub(super) fn normalize_tool_name(value: &str) -> Result<String, String> {
    let mut value = value.replace('-', "_");
    if !value.starts_with("worker_") {
        value = format!("worker_{value}");
    }
    validate_identifier(&value, "toolName")?;
    Ok(value)
}

pub(super) fn safe_relative_path(value: &str) -> Result<PathBuf, String> {
    let path = Path::new(value);
    if path.is_absolute() || value.is_empty() {
        return Err(format!("worker file path '{value}' must be relative"));
    }
    if path.components().any(|component| {
        matches!(
            component,
            Component::ParentDir | Component::RootDir | Component::Prefix(_)
        )
    }) {
        return Err(format!("worker file path '{value}' escapes its bundle"));
    }
    Ok(path.to_path_buf())
}

pub(super) fn slug(value: &str) -> String {
    let mut result = String::new();
    let mut separator = false;
    for character in value.chars() {
        if character.is_ascii_alphanumeric() {
            if separator && !result.is_empty() {
                result.push('-');
            }
            result.push(character.to_ascii_lowercase());
            separator = false;
        } else {
            separator = true;
        }
    }
    if result.is_empty() {
        format!("worker-{}", &uuid::Uuid::now_v7().to_string()[..8])
    } else {
        result.truncate(80);
        result
    }
}

pub(super) fn terms(value: &str) -> HashSet<String> {
    value
        .split(|character: char| !character.is_ascii_alphanumeric())
        .map(str::to_ascii_lowercase)
        .filter(|term| term.len() > 2 || term.chars().all(|character| character.is_ascii_digit()))
        .collect()
}

pub(super) fn jaccard(left: &HashSet<String>, right: &HashSet<String>) -> f64 {
    let union = left.union(right).count();
    if union == 0 {
        0.0
    } else {
        left.intersection(right).count() as f64 / union as f64
    }
}

pub(super) fn replace_active_triggers(
    connection: &Connection,
    worker_id: &str,
    triggers: &[WorkerTrigger],
    enabled: bool,
    new_webhooks: &mut Vec<WebhookCredential>,
) -> Result<(), String> {
    let prior = {
        let mut statement = connection
            .prepare(
                "SELECT trigger_id,kind,token_hash,next_run_at,stream_cursor
                 FROM worker_triggers WHERE worker_id=?1",
            )
            .map_err(|error| error.to_string())?;
        statement
            .query_map([worker_id], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    (
                        row.get::<_, String>(1)?,
                        row.get::<_, Option<String>>(2)?,
                        row.get::<_, Option<String>>(3)?,
                        row.get::<_, i64>(4)?,
                    ),
                ))
            })
            .map_err(|error| error.to_string())?
            .collect::<rusqlite::Result<HashMap<_, _>>>()
            .map_err(|error| error.to_string())?
    };
    connection
        .execute(
            "DELETE FROM worker_triggers WHERE worker_id=?1",
            [worker_id],
        )
        .map_err(|error| format!("replace worker triggers: {error}"))?;
    for trigger in triggers {
        let matching = prior
            .get(trigger.id())
            .filter(|(kind, _, _, _)| kind == trigger.kind());
        let mut token_hash = matching.and_then(|(_, token, _, _)| token.clone());
        if matches!(trigger, WorkerTrigger::Webhook { .. }) && token_hash.is_none() {
            let token = generate_token();
            token_hash = Some(hash_secret(&token));
            new_webhooks.push(WebhookCredential {
                trigger_id: trigger.id().to_owned(),
                path: format!("/engine/webhooks/workers/{worker_id}/{}", trigger.id()),
                token,
            });
        }
        let next_run_at = match trigger {
            WorkerTrigger::Schedule { every_seconds, .. } => matching
                .and_then(|(_, _, next, _)| next.clone())
                .or_else(|| {
                    Some(
                        (chrono::Utc::now()
                            + chrono::Duration::seconds(
                                i64::try_from(*every_seconds).unwrap_or(i64::MAX),
                            ))
                        .to_rfc3339(),
                    )
                }),
            _ => None,
        };
        let stream_cursor = if matches!(trigger, WorkerTrigger::EngineEvent { .. }) {
            matching.map_or(0, |(_, _, _, cursor)| *cursor)
        } else {
            0
        };
        connection
            .execute(
                "INSERT INTO worker_triggers(worker_id,trigger_id,kind,config_json,token_hash,next_run_at,stream_cursor,enabled)
                 VALUES (?1,?2,?3,?4,?5,?6,?7,?8)",
                params![
                    worker_id,
                    trigger.id(),
                    trigger.kind(),
                    serde_json::to_string(trigger).map_err(|error| error.to_string())?,
                    token_hash,
                    next_run_at,
                    stream_cursor,
                    i64::from(enabled),
                ],
            )
            .map_err(|error| format!("insert worker trigger '{}': {error}", trigger.id()))?;
    }
    Ok(())
}

pub(super) fn insert_audit(
    connection: &Connection,
    worker_id: &str,
    action: &str,
    details: &Value,
) -> Result<(), String> {
    connection
        .execute(
            "INSERT INTO worker_audit(audit_id,worker_id,action,details_json,created_at)
             VALUES (?1,?2,?3,?4,?5)",
            params![
                format!("worker_audit_{}", uuid::Uuid::now_v7()),
                worker_id,
                action,
                serde_json::to_string(details).map_err(|error| error.to_string())?,
                chrono::Utc::now().to_rfc3339(),
            ],
        )
        .map_err(|error| format!("record worker audit action '{action}': {error}"))?;
    Ok(())
}

pub(super) fn insert_health(
    connection: &Connection,
    worker_id: &str,
    worker_version: &str,
    status: &str,
    source: &str,
    details: &Value,
) -> Result<(), String> {
    connection
        .execute(
            "INSERT INTO worker_health(health_id,worker_id,worker_version,status,source,details_json,recorded_at)
             VALUES (?1,?2,?3,?4,?5,?6,?7)",
            params![
                format!("worker_health_{}", uuid::Uuid::now_v7()),
                worker_id,
                worker_version,
                status,
                source,
                serde_json::to_string(details).map_err(|error| error.to_string())?,
                chrono::Utc::now().to_rfc3339(),
            ],
        )
        .map_err(|error| format!("record worker health: {error}"))?;
    Ok(())
}

pub(super) fn upsert_causal_trace(
    connection: &Connection,
    trace_id: &str,
    invocation_id: Option<&str>,
    causal_depth: u32,
    suppressed: bool,
) -> Result<(), String> {
    let now = chrono::Utc::now().to_rfc3339();
    connection
        .execute(
            "INSERT INTO worker_causal_traces(trace_id,root_invocation_id,max_causal_depth,
                invocation_count,suppressed_count,first_seen_at,last_seen_at)
             VALUES (?1,?2,?3,?4,?5,?6,?6)
             ON CONFLICT(trace_id) DO UPDATE SET
                root_invocation_id=COALESCE(worker_causal_traces.root_invocation_id,excluded.root_invocation_id),
                max_causal_depth=MAX(worker_causal_traces.max_causal_depth,excluded.max_causal_depth),
                invocation_count=worker_causal_traces.invocation_count+excluded.invocation_count,
                suppressed_count=worker_causal_traces.suppressed_count+excluded.suppressed_count,
                last_seen_at=excluded.last_seen_at",
            params![
                trace_id,
                invocation_id,
                causal_depth,
                i64::from(!suppressed),
                i64::from(suppressed),
                now,
            ],
        )
        .map_err(|error| format!("record worker causal trace: {error}"))?;
    Ok(())
}

pub(super) fn row_summary(row: &rusqlite::Row<'_>) -> rusqlite::Result<WorkerSummary> {
    Ok(WorkerSummary {
        worker_id: row.get(0)?,
        name: row.get(1)?,
        description: row.get(2)?,
        tool_name: row.get(3)?,
        runner_kind: row.get(4)?,
        active_version: row.get(5)?,
        enabled: row.get::<_, i64>(6)? != 0,
        retired: row.get::<_, i64>(7)? != 0,
        health: row.get(8)?,
        updated_at: row.get(9)?,
        trigger_count: row.get(10)?,
        presentation: row
            .get::<_, Option<String>>(11)?
            .and_then(|value| serde_json::from_str(&value).ok()),
    })
}

pub(super) fn inbox_context_candidate(row: &rusqlite::Row<'_>) -> rusqlite::Result<Value> {
    const MAX_RESULT_PREVIEW_BYTES: usize = 4_096;
    let result_json = row.get::<_, String>(4)?;
    let result_preview = serde_json::from_str::<Value>(&result_json)
        .ok()
        .and_then(|result| {
            result
                .get("preview")
                .or_else(|| result.get("error"))
                .and_then(Value::as_str)
                .map(ToOwned::to_owned)
        })
        .unwrap_or_else(|| result_json.clone());
    Ok(json!({
        "inboxId":row.get::<_, String>(0)?,
        "invocationId":row.get::<_, String>(1)?,
        "workerId":row.get::<_, String>(2)?,
        "severity":row.get::<_, String>(3)?,
        "resultPreview":crate::shared::foundation::text::truncate_with_suffix(
            &result_preview,
            MAX_RESULT_PREVIEW_BYTES,
            "...",
        ),
        "createdAt":row.get::<_, String>(5)?,
        "triggerKind":row.get::<_, String>(6)?,
        "workerName":row.get::<_, String>(7)?,
        "workerDescription":row.get::<_, String>(8)?,
    }))
}

pub(super) fn invocation_select(condition: &str) -> String {
    format!("{} {condition}", invocation_select_base())
}

pub(super) fn invocation_select_base() -> &'static str {
    "SELECT worker_invocations.invocation_id,worker_invocations.worker_id,
            worker_invocations.worker_version,worker_invocations.status,
            worker_invocations.input_json,worker_invocations.output_json,
            worker_invocations.error,worker_invocations.idempotency_key,
            worker_invocations.trace_id,worker_invocations.causal_depth,
            worker_invocations.trigger_kind,worker_invocations.origin_session_id,
            worker_invocations.agent_session_id,
            worker_invocations.interaction_mode,worker_invocations.detached_at,
            worker_invocations.model_tool_invocation_id,
            worker_invocations.parent_worker_invocation_id,
            worker_invocations.retry_of_invocation_id,
            (SELECT COUNT(*) FROM worker_attempts a
                WHERE a.invocation_id=worker_invocations.invocation_id),
            worker_invocations.created_at,
            worker_invocations.started_at,worker_invocations.completed_at
     FROM worker_invocations"
}

pub(super) fn row_invocation(
    connection: &Connection,
    row: &rusqlite::Row<'_>,
) -> rusqlite::Result<InvocationRecord> {
    row_invocation_with_output(connection, row, InvocationOutputProjection::Exact)
}

pub(super) fn row_invocation_reference(
    connection: &Connection,
    row: &rusqlite::Row<'_>,
) -> rusqlite::Result<InvocationRecord> {
    row_invocation_with_output(connection, row, InvocationOutputProjection::Reference)
}

#[derive(Clone, Copy)]
enum InvocationOutputProjection {
    Exact,
    Reference,
}

fn row_invocation_with_output(
    connection: &Connection,
    row: &rusqlite::Row<'_>,
    output_projection: InvocationOutputProjection,
) -> rusqlite::Result<InvocationRecord> {
    let input: String = row.get(4)?;
    let output: Option<String> = row.get(5)?;
    let invocation_id = row.get::<_, String>(0)?;
    let output = output
        .as_deref()
        .map(|value| match output_projection {
            InvocationOutputProjection::Exact => {
                super::results::resolve_stored_result(connection, &invocation_id, value)
            }
            InvocationOutputProjection::Reference => {
                super::results::result_reference_from_connection(connection, &invocation_id)
            }
        })
        .map(|result| result.map_err(result_projection_error))
        .transpose()?;
    Ok(InvocationRecord {
        invocation_id,
        worker_id: row.get(1)?,
        worker_version: row.get(2)?,
        status: row.get(3)?,
        input: serde_json::from_str(&input).unwrap_or(Value::Null),
        output,
        error: row.get(6)?,
        idempotency_key: row.get(7)?,
        trace_id: row.get(8)?,
        causal_depth: row.get(9)?,
        trigger_kind: row.get(10)?,
        origin_session_id: row.get(11)?,
        agent_session_id: row.get(12)?,
        interaction_mode: match row.get::<_, String>(13)?.as_str() {
            "background" => WorkerInteractionMode::Background,
            _ => WorkerInteractionMode::Foreground,
        },
        detached_at: row.get(14)?,
        model_tool_invocation_id: row.get(15)?,
        parent_worker_invocation_id: row.get(16)?,
        retry_of_invocation_id: row.get(17)?,
        attempt_count: row.get(18)?,
        created_at: row.get(19)?,
        started_at: row.get(20)?,
        completed_at: row.get(21)?,
    })
}

fn result_projection_error(error: String) -> rusqlite::Error {
    rusqlite::Error::FromSqlConversionFailure(
        5,
        rusqlite::types::Type::Text,
        Box::new(std::io::Error::other(error)),
    )
}

pub(super) fn insert_run_event(
    transaction: &rusqlite::Transaction<'_>,
    invocation_id: &str,
    stage: WorkerRunStage,
    summary: &str,
    occurred_at: &str,
) -> Result<(), String> {
    transaction
        .execute(
            "INSERT INTO worker_run_events(
                event_id,invocation_id,sequence,stage,summary,occurred_at
             )
             VALUES (
                ?1,?2,
                (SELECT COALESCE(MAX(sequence),0)+1
                 FROM worker_run_events WHERE invocation_id=?2),
                ?3,?4,?5
             )",
            params![
                format!("worker_event_{}", uuid::Uuid::now_v7()),
                invocation_id,
                stage.as_str(),
                summary,
                occurred_at,
            ],
        )
        .map_err(|error| format!("record worker run stage: {error}"))?;
    Ok(())
}

pub(super) fn generate_token() -> String {
    let mut bytes = [0_u8; 32];
    rand::rng().fill_bytes(&mut bytes);
    format!("trwh_{}", hex::encode(bytes))
}

pub(super) fn hash_secret(value: &str) -> String {
    hex::encode(Sha256::digest(value.as_bytes()))
}
