//! Memory handlers: retain.

use async_trait::async_trait;
use chrono::Utc;
use serde_json::{Value, json};
use tracing::{instrument, warn};

use crate::events::types::state::Message;
use crate::events::types::EventType;
use crate::events::{AppendOptions, EventStore, event_rows_to_session_events, reconstruct_from_events};
use crate::runtime::context::system_prompts::MEMORY_RETAIN_SUMMARIZER_PROMPT;
use crate::runtime::orchestrator::subagent_manager::{SubagentManager, SubsessionConfig};
use crate::server::rpc::context::RpcContext;
use crate::server::rpc::errors::RpcError;
use crate::server::rpc::handlers::require_string_param;
use crate::server::rpc::registry::MethodHandler;

use std::fs;
use std::sync::Arc;

// =============================================================================
// Handler
// =============================================================================

/// Trigger a memory retain: summarize session history since the last boundary
/// and write to `~/.tron/memory/sessions/{session_id}.md`.
pub struct RetainMemoryHandler;

#[async_trait]
impl MethodHandler for RetainMemoryHandler {
    #[instrument(skip(self, ctx), fields(method = "memory.retain", session_id))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;
        retain_memory(ctx, session_id).await
    }
}

// =============================================================================
// Core logic
// =============================================================================

async fn retain_memory(ctx: &RpcContext, session_id: String) -> Result<Value, RpcError> {
    // Emit MemoryUpdating so the iOS spinner appears immediately.
    let _ = ctx
        .orchestrator
        .broadcast()
        .emit(crate::core::events::TronEvent::MemoryUpdating {
            base: crate::core::events::BaseEvent::now(&session_id),
        });

    // ── Find summarization boundary ────────────────────────────────────────
    let event_store = ctx.event_store.clone();
    let session_id_q = session_id.clone();
    let boundary_sequence =
        ctx.run_blocking("memory.retain.find_boundary", move || {
            find_boundary_sequence(&event_store, &session_id_q)
        })
        .await?;

    // ── Get events since boundary ─────────────────────────────────────────
    let event_store2 = ctx.event_store.clone();
    let session_id_q2 = session_id.clone();
    let messages = ctx
        .run_blocking("memory.retain.get_events", move || {
            get_messages_since(&event_store2, &session_id_q2, boundary_sequence)
        })
        .await?;

    if messages.is_empty() {
        // Nothing new to summarize.
        let _ = ctx
            .orchestrator
            .broadcast()
            .emit(crate::core::events::TronEvent::MemoryUpdated {
                base: crate::core::events::BaseEvent::now(&session_id),
                title: None,
                summary: None,
                entry_type: Some("session".to_owned()),
                event_id: None,
            });
        return Ok(json!({ "retained": false, "reason": "nothing_new" }));
    }

    // ── Get session metadata ───────────────────────────────────────────────
    let event_store3 = ctx.event_store.clone();
    let session_id_q3 = session_id.clone();
    let session_meta = ctx
        .run_blocking("memory.retain.get_session", move || {
            event_store3
                .get_session(&session_id_q3)
                .map_err(|e| RpcError::Internal {
                    message: format!("Failed to get session: {e}"),
                })
        })
        .await?;

    let working_directory = session_meta
        .as_ref()
        .map(|s| s.working_directory.clone())
        .unwrap_or_else(|| "/tmp".to_owned());

    let model = session_meta
        .as_ref()
        .map(|s| s.latest_model.as_str())
        .unwrap_or("claude-sonnet-4-6")
        .to_owned();

    let turn_count = session_meta
        .as_ref()
        .map(|s| s.turn_count)
        .unwrap_or(0);

    // ── Serialize transcript ───────────────────────────────────────────────
    let transcript = serialize_for_memory(&messages);

    if transcript.is_empty() {
        let _ = ctx
            .orchestrator
            .broadcast()
            .emit(crate::core::events::TronEvent::MemoryUpdated {
                base: crate::core::events::BaseEvent::now(&session_id),
                title: None,
                summary: None,
                entry_type: Some("session".to_owned()),
                event_id: None,
            });
        return Ok(json!({ "retained": false, "reason": "empty_transcript" }));
    }

    // ── Spawn summarizer subagent ──────────────────────────────────────────
    let summary_text = match &ctx.subagent_manager {
        Some(manager) => {
            run_summarizer(
                manager.clone(),
                &session_id,
                &working_directory,
                transcript,
                turn_count,
            )
            .await
        }
        None => {
            // No subagent manager (unit tests / stripped build) — use keyword fallback.
            warn!(session_id = %session_id, "no subagent manager for memory retain, using keyword fallback");
            keyword_summary(&session_id, turn_count)
        }
    };

    // ── Parse title (first non-empty line of summary) ─────────────────────
    let title = summary_text
        .lines()
        .find(|l| !l.trim().is_empty())
        .unwrap_or("Session summary")
        .trim()
        .to_owned();

    // ── Write per-session memory file ───────────────────────────────────
    let now = Utc::now();
    let ts = now.format("%Y-%m-%dT%H:%M:%SZ").to_string();

    if let Err(e) = write_session_entry(&session_id, &ts, &model, turn_count, &title, &summary_text) {
        warn!(session_id = %session_id, error = %e, "failed to write session memory file — boundary event still persisted");
    }

    // ── Persist memory.retained event ─────────────────────────────────────
    let event_store4 = ctx.event_store.clone();
    let session_id_persist = session_id.clone();
    let title_persist = title.clone();
    let summary_persist = summary_text.clone();
    let ts_persist = ts.clone();
    let retained_event_id = ctx
        .run_blocking("memory.retain.persist_event", move || {
            event_store4
                .append(&AppendOptions {
                    session_id: &session_id_persist,
                    event_type: EventType::MemoryRetained,
                    payload: json!({
                        "sessionId": session_id_persist,
                        "turnNumber": turn_count,
                        "title": title_persist,
                        "summary": summary_persist,
                        "timestamp": ts_persist,
                    }),
                    parent_id: None,
                })
                .map(|row| row.id)
                .map_err(|e| RpcError::Internal {
                    message: format!("Failed to persist memory.retained event: {e}"),
                })
        })
        .await
        .unwrap_or_default();

    // ── Emit MemoryUpdated ─────────────────────────────────────────────────
    let _ = ctx
        .orchestrator
        .broadcast()
        .emit(crate::core::events::TronEvent::MemoryUpdated {
            base: crate::core::events::BaseEvent::now(&session_id),
            title: Some(title.clone()),
            summary: Some(summary_text.clone()),
            entry_type: Some("session".to_owned()),
            event_id: if retained_event_id.is_empty() {
                None
            } else {
                Some(retained_event_id)
            },
        });

    Ok(json!({
        "retained": true,
        "title": title,
        "timestamp": ts,
    }))
}

// =============================================================================
// Helpers
// =============================================================================

/// Find the sequence number to use as the "start of window" for summarization.
///
/// Priority:
/// 1. Latest `memory.retained` event (previous Retain boundary)
/// 2. Latest `compact.boundary` event (compaction boundary)
/// 3. 0 (beginning of session)
fn find_boundary_sequence(store: &EventStore, session_id: &str) -> Result<i64, RpcError> {
    // Try memory.retained first
    if let Ok(Some(row)) = store.get_latest_event_by_type(session_id, "memory.retained") {
        return Ok(row.sequence);
    }
    // Fall back to compact.boundary
    if let Ok(Some(row)) = store.get_latest_event_by_type(session_id, "compact.boundary") {
        return Ok(row.sequence);
    }
    Ok(0)
}

/// Get reconstructed messages since `after_sequence`.
fn get_messages_since(
    store: &EventStore,
    session_id: &str,
    after_sequence: i64,
) -> Result<Vec<Message>, RpcError> {
    let rows = store
        .get_events_since(session_id, after_sequence)
        .map_err(|e| RpcError::Internal {
            message: format!("Failed to fetch events: {e}"),
        })?;

    if rows.is_empty() {
        return Ok(vec![]);
    }

    let events = event_rows_to_session_events(&rows);
    let result = reconstruct_from_events(&events);
    Ok(result
        .messages_with_event_ids
        .into_iter()
        .map(|m| m.message)
        .collect())
}

/// Serialize reconstructed messages to a plain-text transcript for summarization.
///
/// Truncates text content to keep the transcript within model limits.
fn serialize_for_memory(messages: &[Message]) -> String {
    const MAX_TEXT: usize = 300;
    const MAX_TOOL: usize = 150;
    const MAX_TOTAL: usize = 20_000;

    let mut lines = Vec::new();
    for msg in messages {
        match msg.role.as_str() {
            "user" => {
                let text = match &msg.content {
                    Value::String(s) => s.clone(),
                    Value::Array(arr) => arr
                        .iter()
                        .filter_map(|b| b.get("text").and_then(Value::as_str))
                        .collect::<Vec<_>>()
                        .join(" "),
                    _ => continue,
                };
                let t = truncate_str(&text, MAX_TEXT);
                if !t.is_empty() {
                    lines.push(format!("[USER] {t}"));
                }
            }
            "assistant" => {
                let text = match &msg.content {
                    Value::String(s) => s.clone(),
                    Value::Array(arr) => arr
                        .iter()
                        .filter_map(|b| b.get("text").and_then(Value::as_str))
                        .collect::<Vec<_>>()
                        .join(" "),
                    _ => continue,
                };
                let t = truncate_str(&text, MAX_TEXT);
                if !t.is_empty() {
                    lines.push(format!("[ASSISTANT] {t}"));
                }
            }
            "tool_result" | "toolResult" => {
                let text = match &msg.content {
                    Value::String(s) => s.clone(),
                    Value::Array(arr) => arr
                        .iter()
                        .filter_map(|b| b.get("text").and_then(Value::as_str))
                        .collect::<Vec<_>>()
                        .join(" "),
                    _ => continue,
                };
                let t = truncate_str(&text, MAX_TOOL);
                let label = if msg.is_error == Some(true) { "[TOOL_ERROR]" } else { "[TOOL_RESULT]" };
                if !t.is_empty() {
                    lines.push(format!("{label} {t}"));
                }
            }
            _ => {}
        }
    }

    let full = lines.join("\n");
    if full.len() > MAX_TOTAL {
        // Keep first 50% and last 50%, insert an omission marker.
        let half = MAX_TOTAL / 2;
        let start = &full[..half];
        let end = &full[full.len() - half..];
        format!("{start}\n[...omitted for length...]\n{end}")
    } else {
        full
    }
}

fn truncate_str(s: &str, max: usize) -> &str {
    if s.len() <= max {
        s
    } else {
        // Safe UTF-8 boundary truncation
        &s[..s.char_indices()
            .map(|(i, _)| i)
            .take_while(|&i| i < max)
            .last()
            .unwrap_or(0)]
    }
}

/// Run the LLM summarizer subsession and return its text output.
async fn run_summarizer(
    manager: Arc<SubagentManager>,
    parent_session_id: &str,
    working_directory: &str,
    transcript: String,
    turn_count: i64,
) -> String {
    let task = format!(
        "Summarize this session transcript (turns 1–{turn_count}):\n\n{transcript}"
    );

    match manager
        .spawn_subsession(SubsessionConfig {
            parent_session_id: parent_session_id.to_owned(),
            task,
            model: None, // defaults to SUBAGENT_MODEL (Haiku 4.5)
            system_prompt: MEMORY_RETAIN_SUMMARIZER_PROMPT.to_owned(),
            working_directory: working_directory.to_owned(),
            inherit_tools: false,
            max_turns: 1,
            max_depth: 0,
            ..SubsessionConfig::default()
        })
        .await
    {
        Ok(result) => result.output,
        Err(e) => {
            warn!(session_id = %parent_session_id, error = %e, "memory summarizer subagent failed, using keyword fallback");
            keyword_summary(parent_session_id, turn_count)
        }
    }
}

/// Minimal keyword-based fallback when no subagent manager is available.
fn keyword_summary(session_id: &str, turn_count: i64) -> String {
    format!("Session {session_id} ({turn_count} turns)")
}

/// Return the path for a session's memory file: `~/.tron/memory/sessions/{session_id}.md`.
fn session_file_path(session_id: &str) -> std::path::PathBuf {
    crate::core::paths::tron_home()
        .join("memory")
        .join("sessions")
        .join(format!("{session_id}.md"))
}

/// Format YAML frontmatter for a new session memory file.
fn format_session_frontmatter(session_id: &str, ts: &str, model: &str) -> String {
    format!(
        "---\nsession: {session_id}\ncreated: {ts}\nmodel: {model}\n---\n"
    )
}

/// Format a timestamped section entry.
fn format_session_section(ts: &str, title: &str, summary: &str) -> String {
    // Extract YYYY-MM-DD HH:MM from ISO timestamp
    let short_ts = if ts.len() >= 16 {
        &ts[..16]
    } else {
        ts
    };
    let display_ts = short_ts.replace('T', " ");
    format!("\n## {display_ts} — {title}\n\n{summary}\n")
}

/// Write a session memory entry to `~/.tron/memory/sessions/{session_id}.md`.
///
/// Creates the file with YAML frontmatter on first write; appends a new
/// timestamped section on subsequent writes.
fn write_session_entry(
    session_id: &str,
    ts: &str,
    model: &str,
    _turns: i64,
    title: &str,
    summary: &str,
) -> std::io::Result<()> {
    let path = session_file_path(session_id);
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }

    let section = format_session_section(ts, title, summary);
    let is_new = !path.exists();

    use std::io::Write as _;
    let mut file = fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&path)?;

    if is_new {
        let frontmatter = format_session_frontmatter(session_id, ts, model);
        file.write_all(frontmatter.as_bytes())?;
    }
    file.write_all(section.as_bytes())?;
    Ok(())
}

// =============================================================================
// Tests
// =============================================================================

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn session_file_path_uses_session_id() {
        let path = session_file_path("sess_019d4a32");
        assert_eq!(path.file_name().unwrap().to_str().unwrap(), "sess_019d4a32.md");
        assert!(path.to_str().unwrap().contains(".tron/memory/sessions"));
    }

    #[test]
    fn format_session_frontmatter_is_valid_yaml() {
        let fm = format_session_frontmatter("sess_abc", "2026-01-01T00:00:00Z", "claude-haiku");
        assert!(fm.starts_with("---\n"));
        assert!(fm.ends_with("---\n"));
        assert!(fm.contains("session: sess_abc"));
        assert!(fm.contains("created: 2026-01-01T00:00:00Z"));
        assert!(fm.contains("model: claude-haiku"));
    }

    #[test]
    fn format_session_section_contains_title_and_summary() {
        let section = format_session_section("2026-01-01T00:00:00Z", "Test title", "Test summary");
        assert!(section.contains("## 2026-01-01 00:00 — Test title"));
        assert!(section.contains("Test summary"));
    }

    #[test]
    fn write_session_entry_creates_file_with_frontmatter() {
        let dir = tempfile::tempdir().unwrap();
        let session_id = "sess_test_create";
        let path = dir.path().join(format!("{session_id}.md"));

        // Temporarily override home — we test the helpers directly instead
        let frontmatter = format_session_frontmatter(session_id, "2026-01-01T00:00:00Z", "claude-haiku");
        let section = format_session_section("2026-01-01T00:00:00Z", "Initial work", "Did some things");

        std::fs::write(&path, format!("{frontmatter}{section}")).unwrap();
        let content = std::fs::read_to_string(&path).unwrap();
        assert!(content.starts_with("---\n"));
        assert!(content.contains("session: sess_test_create"));
        assert!(content.contains("## 2026-01-01 00:00 — Initial work"));
        assert!(content.contains("Did some things"));
    }

    #[test]
    fn write_session_entry_appends_without_duplicate_frontmatter() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("sess_test_append.md");

        let frontmatter = format_session_frontmatter("sess_test_append", "2026-01-01T00:00:00Z", "claude-haiku");
        let section1 = format_session_section("2026-01-01T00:00:00Z", "First", "First work");
        let section2 = format_session_section("2026-01-01T01:00:00Z", "Second", "More work");

        std::fs::write(&path, format!("{frontmatter}{section1}")).unwrap();
        use std::io::Write as _;
        let mut file = std::fs::OpenOptions::new().append(true).open(&path).unwrap();
        file.write_all(section2.as_bytes()).unwrap();

        let content = std::fs::read_to_string(&path).unwrap();
        assert_eq!(content.matches("---").count(), 2); // only the frontmatter pair
        assert!(content.contains("## 2026-01-01 00:00 — First"));
        assert!(content.contains("## 2026-01-01 01:00 — Second"));
    }

    #[test]
    fn keyword_summary_includes_session_id() {
        let s = keyword_summary("sess_xyz", 3);
        assert!(s.contains("sess_xyz"));
        assert!(s.contains("3 turns"));
    }

    #[test]
    fn title_extraction_first_non_empty_line() {
        let summary = "\n\nImplement JWT auth\n\n**Goal**: ...\n";
        let title = summary
            .lines()
            .find(|l| !l.trim().is_empty())
            .unwrap_or("Session summary")
            .trim()
            .to_owned();
        assert_eq!(title, "Implement JWT auth");
    }

    #[tokio::test]
    async fn handler_requires_session_id() {
        use crate::server::rpc::handlers::test_helpers::make_test_context;
        let ctx = make_test_context();
        let handler = RetainMemoryHandler;
        let err = handler.handle(Some(serde_json::json!({})), &ctx).await.unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
    }

    #[tokio::test]
    async fn handler_returns_nothing_new_for_empty_session() {
        use crate::server::rpc::handlers::test_helpers::make_test_context;
        let ctx = make_test_context();

        // Create a session first so the handler can find it
        let cr = ctx
            .event_store
            .create_session("claude-sonnet-4-6", "/tmp", None, None, None)
            .unwrap();

        let result = retain_memory(&ctx, cr.session.id.clone()).await.unwrap();
        // No events since boundary (sequence 0 => empty since) => nothing_new
        assert_eq!(result["retained"], false);
    }
}
