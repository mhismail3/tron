use std::collections::HashSet;
use std::fmt::Write;
use std::sync::Arc;

use parking_lot::RwLock;
use serde_json::Value;
use tron_events::{EventStore, EventType, MessagePreview};
use tron_runtime::orchestrator::event_persister::EventPersister;
use tron_runtime::orchestrator::session_manager::SessionManager;
use tron_runtime::orchestrator::session_reconstructor::ReconstructedState;
use tron_skills::registry::SkillRegistry;
use tron_skills::types::SkillMetadata;

use crate::rpc::context::run_blocking_task;
use crate::rpc::errors::RpcError;
use crate::rpc::session_context::{ContextArtifactsService, collect_dynamic_rule_paths};

/// Extract skill/spell names from a JSON array.
///
/// Clients may send objects `[{name: "skill-name", source: "global"}]` or
/// plain strings `["skill-name"]`. This handles both.
pub fn extract_skills(value: Option<&Value>) -> Vec<String> {
    value
        .and_then(|v| v.as_array())
        .map(|arr| {
            arr.iter()
                .filter_map(|v| {
                    v.get("name")
                        .and_then(|n| n.as_str())
                        .or_else(|| v.as_str())
                        .map(String::from)
                })
                .collect()
        })
        .unwrap_or_default()
}

/// Build the JSON payload for a `message.user` event.
///
/// When the prompt includes images, attachments, skills, or spells, the payload
/// is enriched so that session resume can reconstruct client UI chips and the
/// LLM can see previously-sent images in reconstructed history.
pub fn build_user_event_payload(
    prompt: &str,
    images: Option<&[Value]>,
    attachments: Option<&[Value]>,
    raw_skills: Option<&[Value]>,
    raw_spells: Option<&[Value]>,
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
    if let Some(skills) = raw_skills.filter(|s| !s.is_empty()) {
        payload["skills"] = Value::Array(skills.to_vec());
    }
    if let Some(spells) = raw_spells.filter(|s| !s.is_empty()) {
        payload["spells"] = Value::Array(spells.to_vec());
    }
    payload
}

pub fn build_user_content_override(
    prompt: &str,
    model: &str,
    images: Option<&[Value]>,
    attachments: Option<&[Value]>,
) -> Option<tron_core::messages::UserMessageContent> {
    let has_images = images.is_some_and(|v| !v.is_empty());
    let has_attachments = attachments.is_some_and(|v| !v.is_empty());
    if !has_images && !has_attachments {
        return None;
    }

    let mut blocks = vec![tron_core::content::UserContent::Text {
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
                blocks.push(tron_core::content::UserContent::Image {
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
                    blocks.push(tron_core::content::UserContent::Image {
                        data: data.to_owned(),
                        mime_type: mime.to_owned(),
                    });
                } else {
                    blocks.push(tron_core::content::UserContent::Document {
                        data: data.to_owned(),
                        mime_type: mime.to_owned(),
                        file_name,
                    });
                }
            }
        }
    }

    if !tron_llm::model_supports_images(model) {
        blocks.retain(|block| !matches!(block, tron_core::content::UserContent::Image { .. }));
    }

    (blocks.len() > 1).then_some(tron_core::messages::UserMessageContent::Blocks(blocks))
}

#[derive(Default)]
pub struct PromptContextArtifacts {
    pub rules_content: Option<String>,
    pub rules_index: Option<tron_runtime::context::rules_index::RulesIndex>,
    pub pre_activated_rules: Vec<String>,
    pub workspace_id: Option<String>,
}

pub struct PromptBootstrapData {
    pub artifacts: PromptContextArtifacts,
    pub subagent_results_context: Option<String>,
}

pub struct ResumedPromptSession {
    pub state: ReconstructedState,
    pub persister: Arc<EventPersister>,
}

pub struct SessionUpdateData {
    pub session: tron_events::sqlite::row_types::SessionRow,
    pub preview: Option<MessagePreview>,
}

fn load_prompt_context_artifacts(
    context_artifacts: &ContextArtifactsService,
    event_store: &tron_events::EventStore,
    session_id: &str,
    working_dir: &str,
    settings: &tron_settings::TronSettings,
    is_chat: bool,
    is_resumed: bool,
) -> PromptContextArtifacts {
    if is_chat {
        return PromptContextArtifacts::default();
    }

    let artifacts = context_artifacts.load(event_store, working_dir, settings, is_chat);
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
    event_store: &tron_events::EventStore,
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
        let task = payload.get("task").and_then(Value::as_str).unwrap_or("unknown");
        let total_turns = payload.get("totalTurns").and_then(Value::as_i64).unwrap_or(0);
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

/// Gather recent event types and Bash tool call commands since the last compact.boundary.
///
/// Returns `(event_types, bash_commands)` for the compaction trigger's progress-signal check.
pub fn gather_recent_events(
    event_store: &tron_events::EventStore,
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
                &tron_events::sqlite::repositories::event::ListEventsOptions::default(),
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
    settings: tron_settings::TronSettings,
    is_chat: bool,
    is_resumed: bool,
) -> Result<PromptBootstrapData, RpcError> {
    run_blocking_task("agent.prompt.bootstrap", move || {
        let artifacts = load_prompt_context_artifacts(
            context_artifacts.as_ref(),
            event_store.as_ref(),
            &session_id,
            &working_dir,
            &settings,
            is_chat,
            is_resumed,
        );

        let pending = get_pending_subagent_results(event_store.as_ref(), &session_id);
        let subagent_results_context = if pending.is_empty() {
            None
        } else {
            let event_ids: Vec<String> = pending.iter().map(|(id, _)| id.clone()).collect();
            let formatted = format_subagent_results(&pending);
            if formatted.is_some() {
                let _ = event_store.append(&tron_events::AppendOptions {
                    session_id: &session_id,
                    event_type: EventType::SubagentResultsConsumed,
                    payload: serde_json::json!({
                        "consumedEventIds": event_ids,
                        "count": pending.len(),
                    }),
                    parent_id: None,
                });
            }
            formatted
        };

        Ok(PromptBootstrapData {
            artifacts,
            subagent_results_context,
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
        let _ = event_store.append(&tron_events::AppendOptions {
            session_id: &session_id,
            event_type: tron_events::EventType::MessageUser,
            payload,
            parent_id: None,
        });
        Ok(())
    })
    .await
}

pub async fn build_skill_context(
    skill_registry: Arc<RwLock<SkillRegistry>>,
    event_store: Arc<EventStore>,
    session_id: String,
    skills: Option<Vec<String>>,
    spells: Option<Vec<String>>,
) -> Result<Option<String>, RpcError> {
    run_blocking_task("agent.prompt.skills", move || {
        let mut all_names = skills.unwrap_or_default();
        if let Some(spell_names) = spells {
            for name in spell_names {
                if !all_names.contains(&name) {
                    all_names.push(name);
                }
            }
        }

        if all_names.is_empty() {
            return Ok(None);
        }

        let found: Vec<SkillMetadata> = {
            let registry = skill_registry.read();
            let name_refs: Vec<&str> = all_names.iter().map(String::as_str).collect();
            let (found, _not_found) = registry.get_many(&name_refs);
            found.into_iter().cloned().collect()
        };

        if found.is_empty() {
            return Ok(None);
        }

        let existing = event_store
            .get_events_by_type(&session_id, &["skill.added"], None)
            .unwrap_or_default();
        let existing_names: HashSet<String> = existing
            .iter()
            .filter_map(|event| {
                serde_json::from_str::<serde_json::Value>(&event.payload)
                    .ok()
                    .and_then(|payload| {
                        payload
                            .get("skillName")
                            .and_then(|value| value.as_str())
                            .map(String::from)
                    })
            })
            .collect();

        for skill in &found {
            if !existing_names.contains(&skill.name) {
                let _ = event_store.append(&tron_events::AppendOptions {
                    session_id: &session_id,
                    event_type: tron_events::EventType::SkillAdded,
                    payload: serde_json::json!({
                        "skillName": skill.name,
                        "source": skill.source.to_string(),
                        "addedVia": "mention",
                        "tokens": skill.content.len() as u64 / 4,
                    }),
                    parent_id: None,
                });
            }
        }

        let skill_refs: Vec<&SkillMetadata> = found.iter().collect();
        let context = tron_skills::injector::build_skill_context(&skill_refs);
        Ok((!context.is_empty()).then_some(context))
    })
    .await
}

pub async fn load_recent_events(
    event_store: Arc<EventStore>,
    session_id: String,
) -> Result<(Vec<String>, Vec<String>), RpcError> {
    run_blocking_task("agent.prompt.recent_events", move || {
        Ok(gather_recent_events(event_store.as_ref(), &session_id))
    })
    .await
}

pub async fn load_session_model(
    session_manager: Arc<SessionManager>,
    session_id: String,
) -> Result<Option<String>, RpcError> {
    run_blocking_task("agent.prompt.session_model", move || {
        let session = session_manager
            .get_session(&session_id)
            .map_err(|error| RpcError::Internal {
                message: error.to_string(),
            })?;
        Ok(session.map(|session| session.latest_model))
    })
    .await
}

pub async fn load_session_update_data(
    session_manager: Arc<SessionManager>,
    event_store: Arc<EventStore>,
    session_id: String,
) -> Result<Option<SessionUpdateData>, RpcError> {
    run_blocking_task("agent.prompt.session_update", move || {
        let session = session_manager
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

        Ok(Some(SessionUpdateData { session, preview }))
    })
    .await
}
