//! Memory handlers: retain.
//!
//! The retain system is the bridge between ephemeral conversations and
//! persistent memory. It runs as an async background task (non-blocking)
//! and acts as a smart router:
//!
//! - **Always** writes a journal entry to `~/.tron/workspace/memory/sessions/`
//! - **Conditionally** updates core memories in `~/.tron/workspace/memory/rules/`
//! - **Conditionally** creates argument docs in `~/.tron/workspace/knowledge/arguments/`
//!
//! The summarizer uses Sonnet 4.6 and produces structured output with `<journal>`,
//! `<core_memory>`, and `<argument>` sections that the handler parses and routes
//! to the right files. The `memory.retainModel` setting is plumbed through iOS
//! for future configurability.

use async_trait::async_trait;
use chrono::Utc;
use serde_json::{Value, json};
use tracing::{debug, instrument, warn};

use crate::events::types::state::Message;
use crate::events::types::EventType;
use crate::events::{AppendOptions, EventStore, event_rows_to_session_events, reconstruct_from_events};
use crate::runtime::context::system_prompts::MEMORY_RETAIN_SUMMARIZER_PROMPT;
use crate::runtime::agent::event_emitter::EventEmitter;
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
/// and write to `~/.tron/workspace/memory/sessions/{session_id}.md`.
///
/// This handler is non-blocking — it emits `MemoryUpdating` immediately,
/// spawns the summarizer as a background task, and returns. The background
/// task emits `MemoryUpdated` when done.
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
                entry_type: Some("journal".to_owned()),
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
                entry_type: Some("journal".to_owned()),
                event_id: None,
            });
        return Ok(json!({ "retained": false, "reason": "empty_transcript" }));
    }

    // ── Spawn background retain task ────────────────────────────────────────
    // The handler returns immediately. The background task runs the summarizer,
    // parses the output, writes files, and emits MemoryUpdated when done.
    let bg_session_id = session_id.clone();
    let bg_event_store = ctx.event_store.clone();
    let bg_broadcast = Arc::clone(ctx.orchestrator.broadcast());
    let bg_subagent_manager = ctx.subagent_manager.clone();

    let _ = tokio::spawn(async move {
        retain_background_task(
            bg_session_id,
            bg_event_store,
            bg_broadcast,
            bg_subagent_manager,
            working_directory,
            model,
            turn_count,
            transcript,
        )
        .await;
    });

    Ok(json!({
        "retained": true,
        "status": "retaining",
    }))
}

/// Background task that runs the summarizer and writes results.
async fn retain_background_task(
    session_id: String,
    event_store: Arc<EventStore>,
    broadcast: Arc<EventEmitter>,
    subagent_manager: Option<Arc<SubagentManager>>,
    working_directory: String,
    model: String,
    turn_count: i64,
    transcript: String,
) {
    // ── Run summarizer ──────────────────────────────────────────────────────
    let raw_output = match subagent_manager {
        Some(manager) => {
            run_summarizer(
                manager,
                &session_id,
                &working_directory,
                transcript,
                turn_count,
            )
            .await
        }
        None => {
            warn!(session_id = %session_id, "no subagent manager for memory retain, using keyword fallback");
            keyword_summary(&session_id, turn_count)
        }
    };

    // ── Parse structured output ─────────────────────────────────────────────
    let parsed = parse_retain_output(&raw_output);

    let journal_text = parsed.journal.as_deref().unwrap_or(&raw_output);

    // ── Extract title (first non-empty line of journal) ─────────────────────
    let title = journal_text
        .lines()
        .find(|l| !l.trim().is_empty())
        .unwrap_or("Session summary")
        .trim()
        .to_owned();

    // ── Write journal entry (always) ────────────────────────────────────────
    let now = Utc::now();
    let ts = now.format("%Y-%m-%dT%H:%M:%SZ").to_string();

    if let Err(e) = write_session_entry(&session_id, &ts, &model, turn_count, &title, journal_text) {
        warn!(session_id = %session_id, error = %e, "failed to write session journal file");
    }

    // ── Track what was produced ─────────────────────────────────────────────
    let mut entry_type_parts = vec!["journal"];

    // ── Write core memory update (conditional) ──────────────────────────────
    if let Some(ref cm) = parsed.core_memory {
        let path = core_memory_file_path(&cm.file);
        if let Err(e) = write_core_memory_update(&path, &cm.update) {
            warn!(session_id = %session_id, error = %e, "failed to write core memory update");
        } else {
            debug!(session_id = %session_id, file = %cm.file, "updated core memory");
            entry_type_parts.push("memory");
        }
    }

    // ── Write argument (conditional) ────────────────────────────────────────
    if let Some(ref arg) = parsed.argument {
        let slug = slugify(&arg.title);
        let path = argument_file_path(&slug);
        if let Err(e) = write_argument_entry(&path, arg) {
            warn!(session_id = %session_id, error = %e, "failed to write argument");
        } else {
            debug!(session_id = %session_id, slug = %slug, "created argument");
            entry_type_parts.push("argument");
        }
    }

    let entry_type = entry_type_parts.join("+");

    // ── Persist memory.retained event ───────────────────────────────────────
    let retained_event_id = event_store
        .append(&AppendOptions {
            session_id: &session_id,
            event_type: EventType::MemoryRetained,
            payload: json!({
                "sessionId": session_id,
                "turnNumber": turn_count,
                "title": title,
                "summary": journal_text,
                "timestamp": ts,
                "entryType": entry_type,
            }),
            parent_id: None,
            sequence: None,
        })
        .map(|row| row.id)
        .unwrap_or_default();

    // ── Emit MemoryUpdated ──────────────────────────────────────────────────
    let _ = broadcast.emit(crate::core::events::TronEvent::MemoryUpdated {
        base: crate::core::events::BaseEvent::now(&session_id),
        title: Some(title),
        summary: Some(raw_output),
        entry_type: Some(entry_type),
        event_id: if retained_event_id.is_empty() {
            None
        } else {
            Some(retained_event_id)
        },
    });
}

// =============================================================================
// Output parsing
// =============================================================================

/// Parsed output from the smart router summarizer.
#[derive(Debug, Default)]
struct RetainOutput {
    journal: Option<String>,
    core_memory: Option<CoreMemoryUpdate>,
    argument: Option<ArgumentContent>,
}

/// A core memory update to write to `memory/rules/{file}`.
#[derive(Debug)]
struct CoreMemoryUpdate {
    file: String,
    update: String,
}

/// Argument content to write to `knowledge/arguments/{slug}.md`.
#[derive(Debug)]
struct ArgumentContent {
    title: String,
    thesis: String,
    topics: Vec<String>,
    sources: Vec<String>,
    evidence: String,
}

/// Parse structured retain output with `<journal>`, `<core_memory>`, `<argument>` sections.
///
/// Falls back gracefully: if no tags are found, the entire output is treated as journal.
fn parse_retain_output(raw: &str) -> RetainOutput {
    let mut result = RetainOutput::default();

    // Extract <journal>...</journal>
    if let Some(content) = extract_tag(raw, "journal") {
        result.journal = Some(content);
    }

    // Extract <core_memory>...</core_memory>
    if let Some(content) = extract_tag(raw, "core_memory") {
        result.core_memory = parse_core_memory(&content);
    }

    // Extract <argument>...</argument>
    if let Some(content) = extract_tag(raw, "argument") {
        result.argument = parse_argument(&content);
    }

    // Fallback: if no journal tag found, use the entire raw output
    if result.journal.is_none() {
        result.journal = Some(raw.to_owned());
    }

    result
}

/// Extract content between `<tag>` and `</tag>`.
fn extract_tag(text: &str, tag: &str) -> Option<String> {
    let open = format!("<{tag}>");
    let close = format!("</{tag}>");
    let start = text.find(&open)?;
    let end = text.find(&close)?;
    if end <= start {
        return None;
    }
    Some(text[start + open.len()..end].trim().to_owned())
}

/// Parse core memory update from extracted tag content.
fn parse_core_memory(content: &str) -> Option<CoreMemoryUpdate> {
    let mut file = None;
    let mut update = None;

    for line in content.lines() {
        let line = line.trim();
        if let Some(rest) = line.strip_prefix("file:") {
            file = Some(rest.trim().to_owned());
        } else if let Some(rest) = line.strip_prefix("update:") {
            update = Some(rest.trim().to_owned());
        }
    }

    match (file, update) {
        (Some(f), Some(u)) if !f.is_empty() && !u.is_empty() => {
            Some(CoreMemoryUpdate { file: f, update: u })
        }
        _ => None,
    }
}

/// Parse argument content from extracted tag content.
fn parse_argument(content: &str) -> Option<ArgumentContent> {
    let mut title = None;
    let mut thesis = None;
    let mut topics = Vec::new();
    let mut sources = Vec::new();
    let mut evidence_lines = Vec::new();
    let mut in_evidence = false;

    for line in content.lines() {
        let line_trimmed = line.trim();
        if let Some(rest) = line_trimmed.strip_prefix("title:") {
            title = Some(rest.trim().to_owned());
            in_evidence = false;
        } else if let Some(rest) = line_trimmed.strip_prefix("thesis:") {
            thesis = Some(rest.trim().to_owned());
            in_evidence = false;
        } else if let Some(rest) = line_trimmed.strip_prefix("topics:") {
            topics = parse_bracket_list(rest);
            in_evidence = false;
        } else if let Some(rest) = line_trimmed.strip_prefix("sources:") {
            sources = parse_bracket_list(rest);
            in_evidence = false;
        } else if line_trimmed.starts_with("evidence:") {
            in_evidence = true;
        } else if in_evidence && line_trimmed.starts_with('-') {
            evidence_lines.push(line_trimmed.to_owned());
        }
    }

    let title = title?;
    let thesis = thesis.unwrap_or_default();
    let evidence = evidence_lines.join("\n");

    Some(ArgumentContent {
        title,
        thesis,
        topics,
        sources,
        evidence,
    })
}

/// Parse a bracketed list like `[a, b, c]` into a Vec of strings.
fn parse_bracket_list(s: &str) -> Vec<String> {
    let s = s.trim();
    let s = s.strip_prefix('[').unwrap_or(s);
    let s = s.strip_suffix(']').unwrap_or(s);
    s.split(',')
        .map(|item| item.trim().to_owned())
        .filter(|item| !item.is_empty())
        .collect()
}

/// Convert a title to a kebab-case slug.
fn slugify(title: &str) -> String {
    title
        .to_lowercase()
        .chars()
        .map(|c| if c.is_alphanumeric() { c } else { '-' })
        .collect::<String>()
        .split('-')
        .filter(|s| !s.is_empty())
        .collect::<Vec<_>>()
        .join("-")
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
            model: Some("claude-sonnet-4-6".to_string()),
            system_prompt: MEMORY_RETAIN_SUMMARIZER_PROMPT.to_owned(),
            working_directory: working_directory.to_owned(),
            inherit_tools: false,
            max_turns: 1,
            max_depth: 0,
            blocking_timeout_ms: Some(60_000),
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

// =============================================================================
// File path helpers
// =============================================================================

/// Return the path for a session's journal file: `~/.tron/workspace/memory/sessions/{session_id}.md`.
fn session_file_path(session_id: &str) -> std::path::PathBuf {
    crate::core::paths::memory_sessions_dir()
        .join(format!("{session_id}.md"))
}

/// Return the path for a core memory file: `~/.tron/workspace/memory/rules/{filename}`.
fn core_memory_file_path(filename: &str) -> std::path::PathBuf {
    crate::core::paths::memory_rules_dir().join(filename)
}

/// Return the path for an argument file: `~/.tron/workspace/knowledge/arguments/{slug}.md`.
fn argument_file_path(slug: &str) -> std::path::PathBuf {
    crate::core::paths::knowledge_dir()
        .join("arguments")
        .join(format!("{slug}.md"))
}

// =============================================================================
// File writers
// =============================================================================

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

/// Write a session journal entry to `~/.tron/workspace/memory/sessions/{session_id}.md`.
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

/// Write or append a core memory update to a file in `memory/rules/`.
///
/// Creates the file with frontmatter if it doesn't exist, then appends
/// a timestamped update entry.
fn write_core_memory_update(
    path: &std::path::Path,
    update: &str,
) -> std::io::Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }

    let is_new = !path.exists();
    let now = Utc::now();
    let ts = now.format("%Y-%m-%d %H:%M").to_string();

    use std::io::Write as _;
    let mut file = fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)?;

    if is_new {
        let today = now.format("%Y-%m-%d").to_string();
        let frontmatter = format!(
            "---\ntype: core-memory\ncreated: \"{today}\"\nupdated: \"{today}\"\n---\n\n"
        );
        file.write_all(frontmatter.as_bytes())?;
    }

    let entry = format!("\n## {ts}\n\n- {update}\n");
    file.write_all(entry.as_bytes())?;
    Ok(())
}

/// Write an argument document to `knowledge/arguments/{slug}.md`.
fn write_argument_entry(
    path: &std::path::Path,
    arg: &ArgumentContent,
) -> std::io::Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }

    let today = Utc::now().format("%Y-%m-%d").to_string();
    let topics_yaml = if arg.topics.is_empty() {
        "[]".to_owned()
    } else {
        format!("[{}]", arg.topics.join(", "))
    };
    let sources_yaml = if arg.sources.is_empty() {
        "[]".to_owned()
    } else {
        format!("[{}]", arg.sources.join(", "))
    };

    let content = format!(
        "---\ntype: argument\ntags: []\ntopics: {topics_yaml}\nsources: {sources_yaml}\ncreated: \"{today}\"\norigin: retain\n---\n\n# {title}\n\n## Thesis\n\n{thesis}\n\n## Evidence\n\n{evidence}\n",
        title = arg.title,
        thesis = arg.thesis,
        evidence = arg.evidence,
    );

    fs::write(path, content)?;
    Ok(())
}

// =============================================================================
// Tests
// =============================================================================

#[cfg(test)]
mod tests {
    use super::*;

    // ── Path tests ──────────────────────────────────────────────────────

    #[test]
    fn session_file_path_uses_memory_sessions() {
        let path = session_file_path("sess_019d4a32");
        assert_eq!(path.file_name().unwrap().to_str().unwrap(), "sess_019d4a32.md");
        let path_str = path.to_str().unwrap();
        assert!(
            path_str.contains("memory/sessions/"),
            "expected memory/sessions/ in path, got: {path_str}"
        );
    }

    #[test]
    fn core_memory_path_under_memory_rules() {
        let path = core_memory_file_path("user-preferences.md");
        let path_str = path.to_str().unwrap();
        assert!(
            path_str.contains("memory/rules/user-preferences.md"),
            "expected memory/rules/ in path, got: {path_str}"
        );
    }

    #[test]
    fn argument_path_under_knowledge_arguments() {
        let path = argument_file_path("oversight-vs-autonomy");
        let path_str = path.to_str().unwrap();
        assert!(
            path_str.contains("knowledge/arguments/oversight-vs-autonomy.md"),
            "expected knowledge/arguments/ in path, got: {path_str}"
        );
    }

    // ── Format tests ────────────────────────────────────────────────────

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

    // ── Parse tests ─────────────────────────────────────────────────────

    #[test]
    fn parse_retain_output_journal_only() {
        let output = "<journal>\n## 2026-04-11 14:00 — Test Session\n\n**Goal**: Testing\n### Completed\n- Did a thing\n</journal>";
        let parsed = parse_retain_output(output);
        assert!(parsed.journal.is_some());
        assert!(parsed.journal.unwrap().contains("Test Session"));
        assert!(parsed.core_memory.is_none());
        assert!(parsed.argument.is_none());
    }

    #[test]
    fn parse_retain_output_all_sections() {
        let output = "<journal>\n## Title\nContent\n</journal>\n\n<core_memory>\nfile: user-preferences.md\nupdate: Prefers Rust\n</core_memory>\n\n<argument>\ntitle: Connection between X and Y\nthesis: Ideas connect\ntopics: [topic-a, topic-b]\nsources: [source-x]\nevidence:\n- topic-a relates to topic-b\n</argument>";
        let parsed = parse_retain_output(output);
        assert!(parsed.journal.is_some());

        let cm = parsed.core_memory.unwrap();
        assert_eq!(cm.file, "user-preferences.md");
        assert_eq!(cm.update, "Prefers Rust");

        let arg = parsed.argument.unwrap();
        assert_eq!(arg.title, "Connection between X and Y");
        assert_eq!(arg.thesis, "Ideas connect");
        assert_eq!(arg.topics, vec!["topic-a", "topic-b"]);
        assert_eq!(arg.sources, vec!["source-x"]);
        assert!(arg.evidence.contains("topic-a relates to topic-b"));
    }

    #[test]
    fn parse_retain_output_handles_malformed_gracefully() {
        let output = "Just a plain text summary without tags";
        let parsed = parse_retain_output(output);
        // Fallback: treat entire output as journal
        assert!(parsed.journal.is_some());
        assert_eq!(parsed.journal.unwrap(), output);
        assert!(parsed.core_memory.is_none());
        assert!(parsed.argument.is_none());
    }

    #[test]
    fn parse_retain_output_partial_core_memory_ignored() {
        // Missing update field — should not produce a core memory
        let output = "<journal>Summary</journal>\n<core_memory>\nfile: user-preferences.md\n</core_memory>";
        let parsed = parse_retain_output(output);
        assert!(parsed.journal.is_some());
        assert!(parsed.core_memory.is_none());
    }

    #[test]
    fn extract_tag_basic() {
        let text = "before <foo>hello world</foo> after";
        assert_eq!(extract_tag(text, "foo"), Some("hello world".to_owned()));
    }

    #[test]
    fn extract_tag_missing() {
        assert_eq!(extract_tag("no tags here", "foo"), None);
    }

    #[test]
    fn parse_bracket_list_basic() {
        assert_eq!(
            parse_bracket_list("[a, b, c]"),
            vec!["a", "b", "c"]
        );
    }

    #[test]
    fn parse_bracket_list_empty() {
        assert!(parse_bracket_list("[]").is_empty());
    }

    #[test]
    fn slugify_basic() {
        assert_eq!(slugify("Connection between X and Y"), "connection-between-x-and-y");
    }

    #[test]
    fn slugify_special_chars() {
        assert_eq!(slugify("AI's Impact on Society!"), "ai-s-impact-on-society");
    }

    // ── File write tests ────────────────────────────────────────────────

    #[test]
    fn write_session_entry_creates_file_with_frontmatter() {
        let dir = tempfile::tempdir().unwrap();
        let session_id = "sess_test_create";
        let path = dir.path().join(format!("{session_id}.md"));

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
    fn write_core_memory_creates_file() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("user-preferences.md");
        write_core_memory_update(&path, "Prefers Rust over Go").unwrap();
        let content = std::fs::read_to_string(&path).unwrap();
        assert!(content.contains("type: core-memory"));
        assert!(content.contains("Prefers Rust over Go"));
    }

    #[test]
    fn write_core_memory_appends_to_existing() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("user-preferences.md");
        std::fs::write(&path, "---\ntype: core-memory\n---\n\n## Existing\n- Old pref\n").unwrap();
        write_core_memory_update(&path, "Also prefers dark mode").unwrap();
        let content = std::fs::read_to_string(&path).unwrap();
        assert!(content.contains("Old pref"));
        assert!(content.contains("Also prefers dark mode"));
    }

    #[test]
    fn write_argument_creates_file() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("test-argument.md");
        let arg = ArgumentContent {
            title: "Test Argument".to_owned(),
            thesis: "Things connect".to_owned(),
            topics: vec!["topic-a".to_owned(), "topic-b".to_owned()],
            sources: vec!["source-x".to_owned()],
            evidence: "- Evidence line 1\n- Evidence line 2".to_owned(),
        };
        write_argument_entry(&path, &arg).unwrap();
        let content = std::fs::read_to_string(&path).unwrap();
        assert!(content.contains("type: argument"));
        assert!(content.contains("# Test Argument"));
        assert!(content.contains("Things connect"));
        assert!(content.contains("topics: [topic-a, topic-b]"));
        assert!(content.contains("origin: retain"));
    }

    // ── Other tests ─────────────────────────────────────────────────────

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
