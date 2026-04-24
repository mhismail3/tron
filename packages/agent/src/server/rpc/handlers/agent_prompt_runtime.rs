use std::collections::HashSet;
use std::fmt::Write;
use std::sync::Arc;

use crate::events::types::payloads::skill::{SkillsClearedMode, SkillsClearedPayload};
use crate::events::{ActivitySummaryLine, EventStore, EventType, MessagePreview};
use crate::runtime::orchestrator::event_persister::EventPersister;
use crate::runtime::orchestrator::session_manager::SessionManager;
use crate::runtime::orchestrator::session_reconstructor::ReconstructedState;
use crate::skills::registry::SkillRegistry;
use crate::skills::types::SkillMetadata;
use parking_lot::RwLock;
use serde_json::Value;

use crate::server::rpc::context::run_blocking_task;
use crate::server::rpc::errors::RpcError;
use crate::server::rpc::session_context::{ContextArtifactsService, collect_dynamic_rule_paths};

/// Build the JSON payload for a `message.user` event.
///
/// When the prompt includes images or attachments, the payload is enriched
/// so that session resume can reconstruct client UI and the LLM can see
/// previously-sent images in reconstructed history.
///
/// The optional `extra_metadata` object is merged into the payload (top-level
/// fields like `messageKind`, `confirmationDecision`, `answerCount` used by
/// interactive-tool handlers so iOS can render chips from structured data).
pub fn build_user_event_payload(
    prompt: &str,
    images: Option<&[Value]>,
    attachments: Option<&[Value]>,
    extra_metadata: Option<&Value>,
    skills: Option<&Value>,
) -> Value {
    let has_images = images.is_some_and(|v| !v.is_empty());
    let has_attachments = attachments.is_some_and(|v| !v.is_empty());

    let (content, image_count) = if !has_images && !has_attachments {
        (Value::String(prompt.to_owned()), None)
    } else {
        let mut blocks = vec![serde_json::json!({"type": "text", "text": prompt})];
        let mut img_count: i64 = 0;

        if let Some(imgs) = images {
            for img in imgs {
                let data = img.get("data").and_then(|v| v.as_str());
                let mime = img
                    .get("mediaType")
                    .or_else(|| img.get("mimeType"))
                    .and_then(|v| v.as_str());
                if let (Some(d), Some(m)) = (data, mime) {
                    blocks.push(serde_json::json!({
                        "type": "image",
                        "data": d,
                        "mimeType": m,
                    }));
                    img_count += 1;
                }
            }
        }

        if let Some(atts) = attachments {
            for att in atts {
                let data = att.get("data").and_then(|v| v.as_str());
                let mime = att.get("mimeType").and_then(|v| v.as_str());
                if let (Some(d), Some(m)) = (data, mime) {
                    if m.starts_with("image/") {
                        blocks.push(serde_json::json!({
                            "type": "image",
                            "data": d,
                            "mimeType": m,
                        }));
                        img_count += 1;
                    } else {
                        let mut block = serde_json::json!({
                            "type": "document",
                            "data": d,
                            "mimeType": m,
                        });
                        if let Some(name) = att.get("fileName").and_then(|v| v.as_str()) {
                            block["fileName"] = Value::String(name.to_owned());
                        }
                        blocks.push(block);
                    }
                }
            }
        }

        if blocks.len() == 1 {
            (Value::String(prompt.to_owned()), None)
        } else {
            let count = if img_count > 0 { Some(img_count) } else { None };
            (Value::Array(blocks), count)
        }
    };

    let mut payload = serde_json::json!({ "content": content });
    if let Some(c) = image_count {
        payload["imageCount"] = Value::Number(c.into());
    }
    if let Some(Value::Object(extra)) = extra_metadata {
        if let Value::Object(ref mut obj) = payload {
            for (k, v) in extra {
                let _ = obj.insert(k.clone(), v.clone());
            }
        }
    }
    if let Some(s) = skills {
        payload["skills"] = s.clone();
    }
    payload
}

/// Collect skills activated since the last `message.user` event.
///
/// Returns `skills_json` in the format expected by iOS:
/// `[{"name", "source", "service", "displayName"}]`
///
/// Uses the event store sequence ordering to find only the skill events
/// that belong to the current prompt (between last message.user and now).
///
/// `service` and `displayName` are enriched via the registry. If the skill
/// is no longer present in the registry (deleted from disk), `service` is
/// `"unknown"` and `displayName` falls back to the raw skill name — iOS
/// renders the chip without a service badge in that case.
pub fn collect_pending_skill_payloads(
    event_store: &crate::events::EventStore,
    session_id: &str,
    skill_registry: Option<&crate::skills::registry::SkillRegistry>,
) -> Option<Value> {
    let last_user_seq = event_store
        .get_latest_event_by_type(session_id, "message.user")
        .ok()
        .flatten()
        .map(|e| e.sequence)
        .unwrap_or(0);

    let recent_events = event_store
        .get_events_since(session_id, last_user_seq)
        .unwrap_or_default();

    let mut skills: Vec<Value> = Vec::new();

    for event in &recent_events {
        let payload: Value = match serde_json::from_str(&event.payload) {
            Ok(v) => v,
            Err(_) => continue,
        };
        if event.event_type.as_str() == "skill.activated" {
            if let Some(name) = payload.get("skillName").and_then(|v| v.as_str()) {
                let source = payload
                    .get("source")
                    .and_then(|v| v.as_str())
                    .unwrap_or("project");
                let registry_entry = skill_registry.and_then(|r| r.get(name));
                let display_name = registry_entry
                    .map(|m| m.display_name.as_str())
                    .unwrap_or(name);
                let service = registry_entry
                    .map(|m| m.service.as_str())
                    .unwrap_or("unknown");
                skills.push(serde_json::json!({
                    "name": name,
                    "source": source,
                    "service": service,
                    "displayName": display_name,
                }));
            }
        }
    }

    if skills.is_empty() {
        None
    } else {
        Some(Value::Array(skills))
    }
}

pub fn build_user_content_override(
    prompt: &str,
    model: &str,
    images: Option<&[Value]>,
    attachments: Option<&[Value]>,
) -> Option<crate::core::messages::UserMessageContent> {
    let has_images = images.is_some_and(|v| !v.is_empty());
    let has_attachments = attachments.is_some_and(|v| !v.is_empty());
    if !has_images && !has_attachments {
        return None;
    }

    let mut blocks = vec![crate::core::content::UserContent::Text {
        text: prompt.to_owned(),
    }];

    if let Some(imgs) = images {
        for img in imgs {
            if let (Some(data), Some(media_type)) = (
                img.get("data").and_then(|v| v.as_str()),
                img.get("mediaType")
                    .or_else(|| img.get("mimeType"))
                    .and_then(|v| v.as_str()),
            ) {
                blocks.push(crate::core::content::UserContent::Image {
                    data: data.to_owned(),
                    mime_type: media_type.to_owned(),
                });
            }
        }
    }

    if let Some(atts) = attachments {
        for att in atts {
            if let (Some(data), Some(mime)) = (
                att.get("data").and_then(|v| v.as_str()),
                att.get("mimeType").and_then(|v| v.as_str()),
            ) {
                let file_name = att
                    .get("fileName")
                    .and_then(|v| v.as_str())
                    .map(String::from);
                if mime.starts_with("image/") {
                    blocks.push(crate::core::content::UserContent::Image {
                        data: data.to_owned(),
                        mime_type: mime.to_owned(),
                    });
                } else {
                    let extracted_text = crate::core::document_extractor::extract_text(data, mime);
                    blocks.push(crate::core::content::UserContent::Document {
                        data: data.to_owned(),
                        mime_type: mime.to_owned(),
                        file_name,
                        extracted_text,
                    });
                }
            }
        }
    }

    if !crate::llm::model_supports_images(model) {
        blocks.retain(|block| !matches!(block, crate::core::content::UserContent::Image { .. }));
    }

    (blocks.len() > 1).then_some(crate::core::messages::UserMessageContent::Blocks(blocks))
}

#[derive(Default)]
pub struct PromptContextArtifacts {
    pub rules_content: Option<String>,
    pub rules_index: Option<crate::runtime::context::rules_index::RulesIndex>,
    pub pre_activated_rules: Vec<String>,
    pub workspace_id: Option<String>,
}

pub struct PromptBootstrapData {
    pub artifacts: PromptContextArtifacts,
    pub subagent_results_context: Option<String>,
    pub process_results_context: Option<String>,
    pub user_job_actions_context: Option<String>,
}

pub struct ResumedPromptSession {
    pub state: ReconstructedState,
    pub persister: Arc<EventPersister>,
}

pub struct SessionUpdateData {
    pub session: crate::events::sqlite::row_types::SessionRow,
    pub preview: Option<MessagePreview>,
    pub activity_lines: Vec<ActivitySummaryLine>,
}

fn load_prompt_context_artifacts(
    context_artifacts: &ContextArtifactsService,
    event_store: &crate::events::EventStore,
    session_id: &str,
    working_dir: &str,
    settings: &crate::settings::TronSettings,
    is_resumed: bool,
    source: Option<&str>,
) -> PromptContextArtifacts {
    // Chat sessions skip context artifacts (rules, workspace memory)
    if source == Some("chat") {
        return PromptContextArtifacts::default();
    }

    let artifacts = context_artifacts.load(event_store, working_dir, settings);
    let pre_activated_rules = if is_resumed {
        collect_dynamic_rule_paths(event_store, session_id)
    } else {
        Vec::new()
    };

    PromptContextArtifacts {
        rules_content: artifacts.session.rules.merged_content,
        rules_index: artifacts.rules_index,
        pre_activated_rules,
        workspace_id: artifacts.workspace_id,
    }
}

/// Parse a pending-results event row's payload into an `(id, value)` pair.
///
/// Used by the `get_pending_*` helpers that surface unconsumed notification
/// events into the next prompt's context. A corrupt payload means the event
/// cannot be displayed to the model, so we drop it — but we log first so the
/// stale/corrupt payload is findable in operator logs.
fn parse_pending_event_payload(
    event: crate::events::sqlite::row_types::EventRow,
) -> Option<(String, Value)> {
    match serde_json::from_str::<Value>(&event.payload) {
        Ok(payload) => Some((event.id, payload)),
        Err(e) => {
            tracing::warn!(
                event_id = %event.id,
                event_type = %event.event_type,
                error = %e,
                "pending-results: corrupt event payload JSON; dropping from prompt context"
            );
            None
        }
    }
}

/// Query unconsumed subagent results from the event store.
///
/// Returns `(event_id, payload_json)` pairs for `notification.subagent_result`
/// events that have no matching `subagent.results_consumed` event referencing
/// their ID. Works identically for live sessions and session resume.
pub fn get_pending_subagent_results(
    event_store: &crate::events::EventStore,
    session_id: &str,
) -> Vec<(String, Value)> {
    let notifications = event_store
        .get_events_by_type(session_id, &["notification.subagent_result"], None)
        .unwrap_or_default();

    if notifications.is_empty() {
        return vec![];
    }

    let consumed_events = event_store
        .get_events_by_type(session_id, &["subagent.results_consumed"], None)
        .unwrap_or_default();

    let mut consumed_ids: HashSet<String> = HashSet::new();
    for event in &consumed_events {
        if let Ok(payload) = serde_json::from_str::<Value>(&event.payload)
            && let Some(ids) = payload.get("consumedEventIds").and_then(|v| v.as_array())
        {
            for id in ids {
                if let Some(s) = id.as_str() {
                    let _ = consumed_ids.insert(s.to_owned());
                }
            }
        }
    }

    notifications
        .into_iter()
        .filter(|event| !consumed_ids.contains(&event.id))
        .filter_map(|event| parse_pending_event_payload(event))
        .collect()
}

/// Format pending subagent results into markdown context string.
pub fn format_subagent_results(results: &[(String, Value)]) -> Option<String> {
    if results.is_empty() {
        return None;
    }

    let mut ctx = String::from("# Completed Sub-Agent Results\n\n");
    ctx.push_str(
        "The following sub-agent(s) have completed since your last turn. \
         Review their results and incorporate them into your response.\n\n",
    );

    for (_event_id, payload) in results {
        let success = payload
            .get("success")
            .and_then(Value::as_bool)
            .unwrap_or(false);
        let icon = if success { "+" } else { "x" };
        let subagent_id = payload
            .get("subagentSessionId")
            .and_then(Value::as_str)
            .unwrap_or("unknown");
        let task = payload
            .get("task")
            .and_then(Value::as_str)
            .unwrap_or("unknown");
        let total_turns = payload
            .get("totalTurns")
            .and_then(Value::as_i64)
            .unwrap_or(0);
        let duration = payload.get("duration").and_then(Value::as_i64).unwrap_or(0);

        let _ = writeln!(ctx, "## [{icon}] Sub-Agent: `{subagent_id}`\n");
        let _ = writeln!(ctx, "**Task**: {task}");
        let _ = writeln!(
            ctx,
            "**Status**: {}",
            if success { "Completed" } else { "Failed" }
        );
        let _ = writeln!(ctx, "**Turns**: {total_turns}");
        #[allow(clippy::cast_precision_loss)]
        let duration_secs = duration as f64 / 1000.0;
        let _ = writeln!(ctx, "**Duration**: {duration_secs:.1}s");

        if let Some(output) = payload.get("output").and_then(Value::as_str)
            && !output.is_empty()
        {
            let truncated = if output.len() > 2000 {
                format!("{}\n\n... [Output truncated]", &output[..2000])
            } else {
                output.to_string()
            };
            let _ = write!(ctx, "\n**Output**:\n```\n{truncated}\n```\n");
        }

        if let Some(error) = payload.get("error").and_then(Value::as_str) {
            let _ = writeln!(ctx, "\n**Error**:\n{error}\n");
        }

        ctx.push_str("\n---\n\n");
    }

    Some(ctx)
}

/// Query pending (unconsumed) background process results for a session.
pub fn get_pending_process_results(
    event_store: &crate::events::EventStore,
    session_id: &str,
) -> Vec<(String, Value)> {
    let notifications = event_store
        .get_events_by_type(session_id, &["notification.process_result"], None)
        .unwrap_or_default();

    if notifications.is_empty() {
        return vec![];
    }

    let consumed_events = event_store
        .get_events_by_type(session_id, &["process.results_consumed"], None)
        .unwrap_or_default();

    let mut consumed_ids: HashSet<String> = HashSet::new();
    for event in &consumed_events {
        if let Ok(payload) = serde_json::from_str::<Value>(&event.payload)
            && let Some(ids) = payload.get("consumedEventIds").and_then(|v| v.as_array())
        {
            for id in ids {
                if let Some(s) = id.as_str() {
                    let _ = consumed_ids.insert(s.to_owned());
                }
            }
        }
    }

    notifications
        .into_iter()
        .filter(|event| !consumed_ids.contains(&event.id))
        .filter_map(|event| parse_pending_event_payload(event))
        .collect()
}

/// Format pending process results into markdown context string.
pub fn format_process_results(results: &[(String, Value)]) -> Option<String> {
    if results.is_empty() {
        return None;
    }

    let mut ctx = String::from("# Completed Background Processes\n\n");
    ctx.push_str("The following background process(es) have completed since your last turn.\n\n");

    for (_event_id, payload) in results {
        let success = payload
            .get("success")
            .and_then(Value::as_bool)
            .unwrap_or(false);
        let icon = if success { "+" } else { "x" };
        let process_id = payload
            .get("processId")
            .and_then(Value::as_str)
            .unwrap_or("unknown");
        let label = payload
            .get("label")
            .and_then(Value::as_str)
            .unwrap_or("unknown");
        let exit_code = payload.get("exitCode").and_then(Value::as_i64);
        let duration = payload.get("duration").and_then(Value::as_i64).unwrap_or(0);

        let _ = writeln!(ctx, "## [{icon}] Process: `{label}` ({process_id})\n");
        let status_str = if success {
            match exit_code {
                Some(code) => format!("Completed (exit code {code})"),
                None => "Completed".into(),
            }
        } else {
            match exit_code {
                Some(code) => format!("Failed (exit code {code})"),
                None => "Failed".into(),
            }
        };
        let _ = writeln!(ctx, "**Status**: {status_str}");
        #[allow(clippy::cast_precision_loss)]
        let duration_secs = duration as f64 / 1000.0;
        let _ = writeln!(ctx, "**Duration**: {duration_secs:.1}s");

        if let Some(output) = payload.get("output").and_then(Value::as_str)
            && !output.is_empty()
        {
            let truncated = if output.len() > 2000 {
                format!("{}\n\n... [Output truncated]", &output[..2000])
            } else {
                output.to_string()
            };
            let _ = write!(ctx, "\n**Output**:\n```\n{truncated}\n```\n");
        }

        if let Some(blob_id) = payload.get("blobId").and_then(Value::as_str) {
            let _ = writeln!(ctx, "\nFull output available: `{blob_id}`");
        }

        ctx.push_str("\n---\n\n");
    }

    Some(ctx)
}

/// Get pending user job action notifications (backgrounded/cancelled from iOS).
/// Filters out already-consumed actions using `user_job_actions.consumed` events.
pub fn get_pending_user_job_actions(
    event_store: &crate::events::EventStore,
    session_id: &str,
) -> Vec<(String, Value)> {
    let notifications = event_store
        .get_events_by_type(session_id, &["notification.user_job_action"], None)
        .unwrap_or_default();

    if notifications.is_empty() {
        return vec![];
    }

    let consumed_events = event_store
        .get_events_by_type(session_id, &["user_job_actions.consumed"], None)
        .unwrap_or_default();

    let mut consumed_ids: HashSet<String> = HashSet::new();
    for event in &consumed_events {
        if let Ok(payload) = serde_json::from_str::<Value>(&event.payload)
            && let Some(ids) = payload.get("consumedEventIds").and_then(|v| v.as_array())
        {
            for id in ids {
                if let Some(s) = id.as_str() {
                    let _ = consumed_ids.insert(s.to_owned());
                }
            }
        }
    }

    notifications
        .into_iter()
        .filter(|event| !consumed_ids.contains(&event.id))
        .filter_map(|event| parse_pending_event_payload(event))
        .collect()
}

/// Format user job actions into a system message for context injection.
pub fn format_user_job_actions(actions: &[(String, Value)]) -> String {
    let mut ctx = String::from("# User Job Actions\n\n");
    for (_event_id, action) in actions {
        let job_id = action
            .get("jobId")
            .and_then(Value::as_str)
            .unwrap_or("unknown");
        let action_type = action
            .get("action")
            .and_then(Value::as_str)
            .unwrap_or("unknown");
        let label = action
            .get("label")
            .and_then(Value::as_str)
            .unwrap_or("unknown");
        let _ = writeln!(ctx, "- User **{action_type}** job `{label}` ({job_id})");
    }
    ctx
}

/// Gather recent event types and Bash tool call commands since the last compact.boundary.
///
/// Returns `(event_types, bash_commands)` for the compaction trigger's progress-signal check.
#[cfg(test)]
pub fn gather_recent_events(
    event_store: &crate::events::EventStore,
    session_id: &str,
) -> (Vec<String>, Vec<String>) {
    let boundary = event_store
        .get_events_by_type(session_id, &["compact.boundary"], None)
        .ok()
        .and_then(|rows| rows.into_iter().last())
        .or_else(|| {
            event_store
                .get_events_by_type(session_id, &["compact.summary"], None)
                .ok()
                .and_then(|rows| rows.into_iter().last())
        });

    let events = if let Some(ref boundary) = boundary {
        event_store
            .get_events_since(session_id, boundary.sequence)
            .unwrap_or_default()
    } else {
        event_store
            .get_events_by_session(
                session_id,
                &crate::events::sqlite::repositories::event::ListEventsOptions::default(),
            )
            .unwrap_or_default()
    };

    let mut event_types = Vec::new();
    let mut bash_commands = Vec::new();

    for event in &events {
        event_types.push(event.event_type.clone());

        if event.event_type == "tool.call"
            && event.tool_name.as_deref() == Some("Bash")
            && let Ok(payload) = serde_json::from_str::<serde_json::Value>(&event.payload)
            && let Some(command) = payload
                .get("arguments")
                .and_then(|arguments| arguments.get("command"))
                .and_then(|command| command.as_str())
        {
            bash_commands.push(command.to_owned());
        }
    }

    (event_types, bash_commands)
}

pub async fn resume_prompt_session(
    session_manager: Arc<SessionManager>,
    session_id: String,
) -> Result<ResumedPromptSession, RpcError> {
    run_blocking_task("agent.prompt.resume", move || {
        let active = session_manager
            .resume_session(&session_id)
            .map_err(|error| RpcError::Internal {
                message: error.to_string(),
            })?;
        Ok(ResumedPromptSession {
            state: active.state.clone(),
            persister: active.context.persister.clone(),
        })
    })
    .await
}

/// Local-model variant of `load_prompt_bootstrap`: loads only the cheap artifacts
/// (rules files + dynamic rule paths) and skips the three DB queries for pending
/// subagent/process/user-job results. Local models never receive those
/// result blocks in context (see `build_turn_context` in `turn_runner.rs`), so
/// producing them is pure waste that adds to TTFT.
///
/// Pending results stay queued in the event store — if the user switches back to
/// a cloud model in a later prompt, they will be consumed and injected then.
pub async fn load_prompt_bootstrap_minimal(
    context_artifacts: Arc<ContextArtifactsService>,
    event_store: Arc<EventStore>,
    session_id: String,
    working_dir: String,
    settings: crate::settings::TronSettings,
    is_resumed: bool,
    source: Option<String>,
) -> Result<PromptBootstrapData, RpcError> {
    run_blocking_task("agent.prompt.bootstrap.minimal", move || {
        let artifacts = load_prompt_context_artifacts(
            context_artifacts.as_ref(),
            event_store.as_ref(),
            &session_id,
            &working_dir,
            &settings,
            is_resumed,
            source.as_deref(),
        );
        Ok(PromptBootstrapData {
            artifacts,
            subagent_results_context: None,
            process_results_context: None,
            user_job_actions_context: None,
        })
    })
    .await
}

pub async fn load_prompt_bootstrap(
    context_artifacts: Arc<ContextArtifactsService>,
    event_store: Arc<EventStore>,
    session_id: String,
    working_dir: String,
    settings: crate::settings::TronSettings,
    is_resumed: bool,
    source: Option<String>,
) -> Result<PromptBootstrapData, RpcError> {
    run_blocking_task("agent.prompt.bootstrap", move || {
        let artifacts = load_prompt_context_artifacts(
            context_artifacts.as_ref(),
            event_store.as_ref(),
            &session_id,
            &working_dir,
            &settings,
            is_resumed,
            source.as_deref(),
        );

        let pending = get_pending_subagent_results(event_store.as_ref(), &session_id);
        let subagent_results_context = if pending.is_empty() {
            None
        } else {
            let event_ids: Vec<String> = pending.iter().map(|(id, _)| id.clone()).collect();
            let formatted = format_subagent_results(&pending);
            if formatted.is_some() {
                let _ = event_store.append(&crate::events::AppendOptions {
                    session_id: &session_id,
                    event_type: EventType::SubagentResultsConsumed,
                    payload: serde_json::json!({
                        "consumedEventIds": event_ids,
                        "count": pending.len(),
                    }),
                    parent_id: None,
                    sequence: None,
                });
            }
            formatted
        };

        let pending_procs = get_pending_process_results(event_store.as_ref(), &session_id);
        let process_results_context = if pending_procs.is_empty() {
            None
        } else {
            let event_ids: Vec<String> = pending_procs.iter().map(|(id, _)| id.clone()).collect();
            let formatted = format_process_results(&pending_procs);
            if formatted.is_some() {
                let _ = event_store.append(&crate::events::AppendOptions {
                    session_id: &session_id,
                    event_type: EventType::ProcessResultsConsumed,
                    payload: serde_json::json!({
                        "consumedEventIds": event_ids,
                        "count": pending_procs.len(),
                    }),
                    parent_id: None,
                    sequence: None,
                });
            }
            formatted
        };

        // Inject user job actions (backgrounded / cancelled from iOS).
        let user_job_actions = get_pending_user_job_actions(event_store.as_ref(), &session_id);
        let user_job_actions_context = if user_job_actions.is_empty() {
            None
        } else {
            let event_ids: Vec<String> =
                user_job_actions.iter().map(|(id, _)| id.clone()).collect();
            let formatted = format_user_job_actions(&user_job_actions);
            let _ = event_store.append(&crate::events::AppendOptions {
                session_id: &session_id,
                event_type: EventType::UserJobActionsConsumed,
                payload: serde_json::json!({
                    "consumedEventIds": event_ids,
                    "count": user_job_actions.len(),
                }),
                parent_id: None,
                sequence: None,
            });
            Some(formatted)
        };

        Ok(PromptBootstrapData {
            artifacts,
            subagent_results_context,
            process_results_context,
            user_job_actions_context,
        })
    })
    .await
}

pub async fn persist_user_message_event(
    event_store: Arc<EventStore>,
    session_id: String,
    payload: Value,
) -> Result<(), RpcError> {
    run_blocking_task("agent.prompt.persist_user", move || {
        let _ = event_store.append(&crate::events::AppendOptions {
            session_id: &session_id,
            event_type: crate::events::EventType::MessageUser,
            payload,
            parent_id: None,
            sequence: None,
        });
        Ok(())
    })
    .await
}

/// Prepare skill context for a prompt: reconstructs the [`SkillTracker`]
/// from events, **emits a `skills.cleared` event** under either the
/// `ClearAll` or `AskUser` compaction policy if any skills were cleared at
/// the last boundary, looks up active skills in the registry, and builds
/// the `<skills>` XML block.
///
/// The payload's `mode` field discriminates the iOS render:
/// - `ClearAll` → informational notice listing the previously-active skills.
/// - `AskUser` → interactive picker chips that call `skill.activate` on tap.
///
/// `AutoRestore` never reaches this emission branch because its tracker
/// preserves active skills through the boundary and leaves `cleared_at_boundary`
/// empty. See `SkillTracker::from_events_with_policy`.
///
/// The `prepare_*` prefix (vs `build_*`) signals that this writes to the
/// event store as a side effect — callers that want a pure formatter
/// against an existing tracker should use the lower-level helpers in
/// `crate::skills::injector` directly.
pub async fn prepare_skill_context_from_session(
    skill_registry: Arc<RwLock<SkillRegistry>>,
    event_store: Arc<EventStore>,
    session_id: String,
) -> Result<SkillContextResult, RpcError> {
    run_blocking_task("agent.prompt.skills", move || {
        let policy = {
            let settings = crate::settings::get_settings();
            settings.skills.compaction_policy.clone()
        };

        let tracker = crate::server::rpc::handlers::skill_session::reconstruct_tracker(
            &event_store,
            &session_id,
            &policy,
        );

        // Side effect: under ClearAll OR AskUser policy, persist a
        // `skills.cleared` event so the iOS client can render the correct
        // banner or picker. Documented in the doc-comment above.
        // AutoRestore skips this branch by construction (cleared_at_boundary
        // is always empty under AutoRestore). See M6.
        //
        // INVARIANT: the wire shape of this event is pinned by the typed
        // `SkillsClearedPayload` struct in `events/types/payloads/skill.rs`.
        // We round-trip through `serde_json::to_value(&payload)` rather than
        // an inline `json!` literal so any future rename/retype of the struct
        // fields is caught by the compiler instead of silently drifting
        // between the emitter and the decoders (Rust tests + iOS).
        let mode = match policy {
            crate::settings::types::CompactionPolicy::ClearAll => Some(SkillsClearedMode::ClearAll),
            crate::settings::types::CompactionPolicy::AskUser => Some(SkillsClearedMode::AskUser),
            crate::settings::types::CompactionPolicy::AutoRestore => None,
        };
        if let Some(mode) = mode {
            let cleared = tracker.cleared_at_boundary();
            if !cleared.is_empty() {
                let payload = SkillsClearedPayload {
                    cleared_skills: cleared.to_vec(),
                    reason: "compaction".to_string(),
                    mode,
                };
                let payload_value = serde_json::to_value(&payload).expect(
                    "SkillsClearedPayload is composed of owned primitives and always serializes",
                );
                let _ = event_store.append(&crate::events::AppendOptions {
                    session_id: &session_id,
                    event_type: crate::events::EventType::SkillsCleared,
                    payload: payload_value,
                    parent_id: None,
                    sequence: None,
                });
            }
        }

        // Collect active skill names
        let active_names = tracker.active_skill_names();

        tracing::info!(
            active_count = tracker.count(),
            active_skills = ?active_names,
            "[skills] reconstructed tracker for session {session_id}"
        );

        // Look up metadata from registry
        let found: Vec<SkillMetadata> = if active_names.is_empty() {
            Vec::new()
        } else {
            let registry = skill_registry.read();
            let name_refs: Vec<&str> = active_names.iter().map(String::as_str).collect();
            let (found, _not_found) = registry.get_many(&name_refs);
            found.into_iter().cloned().collect()
        };

        tracing::info!(
            found_count = found.len(),
            found_names = ?found.iter().map(|s| &s.name).collect::<Vec<_>>(),
            "[skills] registry lookup result"
        );

        // Build XML context
        let skill_context = if found.is_empty() {
            None
        } else {
            let skill_refs: Vec<&SkillMetadata> = found.iter().collect();
            let context = crate::skills::injector::build_skill_context(&skill_refs);
            tracing::info!(
                context_len = context.len(),
                context_preview = &context[..context.len().min(200)],
                "[skills] built skill context XML"
            );
            (!context.is_empty()).then_some(context)
        };

        // Build activation directive for active skills
        let skill_activation_context =
            crate::skills::injector::build_activation_directive(&active_names);

        // Build removal notice for deactivated skills + post-compaction guidance
        let removal_notice = {
            let mut notices = Vec::new();

            // Post-compaction skill notice: when skills were cleared by compaction
            // and none re-activated, tell the model not to use skills from the summary
            if tracker.skills_cleared_by_compaction() {
                notices.push(
                    "Context was compacted and all previously active skills were cleared. \
                     Skills mentioned in the earlier context summary are not currently active \
                     and should not be used. To use a skill, activate it with @skill-name."
                        .to_string(),
                );
            }

            // Standard removal notice for explicitly deactivated skills
            let pending_removals = tracker.pending_removal_notices();
            if !pending_removals.is_empty() {
                let names: Vec<String> = pending_removals
                    .iter()
                    .map(|n| format!("@{n}"))
                    .collect();
                notices.push(format!(
                    "The following skills have been deactivated. Stop following their instructions: {}.",
                    names.join(", ")
                ));
            }

            if notices.is_empty() {
                None
            } else {
                Some(notices.join("\n\n"))
            }
        };

        Ok(SkillContextResult {
            skill_activation_context,
            skill_context,
            skill_removal_context: removal_notice,
        })
    })
    .await
}

/// Result of building skill context from session state.
pub struct SkillContextResult {
    /// Activation directive ("follow these active skills").
    pub skill_activation_context: Option<String>,
    /// The `<skills>` XML block for active skills.
    pub skill_context: Option<String>,
    /// One-turn removal notice for recently deactivated skills.
    pub skill_removal_context: Option<String>,
}

pub async fn load_session_update_data(
    session_manager: Arc<SessionManager>,
    event_store: Arc<EventStore>,
    session_id: String,
) -> Result<Option<SessionUpdateData>, RpcError> {
    run_blocking_task("agent.prompt.session_update", move || {
        let session =
            session_manager
                .get_session(&session_id)
                .map_err(|error| RpcError::Internal {
                    message: error.to_string(),
                })?;
        let Some(session) = session else {
            return Ok(None);
        };

        let preview = event_store
            .get_session_message_previews(&[session_id.as_str()])
            .ok()
            .and_then(|mut previews| previews.remove(&session_id));

        let activity_lines = event_store
            .get_session_activity_summaries(&session_id)
            .unwrap_or_default();

        Ok(Some(SessionUpdateData {
            session,
            preview,
            activity_lines,
        }))
    })
    .await
}

#[cfg(test)]
mod skills_cleared_emission_tests {
    //! Integration tests for the `skills.cleared` emission side effect in
    //! [`prepare_skill_context_from_session`]. See M6 in the audit plan.
    //!
    //! These tests mutate the global settings singleton and MUST hold the
    //! shared `settings_reload_lock()` to serialize with other settings-
    //! mutating tests.

    use super::*;
    use crate::events::types::payloads::skill::{SkillsClearedMode, SkillsClearedPayload};
    use crate::server::rpc::handlers::test_helpers::make_test_context;
    use crate::settings::types::CompactionPolicy;

    fn settings_lock() -> &'static std::sync::Mutex<()> {
        crate::server::rpc::settings_service::settings_reload_lock()
    }

    fn settings_with_policy(policy: CompactionPolicy) -> crate::settings::TronSettings {
        let mut s = crate::settings::TronSettings::default();
        s.skills.compaction_policy = policy;
        s
    }

    fn append(
        store: &Arc<crate::events::EventStore>,
        session_id: &str,
        event_type: crate::events::EventType,
        payload: serde_json::Value,
    ) {
        store
            .append(&crate::events::AppendOptions {
                session_id,
                event_type,
                payload,
                parent_id: None,
                sequence: None,
            })
            .expect("append must succeed");
    }

    fn seed_skill_activated_then_boundary(
        store: &Arc<crate::events::EventStore>,
        session_id: &str,
    ) {
        append(
            store,
            session_id,
            crate::events::EventType::SkillActivated,
            serde_json::json!({ "skillName": "browser", "source": "global" }),
        );
        append(
            store,
            session_id,
            crate::events::EventType::SkillActivated,
            serde_json::json!({ "skillName": "code", "source": "project" }),
        );
        append(
            store,
            session_id,
            crate::events::EventType::CompactBoundary,
            serde_json::json!({
                "originalTokens": 0,
                "compactedTokens": 0,
                "reason": "manual",
            }),
        );
    }

    fn read_skills_cleared_events(
        store: &crate::events::EventStore,
        session_id: &str,
    ) -> Vec<SkillsClearedPayload> {
        store
            .get_events_by_type(session_id, &["skills.cleared"], None)
            .unwrap()
            .into_iter()
            .map(|row| serde_json::from_str::<SkillsClearedPayload>(&row.payload).unwrap())
            .collect()
    }

    async fn run_with_policy(policy: CompactionPolicy) -> Vec<SkillsClearedPayload> {
        let ctx = make_test_context();
        let session_id = ctx
            .session_manager
            .create_session("test-model", "/tmp", Some("t"), None)
            .unwrap();
        seed_skill_activated_then_boundary(&ctx.event_store, &session_id);

        let _guard = settings_lock()
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        crate::settings::init_settings(settings_with_policy(policy));
        let _ = prepare_skill_context_from_session(
            ctx.skill_registry.clone(),
            ctx.event_store.clone(),
            session_id.clone(),
        )
        .await
        .unwrap();
        // Restore defaults before releasing the lock.
        crate::settings::init_settings(crate::settings::TronSettings::default());
        drop(_guard);

        read_skills_cleared_events(&ctx.event_store, &session_id)
    }

    #[tokio::test]
    async fn emits_skills_cleared_under_clear_all_with_mode_clear_all() {
        let events = run_with_policy(CompactionPolicy::ClearAll).await;
        assert_eq!(events.len(), 1, "exactly one skills.cleared event expected");
        let payload = &events[0];
        assert_eq!(payload.mode, SkillsClearedMode::ClearAll);
        assert_eq!(payload.reason, "compaction");
        let mut names = payload.cleared_skills.clone();
        names.sort();
        assert_eq!(names, vec!["browser", "code"]);
    }

    #[tokio::test]
    async fn emits_skills_cleared_under_ask_user_with_mode_ask_user() {
        let events = run_with_policy(CompactionPolicy::AskUser).await;
        assert_eq!(events.len(), 1, "exactly one skills.cleared event expected");
        let payload = &events[0];
        assert_eq!(payload.mode, SkillsClearedMode::AskUser);
        assert_eq!(payload.reason, "compaction");
        let mut names = payload.cleared_skills.clone();
        names.sort();
        assert_eq!(names, vec!["browser", "code"]);
    }

    #[tokio::test]
    async fn does_not_emit_under_auto_restore() {
        // AutoRestore preserves active skills through the boundary, so there's
        // nothing cleared to notify about.
        let events = run_with_policy(CompactionPolicy::AutoRestore).await;
        assert!(
            events.is_empty(),
            "AutoRestore must never emit skills.cleared"
        );
    }

    #[tokio::test]
    async fn no_emission_when_no_boundary_yet() {
        // Even under ClearAll/AskUser, if no compact.boundary has happened
        // the cleared list is empty and we must not emit.
        let ctx = make_test_context();
        let session_id = ctx
            .session_manager
            .create_session("test-model", "/tmp", Some("t"), None)
            .unwrap();
        append(
            &ctx.event_store,
            &session_id,
            crate::events::EventType::SkillActivated,
            serde_json::json!({ "skillName": "a", "source": "global" }),
        );

        let _guard = settings_lock()
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        crate::settings::init_settings(settings_with_policy(CompactionPolicy::ClearAll));
        let _ = prepare_skill_context_from_session(
            ctx.skill_registry.clone(),
            ctx.event_store.clone(),
            session_id.clone(),
        )
        .await
        .unwrap();
        crate::settings::init_settings(crate::settings::TronSettings::default());
        drop(_guard);

        let events = read_skills_cleared_events(&ctx.event_store, &session_id);
        assert!(events.is_empty());
    }

    #[tokio::test]
    async fn emitted_payload_exactly_matches_typed_struct_serialization() {
        // Regression guard for the M6 audit follow-up: the emission site must
        // round-trip through `SkillsClearedPayload` rather than an inline
        // `json!` literal, so any rename/retype of a struct field breaks the
        // compiler instead of silently drifting between emitter and decoder.
        //
        // We reconstruct the expected wire shape from the typed struct and
        // assert the raw on-disk payload matches — no field names hardcoded
        // in this test either, so both sides track the struct.
        let events = run_with_policy(CompactionPolicy::ClearAll).await;
        assert_eq!(events.len(), 1);
        let payload = &events[0];

        let expected = SkillsClearedPayload {
            cleared_skills: {
                let mut v = payload.cleared_skills.clone();
                v.sort();
                v
            },
            reason: "compaction".to_string(),
            mode: SkillsClearedMode::ClearAll,
        };

        // Sort on our copy for stable comparison.
        let mut actual = payload.clone();
        actual.cleared_skills.sort();
        assert_eq!(actual, expected);

        // And the reverse: the struct round-trips to a JSON object with
        // exactly the three wire-expected keys — no stray fields, no missing.
        let json = serde_json::to_value(&expected).unwrap();
        let obj = json.as_object().unwrap();
        let mut keys: Vec<&str> = obj.keys().map(String::as_str).collect();
        keys.sort();
        assert_eq!(keys, vec!["clearedSkills", "mode", "reason"]);
    }

    #[tokio::test]
    async fn emission_is_suppressed_on_second_call() {
        // Double-dispatch guard: once skills.cleared has been appended, the
        // tracker resets cleared_at_boundary on its `skills.cleared` branch, so
        // a second call to prepare_skill_context_from_session must not emit a
        // duplicate event.
        let ctx = make_test_context();
        let session_id = ctx
            .session_manager
            .create_session("test-model", "/tmp", Some("t"), None)
            .unwrap();
        seed_skill_activated_then_boundary(&ctx.event_store, &session_id);

        let _guard = settings_lock()
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        crate::settings::init_settings(settings_with_policy(CompactionPolicy::AskUser));
        let _ = prepare_skill_context_from_session(
            ctx.skill_registry.clone(),
            ctx.event_store.clone(),
            session_id.clone(),
        )
        .await
        .unwrap();
        let _ = prepare_skill_context_from_session(
            ctx.skill_registry.clone(),
            ctx.event_store.clone(),
            session_id.clone(),
        )
        .await
        .unwrap();
        crate::settings::init_settings(crate::settings::TronSettings::default());
        drop(_guard);

        let events = read_skills_cleared_events(&ctx.event_store, &session_id);
        assert_eq!(events.len(), 1, "duplicate emission suppressed");
    }
}
