//! Primitive agent-state context projection.

use serde_json::{Value, json};
use tracing::warn;

const AGENT_STATE_NAMESPACE: &str = "agent";
const AGENT_STATE_CONTEXT_LIMIT: usize = 40;

pub(super) async fn load_agent_state_context(
    engine_host: &crate::engine::EngineHostHandle,
    session_id: &str,
    workspace_id: Option<&str>,
) -> Option<String> {
    let mut sections = Vec::new();

    if let Some(workspace_id) = workspace_id {
        if let Some(section) = list_state_scope(
            engine_host,
            "workspace",
            Some(session_id),
            Some(workspace_id),
        )
        .await
        {
            sections.push(section);
        }
    }

    if let Some(section) =
        list_state_scope(engine_host, "session", Some(session_id), workspace_id).await
    {
        sections.push(section);
    }

    if sections.is_empty() {
        None
    } else {
        Some(format!("## Agent-owned state\n\n{}", sections.join("\n\n")))
    }
}

async fn list_state_scope(
    engine_host: &crate::engine::EngineHostHandle,
    scope: &str,
    session_id: Option<&str>,
    workspace_id: Option<&str>,
) -> Option<String> {
    let mut payload = json!({
        "scope": scope,
        "namespace": AGENT_STATE_NAMESPACE,
        "limit": AGENT_STATE_CONTEXT_LIMIT,
    });
    if let Some(session_id) = session_id {
        payload["sessionId"] = json!(session_id);
    }
    if let Some(workspace_id) = workspace_id {
        payload["workspaceId"] = json!(workspace_id);
    }
    let value = invoke_state_list(engine_host, payload, session_id, workspace_id).await?;
    let entries = value.get("entries")?.as_array()?;
    if entries.is_empty() {
        return None;
    }
    let lines = entries
        .iter()
        .filter_map(format_state_entry)
        .collect::<Vec<_>>();
    if lines.is_empty() {
        None
    } else {
        Some(format!("### {scope} scope\n\n{}", lines.join("\n")))
    }
}

async fn invoke_state_list(
    engine_host: &crate::engine::EngineHostHandle,
    payload: Value,
    session_id: Option<&str>,
    workspace_id: Option<&str>,
) -> Option<Value> {
    let mut causal = crate::engine::CausalContext::new(
        crate::engine::ActorId::new("system:agent-state-context").ok()?,
        crate::engine::ActorKind::System,
        crate::engine::AuthorityGrantId::new("engine-system").ok()?,
        crate::engine::TraceId::new("agent-state-context").ok()?,
    )
    .with_scope("state.read")
    .with_idempotency_key("agent-state-context");
    if let Some(session_id) = session_id {
        causal = causal.with_session_id(session_id);
    }
    if let Some(workspace_id) = workspace_id {
        causal = causal.with_workspace_id(workspace_id);
    }
    let result = engine_host
        .invoke(crate::engine::Invocation::new_sync(
            crate::engine::FunctionId::new("state::list").ok()?,
            payload,
            causal,
        ))
        .await;
    if let Some(error) = result.error {
        warn!(error = %error, "failed to load agent-owned state context");
        return None;
    }
    result.value
}

fn format_state_entry(entry: &Value) -> Option<String> {
    let key = entry.get("key").and_then(Value::as_str)?;
    let revision = entry.get("revision").and_then(Value::as_u64).unwrap_or(0);
    let value = entry.get("value").cloned().unwrap_or(Value::Null);
    Some(format!(
        "- `{key}` rev {revision}: {}",
        serde_json::to_string(&value).ok()?
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn write_context(session_id: &str) -> crate::engine::CausalContext {
        crate::engine::CausalContext::new(
            crate::engine::ActorId::new("system:test").unwrap(),
            crate::engine::ActorKind::System,
            crate::engine::AuthorityGrantId::new("engine-system").unwrap(),
            crate::engine::TraceId::new("agent-state-context-test").unwrap(),
        )
        .with_scope("state.write")
        .with_idempotency_key("agent-state-context-test")
        .with_session_id(session_id)
    }

    #[tokio::test]
    async fn agent_state_context_reads_session_state_namespace() {
        let handle = crate::engine::EngineHostHandle::new_in_memory().unwrap();
        let session_id = "session-agent-state";
        let write = handle
            .invoke(crate::engine::Invocation::new_sync(
                crate::engine::FunctionId::new("state::set").unwrap(),
                json!({
                    "scope": "session",
                    "namespace": AGENT_STATE_NAMESPACE,
                    "key": "memory/note",
                    "value": {"body": "persist from execute"}
                }),
                write_context(session_id),
            ))
            .await;
        assert_eq!(write.error, None);

        let context = load_agent_state_context(&handle, session_id, None)
            .await
            .expect("agent state context");
        assert!(context.contains("Agent-owned state"));
        assert!(context.contains("memory/note"));
        assert!(context.contains("persist from execute"));
    }
}
