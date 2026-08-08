//! Artifact-style references and bounded reads for durable worker results.
//!
//! The worker invocation ledger remains the sole result owner. Provider turns
//! receive a compact reference once a validated output crosses the engine's
//! established inline-payload boundary, and may read only the JSON path/page
//! they need. This module never interprets task-specific fields.

use super::*;

use crate::shared::protocol::model_tools::DEFAULT_MAX_INLINE_MODEL_TOOL_RESULT_BYTES;

const MAX_RESULT_READ_BYTES: usize = DEFAULT_MAX_INLINE_MODEL_TOOL_RESULT_BYTES * 4;
const MAX_RESULT_READ_ITEMS: usize = 20;

impl WorkerRuntime {
    /// Create a visible client task with authority to inspect one exact result.
    ///
    /// This is a custody operation, not worker routing: the result remains in
    /// the invocation ledger and the new session receives only a passive
    /// Agent Delivery grant plus a bounded reference summary.
    pub(crate) fn create_worker_result_handoff(
        &self,
        invocation: &Invocation,
        invocation_id: &str,
        working_directory: &str,
        model: &str,
        title: &str,
    ) -> Result<Value, String> {
        if invocation.causal_context.actor_kind != ActorKind::Client {
            return Err("worker result handoff requires an authenticated client".to_owned());
        }
        if !crate::domains::model::routing::catalog::is_model_supported(model) {
            return Err(format!("worker result handoff model '{model}' is unknown"));
        }
        if crate::domains::model::routing::catalog::is_model_retired(model) {
            return Err(format!("worker result handoff model '{model}' is retired"));
        }
        let working_directory =
            crate::shared::foundation::paths::normalize_working_directory(working_directory)?
                .display()
                .to_string();
        let record = self
            .store
            .invocation(invocation_id)?
            .ok_or_else(|| format!("worker invocation '{invocation_id}' was not found"))?;
        if record.status != "completed" {
            return Err(format!(
                "worker invocation '{invocation_id}' has no completed result to hand off"
            ));
        }
        let reference = self.result_reference(&record)?;
        let preview = reference
            .get("preview")
            .and_then(Value::as_str)
            .unwrap_or("Completed durable worker result");
        let content = format!(
            "A client attached the exact durable result from worker '{}' invocation '{}'. \
Use worker_result_read with that exact invocation id and bounded JSON pointers/pages when \
you need evidence. Do not ask the user to copy raw JSON. Result preview: {}",
            record.worker_id,
            record.invocation_id,
            crate::shared::foundation::text::truncate_str(preview, 1_000)
        );
        let idempotency_key = invocation
            .causal_context
            .idempotency_key
            .clone()
            .unwrap_or_else(|| format!("result-handoff:{}", invocation.id));
        let created = self
            .event_store
            .create_worker_result_task_with_delivery(
                &crate::domains::session::event_store::NewWorkerResultTaskDelivery {
                    idempotency_key,
                    title: title.to_owned(),
                    model: model.to_owned(),
                    working_directory,
                    result_invocation_id: record.invocation_id.clone(),
                    source_trace_id: Some(record.trace_id.clone()),
                    causal_depth: record.causal_depth,
                    content,
                },
            )
            .map_err(|error| error.to_string())?;
        let session = &created.session.session;
        if created.created {
            crate::domains::session::lifecycle::project_created_session(
                &self.orchestrator,
                self.host.clone(),
                &session.id,
                &session.latest_model,
                &session.working_directory,
                session.title.clone(),
            );
        }
        Ok(json!({
            "sessionId":session.id,
            "workspaceId":session.workspace_id,
            "model":session.latest_model,
            "workingDirectory":session.working_directory,
            "createdAt":session.created_at,
        }))
    }

    /// Project one terminal direct-worker output for a provider turn.
    ///
    /// The exact typed value remains durable and is returned inline while it is
    /// context-safe. Larger values become an integrity-bound reference.
    pub(super) fn provider_worker_output(
        &self,
        record: &InvocationRecord,
    ) -> Result<Value, String> {
        let output = record
            .output
            .as_ref()
            .ok_or_else(|| format!("worker invocation '{}' has no output", record.invocation_id))?;
        if serialized_size(output)? <= DEFAULT_MAX_INLINE_MODEL_TOOL_RESULT_BYTES {
            return Ok(output.clone());
        }
        self.result_reference(record)
    }

    /// Project a fixed worker-control response with a result reference for
    /// every successful output size. Exact direct-worker delivery is owned by
    /// the one-turn agent projection; fixed control records never copy it.
    pub(crate) fn provider_invocation_record(
        &self,
        record: InvocationRecord,
    ) -> Result<Value, String> {
        let reference = record
            .output
            .as_ref()
            .map(|_| self.result_reference(&record))
            .transpose()?;
        let mut projected = serde_json::to_value(record).map_err(|error| error.to_string())?;
        if let Some(reference) = reference {
            projected["output"] = reference;
        }
        Ok(projected)
    }

    /// Read one bounded path/page from an exact durable worker result.
    pub(crate) fn read_worker_result(
        &self,
        invocation: &Invocation,
        invocation_id: &str,
        pointer: &str,
        offset: usize,
        limit: usize,
    ) -> Result<Value, String> {
        let record = self
            .store
            .invocation(invocation_id)?
            .ok_or_else(|| format!("worker invocation '{invocation_id}' was not found"))?;
        self.authorize_result_read(invocation, &record)?;
        if record.status != "completed" {
            return Err(format!(
                "worker invocation '{invocation_id}' is not completed"
            ));
        }
        let output = self
            .store
            .resolve_result(invocation_id)?
            .ok_or_else(|| format!("worker invocation '{invocation_id}' has no output"))?;
        validate_pointer(pointer)?;
        let selected = output.pointer(pointer).ok_or_else(|| {
            format!(
                "JSON pointer '{}' does not exist in worker invocation '{invocation_id}'",
                display_pointer(pointer)
            )
        })?;
        let page = project_result_page(
            selected,
            pointer,
            offset,
            limit.clamp(1, MAX_RESULT_READ_ITEMS),
        )?;
        Ok(json!({
            "kind":"worker_result_chunk",
            "reference":self.result_reference(&record)?,
            "pointer":pointer,
            "value":page.value,
            "children":page.children,
            "offset":offset,
            "returned":page.returned,
            "total":page.total,
            "nextOffset":page.next_offset,
            "truncated":page.truncated,
        }))
    }

    fn result_reference(&self, record: &InvocationRecord) -> Result<Value, String> {
        self.store
            .result_reference(&record.invocation_id)?
            .ok_or_else(|| {
                format!(
                    "worker invocation '{}' has no durable result reference",
                    record.invocation_id
                )
            })
    }

    fn authorize_result_read(
        &self,
        invocation: &Invocation,
        record: &InvocationRecord,
    ) -> Result<(), String> {
        // INVARIANT: authenticated operator clients and engine-owned recovery
        // may inspect profile-local worker results. An agent worker may read
        // only a direct child it durably admitted. Other agent and worker
        // callers remain constrained to the originating session or an
        // explicit Agent Delivery grant.
        if matches!(
            invocation.causal_context.actor_kind,
            ActorKind::Client | ActorKind::System
        ) {
            return Ok(());
        }
        if invocation
            .causal_context
            .origin_worker_invocation_id()
            .is_some_and(|parent_id| {
                record.parent_worker_invocation_id.as_deref() == Some(parent_id)
            })
        {
            return Ok(());
        }
        let Some(session_id) = invocation.causal_context.session_id.as_deref() else {
            return Err(format!(
                "worker result '{}' requires an originating-session or delivery-granted session",
                record.invocation_id
            ));
        };
        if record.origin_session_id.as_deref() == Some(session_id)
            || self
                .event_store
                .session_has_agent_result_grant(session_id, &record.invocation_id)
                .unwrap_or(false)
        {
            return Ok(());
        }
        Err(format!(
            "worker result '{}' is outside the caller's originating session or delivery grant",
            record.invocation_id
        ))
    }
}

#[derive(Debug)]
struct ResultPage {
    value: Value,
    children: Vec<Value>,
    returned: usize,
    total: usize,
    next_offset: Option<usize>,
    truncated: bool,
}

fn project_result_page(
    selected: &Value,
    pointer: &str,
    offset: usize,
    limit: usize,
) -> Result<ResultPage, String> {
    match selected {
        Value::Array(values) => project_array_page(values, pointer, offset, limit),
        Value::Object(values) if serialized_size(selected)? > MAX_RESULT_READ_BYTES => {
            let entries = values.iter().collect::<Vec<_>>();
            let end = offset.saturating_add(limit).min(entries.len());
            let children = entries
                .get(offset..end)
                .unwrap_or_default()
                .iter()
                .map(|(key, value)| child_descriptor(pointer, key, value))
                .collect::<Result<Vec<_>, _>>()?;
            Ok(ResultPage {
                value: Value::Null,
                returned: children.len(),
                total: entries.len(),
                next_offset: (end < entries.len()).then_some(end),
                truncated: true,
                children,
            })
        }
        Value::String(text) if text.len() > MAX_RESULT_READ_BYTES => {
            Ok(project_string_page(text, offset))
        }
        value => Ok(ResultPage {
            value: value.clone(),
            children: Vec::new(),
            returned: 1,
            total: 1,
            next_offset: None,
            truncated: false,
        }),
    }
}

fn project_array_page(
    values: &[Value],
    pointer: &str,
    offset: usize,
    limit: usize,
) -> Result<ResultPage, String> {
    let mut page = Vec::new();
    let mut bytes = 2_usize;
    let end_limit = offset.saturating_add(limit).min(values.len());
    for value in values.get(offset..end_limit).unwrap_or_default() {
        let value_bytes = serialized_size(value)?;
        if bytes.saturating_add(value_bytes).saturating_add(1) > MAX_RESULT_READ_BYTES {
            break;
        }
        bytes = bytes.saturating_add(value_bytes).saturating_add(1);
        page.push(value.clone());
    }
    if page.is_empty() && offset < values.len() {
        let end = end_limit.max(offset.saturating_add(1)).min(values.len());
        let children = (offset..end)
            .map(|index| child_descriptor(pointer, &index.to_string(), &values[index]))
            .collect::<Result<Vec<_>, _>>()?;
        return Ok(ResultPage {
            value: Value::Null,
            returned: children.len(),
            total: values.len(),
            next_offset: (end < values.len()).then_some(end),
            truncated: true,
            children,
        });
    }
    let end = offset.saturating_add(page.len());
    Ok(ResultPage {
        value: Value::Array(page),
        children: Vec::new(),
        returned: end.saturating_sub(offset),
        total: values.len(),
        next_offset: (end < values.len()).then_some(end),
        truncated: end < values.len(),
    })
}

fn project_string_page(text: &str, offset: usize) -> ResultPage {
    let characters = text.chars().collect::<Vec<_>>();
    let mut chunk = String::new();
    for character in characters.iter().skip(offset) {
        if chunk.len().saturating_add(character.len_utf8()) > MAX_RESULT_READ_BYTES {
            break;
        }
        chunk.push(*character);
    }
    let end = offset.saturating_add(chunk.chars().count());
    ResultPage {
        value: Value::String(chunk),
        children: Vec::new(),
        returned: end.saturating_sub(offset),
        total: characters.len(),
        next_offset: (end < characters.len()).then_some(end),
        truncated: end < characters.len(),
    }
}

fn child_descriptor(pointer: &str, key: &str, value: &Value) -> Result<Value, String> {
    let escaped = key.replace('~', "~0").replace('/', "~1");
    let child_pointer = if pointer.is_empty() {
        format!("/{escaped}")
    } else {
        format!("{pointer}/{escaped}")
    };
    Ok(json!({
        "pointer":child_pointer,
        "type":value_type(value),
        "sizeBytes":serialized_size(value)?,
        "preview":run_projection_format::preview_result(value),
    }))
}

fn validate_pointer(pointer: &str) -> Result<(), String> {
    if pointer.len() > 2_048 {
        return Err("worker result JSON pointer exceeds 2048 bytes".to_owned());
    }
    if pointer.is_empty() || pointer.starts_with('/') {
        return Ok(());
    }
    Err("worker result JSON pointer must be empty or start with '/'".to_owned())
}

fn display_pointer(pointer: &str) -> &str {
    if pointer.is_empty() {
        "<root>"
    } else {
        pointer
    }
}

fn serialized_size(value: &Value) -> Result<usize, String> {
    serde_json::to_vec(value)
        .map(|bytes| bytes.len())
        .map_err(|error| error.to_string())
}

fn value_type(value: &Value) -> &'static str {
    match value {
        Value::Null => "null",
        Value::Bool(_) => "boolean",
        Value::Number(_) => "number",
        Value::String(_) => "string",
        Value::Array(_) => "array",
        Value::Object(_) => "object",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn large_objects_project_children_before_payload() {
        let value = json!({
            "large":"x".repeat(MAX_RESULT_READ_BYTES + 1),
            "small":"ok",
        });
        let page = project_result_page(&value, "", 0, 10).unwrap();
        assert!(page.value.is_null());
        assert_eq!(page.children.len(), 2);
        assert!(
            page.children
                .iter()
                .any(|child| child["pointer"] == "/small")
        );
        assert!(page.truncated);
    }

    #[test]
    fn array_pages_never_cross_the_read_budget() {
        let value = Value::Array(vec![
            json!({"id":"one","value":"x".repeat(MAX_RESULT_READ_BYTES / 2)}),
            json!({"id":"two","value":"x".repeat(MAX_RESULT_READ_BYTES / 2)}),
            json!({"id":"three"}),
        ]);
        let page = project_result_page(&value, "/items", 0, 20).unwrap();
        assert_eq!(page.returned, 1);
        assert_eq!(page.next_offset, Some(1));
        assert!(serialized_size(&page.value).unwrap() <= MAX_RESULT_READ_BYTES);
    }

    #[test]
    fn json_pointer_requires_rfc6901_root_shape() {
        assert!(validate_pointer("").is_ok());
        assert!(validate_pointer("/sources/0").is_ok());
        assert!(validate_pointer("sources/0").is_err());
    }
}
