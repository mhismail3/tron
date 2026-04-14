use std::collections::HashSet;
use std::fmt::Write;
use std::sync::Arc;

use parking_lot::RwLock;
use serde_json::Value;
use crate::events::{ActivitySummaryLine, EventStore, EventType, MessagePreview};
use crate::runtime::orchestrator::event_persister::EventPersister;
use crate::runtime::orchestrator::session_manager::SessionManager;
use crate::runtime::orchestrator::session_reconstructor::ReconstructedState;
use crate::skills::registry::SkillRegistry;
use crate::skills::types::SkillMetadata;

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
    payload
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
                    let extracted_text =
                        crate::core::document_extractor::extract_text(data, mime);
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
        .filter_map(|event| {
            serde_json::from_str::<Value>(&event.payload)
                .ok()
                .map(|payload| (event.id, payload))
        })
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
        .filter_map(|event| {
            serde_json::from_str::<Value>(&event.payload)
                .ok()
                .map(|payload| (event.id, payload))
        })
        .collect()
}

/// Format pending process results into markdown context string.
pub fn format_process_results(results: &[(String, Value)]) -> Option<String> {
    if results.is_empty() {
        return None;
    }

    let mut ctx = String::from("# Completed Background Processes\n\n");
    ctx.push_str(
        "The following background process(es) have completed since your last turn.\n\n",
    );

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
        .filter_map(|event| {
            serde_json::from_str::<Value>(&event.payload)
                .ok()
                .map(|payload| (event.id, payload))
        })
        .collect()
}

/// Format user job actions into a system message for context injection.
pub fn format_user_job_actions(actions: &[(String, Value)]) -> String {
    let mut ctx = String::from("# User Job Actions\n\n");
    for (_event_id, action) in actions {
        let job_id = action.get("jobId").and_then(Value::as_str).unwrap_or("unknown");
        let action_type = action.get("action").and_then(Value::as_str).unwrap_or("unknown");
        let label = action.get("label").and_then(Value::as_str).unwrap_or("unknown");
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
            let event_ids: Vec<String> = user_job_actions.iter().map(|(id, _)| id.clone()).collect();
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

/// Build skill context from server-owned session state.
///
/// Reconstructs the [`SkillTracker`] from events, looks up active skills
/// and unconsumed spells in the registry, and builds the `<skills>` XML block.
///
/// Also writes `spell.consumed` events for any spells that are consumed, and
/// returns the removal notice for recently deactivated skills.
pub async fn build_skill_context_from_session(
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

        // For AskUser policy, emit skills.cleared event once after compaction
        if matches!(policy, crate::settings::types::CompactionPolicy::AskUser) {
            let cleared = tracker.cleared_at_boundary();
            if !cleared.is_empty() {
                let _ = event_store.append(&crate::events::AppendOptions {
                    session_id: &session_id,
                    event_type: crate::events::EventType::SkillsCleared,
                    payload: serde_json::json!({
                        "clearedSkills": cleared,
                        "reason": "compaction",
                    }),
                    parent_id: None,
                    sequence: None,
                });
            }
        }

        // Collect active skill names + unconsumed spell names
        let active_names = tracker.active_skill_names();
        let unconsumed_spells = tracker.unconsumed_spells().to_vec();
        let spell_names: Vec<String> = unconsumed_spells.iter().map(|s| s.name.clone()).collect();

        tracing::info!(
            active_count = tracker.count(),
            active_skills = ?active_names,
            pending_spells = ?spell_names,
            "[skills] reconstructed tracker for session {session_id}"
        );

        // Save skill-only names for the activation directive (before merge)
        let skill_only_names = active_names.clone();

        // Merge active skills + spell names (dedup)
        let mut all_names: Vec<String> = active_names;
        for name in &spell_names {
            if !all_names.contains(name) {
                all_names.push(name.clone());
            }
        }

        // Look up metadata from registry
        let found: Vec<SkillMetadata> = if all_names.is_empty() {
            Vec::new()
        } else {
            let registry = skill_registry.read();
            let name_refs: Vec<&str> = all_names.iter().map(String::as_str).collect();
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

        // Write spell.consumed events for consumed spells
        for spell in &unconsumed_spells {
            let _ = event_store.append(&crate::events::AppendOptions {
                session_id: &session_id,
                event_type: crate::events::EventType::SpellConsumed,
                payload: serde_json::json!({
                    "spellName": spell.name,
                    "castEventId": spell.event_id,
                }),
                parent_id: None,
                sequence: None,
            });
        }

        // Build activation directive for active skills + spells
        let skill_activation_context =
            crate::skills::injector::build_activation_directive(&skill_only_names, &spell_names);

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
    /// Activation directive ("follow these active skills/spells").
    pub skill_activation_context: Option<String>,
    /// The `<skills>` XML block for active skills + consumed spells.
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

        Ok(Some(SessionUpdateData { session, preview, activity_lines }))
    })
    .await
}
