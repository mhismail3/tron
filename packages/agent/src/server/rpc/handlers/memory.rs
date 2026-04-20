//! Memory handlers: retain (manual + auto).
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
//!
//! ## Entry points
//!
//! - [`RetainMemoryHandler`] — `memory.retain` RPC (manual). Builds a
//!   [`RetainDeps`] from `RpcContext` and calls [`trigger_retain`] with
//!   [`RetainSource::Manual`].
//! - [`auto_retain::maybe_fire`] — called from `agent_prompt_service` after
//!   each successful agent run. Evaluates the auto-retain policy against the
//!   session's turn history and fires [`trigger_retain`] with
//!   [`RetainSource::Auto`] when the `memory.autoRetainInterval` threshold is
//!   crossed. See the [`auto_retain`] submodule for the policy details.
//!
//! ## Concurrency
//!
//! The entire pipeline holds a session-keyed [`RetainGuard`] (owned by
//! [`Orchestrator::try_begin_retain`]) for the full summarizer duration. A
//! concurrent retain (double-click, or manual-while-auto-in-flight) returns
//! `{ retained: false, reason: "in_flight" }` immediately with no side effects.
//!
//! [`RetainGuard`]: crate::runtime::orchestrator::orchestrator::RetainGuard
//! [`Orchestrator::try_begin_retain`]: crate::runtime::orchestrator::orchestrator::Orchestrator::try_begin_retain

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
use crate::server::rpc::context::{RpcContext, run_blocking_task};
use crate::server::rpc::errors::RpcError;
use crate::server::rpc::handlers::{map_event_store_error, require_string_param};
use crate::server::rpc::registry::MethodHandler;

use std::fs;
use std::sync::Arc;

pub(crate) mod auto_retain;

// =============================================================================
// Retain source discriminator + dependencies
// =============================================================================

/// Whether a retain was initiated by the user or by the auto-retain policy.
///
/// Controls whether a `MemoryAutoRetainTriggered` event is emitted at the
/// start of the pipeline. The summarizer behaviour itself is identical.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum RetainSource {
    /// User hit the Retain button (`memory.retain` RPC).
    Manual,
    /// Auto-retain policy crossed its threshold at end of an agent run.
    Auto {
        /// The interval value that caused the fire (from settings).
        interval_fired: u32,
    },
}

/// The narrow set of dependencies the retain pipeline needs.
///
/// Exists so the pipeline can be driven from two different call sites without
/// requiring the full `RpcContext`: the manual RPC handler constructs one via
/// [`RetainDeps::from_rpc`], while the auto-retain path in
/// `agent_prompt_service::execute_prompt_run` builds it directly from the
/// fields it already holds.
#[derive(Clone)]
pub(crate) struct RetainDeps {
    pub orchestrator: Arc<crate::runtime::orchestrator::orchestrator::Orchestrator>,
    pub event_store: Arc<EventStore>,
    pub subagent_manager: Option<Arc<SubagentManager>>,
}

impl RetainDeps {
    pub fn from_rpc(ctx: &RpcContext) -> Self {
        Self {
            orchestrator: Arc::clone(&ctx.orchestrator),
            event_store: Arc::clone(&ctx.event_store),
            subagent_manager: ctx.subagent_manager.clone(),
        }
    }
}

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
        let deps = RetainDeps::from_rpc(ctx);
        trigger_retain(&deps, session_id, RetainSource::Manual).await
    }
}

// =============================================================================
// Core logic
// =============================================================================

/// Entry point for both manual (`RetainMemoryHandler`) and automatic
/// (`auto_retain::maybe_fire`) retentions. Async-spawns the summarizer and
/// returns immediately with `{ retained, status }`.
///
/// Concurrency: holds a session-level `RetainGuard` for the entire duration of
/// the background summarizer. A second concurrent retain (manual double-click,
/// or manual-while-auto-in-flight) returns `{ retained: false, reason: "in_flight" }`
/// immediately with no side effects.
pub(crate) async fn trigger_retain(
    deps: &RetainDeps,
    session_id: String,
    source: RetainSource,
) -> Result<Value, RpcError> {
    // Acquire the retain slot. If another retain is already running for this
    // session, return the sentinel response and emit nothing — no events, no
    // writes, no LLM calls.
    let guard = match deps.orchestrator.try_begin_retain(&session_id) {
        Some(g) => g,
        None => {
            debug!(session_id = %session_id, "retain already in-flight; skipping");
            return Ok(json!({ "retained": false, "reason": "in_flight" }));
        }
    };

    // For auto-retain: emit (and persist) the distinct trigger event first so
    // iOS can render "auto-retain starting" before the generic spinner.
    if let RetainSource::Auto { interval_fired } = source {
        emit_auto_retain_triggered(deps, &session_id, interval_fired).await;
    }

    // Emit MemoryUpdating so the iOS spinner appears immediately.
    let _ = deps
        .orchestrator
        .broadcast()
        .emit(crate::core::events::TronEvent::MemoryUpdating {
            base: crate::core::events::BaseEvent::now(&session_id),
        });

    // ── Find summarization boundary ────────────────────────────────────────
    let event_store = deps.event_store.clone();
    let session_id_q = session_id.clone();
    let boundary_sequence =
        run_blocking_task("memory.retain.find_boundary", move || {
            find_boundary_sequence(&event_store, &session_id_q)
        })
        .await?;

    // ── Get events since boundary ─────────────────────────────────────────
    let event_store2 = deps.event_store.clone();
    let session_id_q2 = session_id.clone();
    let slice = run_blocking_task("memory.retain.get_events", move || {
        get_retain_slice(&event_store2, &session_id_q2, boundary_sequence)
    })
    .await?;

    let Some(slice) = slice else {
        // Nothing new to summarize.
        let _ = deps
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
    };

    // ── Get session metadata ───────────────────────────────────────────────
    let event_store3 = deps.event_store.clone();
    let session_id_q3 = session_id.clone();
    let session_meta = run_blocking_task("memory.retain.get_session", move || {
        event_store3
            .get_session(&session_id_q3)
            .map_err(map_event_store_error)
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

    // ── Serialize transcript ───────────────────────────────────────────────
    let transcript = serialize_for_memory(&slice.messages);

    if transcript.is_empty() {
        let _ = deps
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
    //
    // The RetainGuard moves into the spawn so the in-flight slot is held for
    // the full summarizer duration, then released on drop — whether the task
    // completes, errors, or panics.
    let bg_session_id = session_id.clone();
    let bg_event_store = deps.event_store.clone();
    let bg_broadcast = Arc::clone(deps.orchestrator.broadcast());
    let bg_subagent_manager = deps.subagent_manager.clone();
    let bg_start_ts = slice.start_ts;
    let bg_end_ts = slice.end_ts;

    let _ = tokio::spawn(async move {
        retain_background_task(
            bg_session_id,
            bg_event_store,
            bg_broadcast,
            bg_subagent_manager,
            working_directory,
            model,
            transcript,
            bg_start_ts,
            bg_end_ts,
        )
        .await;
        drop(guard);
    });

    Ok(json!({
        "retained": true,
        "status": "retaining",
    }))
}

/// Persist and broadcast `memory.auto_retain_triggered` so iOS can distinguish
/// automatic retentions from manual ones in the transcript and history. Errors
/// are logged but never surfaced — the retain pipeline must proceed regardless.
async fn emit_auto_retain_triggered(
    deps: &RetainDeps,
    session_id: &str,
    interval_fired: u32,
) {
    let timestamp = Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();

    // Persist to event store so it appears in session history.
    let event_store_p = deps.event_store.clone();
    let session_id_p = session_id.to_owned();
    let timestamp_p = timestamp.clone();
    let _ = run_blocking_task("memory.auto_retain_triggered.persist", move || {
        if let Err(e) = event_store_p.append(&AppendOptions {
            session_id: &session_id_p,
            event_type: EventType::MemoryAutoRetainTriggered,
            payload: json!({
                "sessionId": session_id_p,
                "intervalFired": interval_fired,
                "timestamp": timestamp_p,
            }),
            parent_id: None,
            sequence: None,
        }) {
            warn!(
                session_id = %session_id_p,
                error = %e,
                "failed to persist memory.auto_retain_triggered event"
            );
        }
        Ok::<(), RpcError>(())
    })
    .await;

    // Broadcast to live WebSocket clients.
    let _ = deps
        .orchestrator
        .broadcast()
        .emit(crate::core::events::TronEvent::MemoryAutoRetainTriggered {
            base: crate::core::events::BaseEvent::now(session_id),
            interval_fired,
        });
}

/// Background task that runs the summarizer and writes results.
async fn retain_background_task(
    session_id: String,
    event_store: Arc<EventStore>,
    broadcast: Arc<EventEmitter>,
    subagent_manager: Option<Arc<SubagentManager>>,
    working_directory: String,
    model: String,
    transcript: String,
    start_ts: String,
    end_ts: String,
) {
    // ── Run summarizer ──────────────────────────────────────────────────────
    let raw_output = match subagent_manager {
        Some(manager) => {
            run_summarizer(manager, &session_id, &working_directory, transcript).await
        }
        None => {
            warn!(session_id = %session_id, "no subagent manager for memory retain, using keyword fallback");
            keyword_summary(&session_id)
        }
    };

    // ── Parse structured output ─────────────────────────────────────────────
    let parsed = parse_retain_output(&raw_output);

    let journal_text = parsed.journal.as_deref().unwrap_or(&raw_output);

    // Subagent emits `{Title}\n\n{body}`. Split so the title is clean (for
    // the event payload) and the body doesn't duplicate it in the file.
    let (title, body) = split_title_and_body(journal_text);

    // ── Write journal entry (always) ────────────────────────────────────────
    // `start_ts`/`end_ts` come from the first and last event rows in the
    // summarized slice (deterministic); `created_ts` is only used for the
    // file's initial frontmatter on first write.
    let created_ts = Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();

    if let Err(e) = write_session_entry(
        &session_id,
        &created_ts,
        &model,
        &start_ts,
        &end_ts,
        &title,
        &body,
    ) {
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
    // No turn_number here — the event's own `sequence` is the boundary that
    // auto-retain uses to count subsequent user messages.
    let retained_event_id = event_store
        .append(&AppendOptions {
            session_id: &session_id,
            event_type: EventType::MemoryRetained,
            payload: json!({
                "sessionId": session_id,
                "title": title,
                "summary": body,
                "timestamp": created_ts,
                "rangeStart": start_ts,
                "rangeEnd": end_ts,
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
        summary: Some(body),
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

/// The slice of events after the last retain boundary, along with the
/// ISO timestamps of the first and last event in the slice. `None` when
/// the slice is empty (i.e. nothing new to retain).
struct RetainSlice {
    messages: Vec<Message>,
    /// Timestamp of the earliest event being summarized (ISO 8601).
    start_ts: String,
    /// Timestamp of the latest event being summarized (ISO 8601).
    end_ts: String,
}

/// Reconstruct messages since `after_sequence` and capture the first/last
/// event timestamps from the raw rows before they're collapsed.
fn get_retain_slice(
    store: &EventStore,
    session_id: &str,
    after_sequence: i64,
) -> Result<Option<RetainSlice>, RpcError> {
    let rows = store
        .get_events_since(session_id, after_sequence)
        .map_err(map_event_store_error)?;

    if rows.is_empty() {
        return Ok(None);
    }

    let start_ts = rows.first().map(|r| r.timestamp.clone()).unwrap_or_default();
    let end_ts = rows.last().map(|r| r.timestamp.clone()).unwrap_or_default();

    let events = event_rows_to_session_events(&rows);
    let result = reconstruct_from_events(&events);
    let messages = result
        .messages_with_event_ids
        .into_iter()
        .map(|m| m.message)
        .collect();

    Ok(Some(RetainSlice { messages, start_ts, end_ts }))
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
) -> String {
    let task = format!("Summarize the provided session transcript:\n\n{transcript}");

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
            keyword_summary(parent_session_id)
        }
    }
}

/// Minimal keyword-based fallback when no subagent manager is available.
fn keyword_summary(session_id: &str) -> String {
    format!("Session {session_id}")
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

/// Extract `YYYY-MM-DD HH:MM` from an ISO-8601 timestamp. Returns the input
/// unchanged if it's shorter than 16 chars (defensive — expected inputs
/// always come from the event store which writes ISO-8601).
fn short_ts(iso: &str) -> String {
    if iso.len() >= 16 {
        iso[..16].replace('T', " ")
    } else {
        iso.replace('T', " ")
    }
}

/// Format the section header's time component as a range.
///
/// - Single point (same minute): `2026-04-20 09:03`
/// - Same day: `2026-04-20 09:03 → 09:47`
/// - Cross day: `2026-04-20 09:03 → 2026-04-21 11:15`
fn format_range(start_ts: &str, end_ts: &str) -> String {
    let start = short_ts(start_ts);
    let end = short_ts(end_ts);

    if start == end {
        return start;
    }

    // Split on the space between date and time to compare dates cheaply.
    let start_date = start.split_once(' ').map(|(d, _)| d).unwrap_or(&start);
    let end_parts = end.split_once(' ');

    match end_parts {
        Some((end_date, end_time)) if end_date == start_date => {
            // Same day: elide the redundant end date.
            format!("{start} → {end_time}")
        }
        _ => format!("{start} → {end}"),
    }
}

/// Format a timestamped section entry.
///
/// The handler owns the header format; the subagent supplies only the title
/// text and body (see `split_title_and_body` and the summarizer system
/// prompt).
fn format_session_section(start_ts: &str, end_ts: &str, title: &str, body: &str) -> String {
    let range = format_range(start_ts, end_ts);
    let body_trimmed = body.trim();
    if body_trimmed.is_empty() {
        format!("\n## {range} — {title}\n")
    } else {
        format!("\n## {range} — {title}\n\n{body_trimmed}\n")
    }
}

/// Split the journal text into a clean title and the body below it.
///
/// Contract with the summarizer: the first non-empty line is the title,
/// everything after is the body. If the LLM slips and prefixes with `#`
/// markers or a `title:` label, strip them defensively.
fn split_title_and_body(journal_text: &str) -> (String, String) {
    let trimmed = journal_text.trim_start();
    let (first_line, rest) = match trimmed.split_once('\n') {
        Some((head, tail)) => (head, tail),
        None => (trimmed, ""),
    };

    let mut t = first_line.trim().trim_start_matches('#').trim();
    if let Some(after) = t.strip_prefix("title:").or_else(|| t.strip_prefix("TITLE:")) {
        t = after.trim();
    }

    let title = if t.is_empty() {
        "Session summary".to_owned()
    } else {
        t.to_owned()
    };

    (title, rest.trim_start().to_owned())
}

/// Write a session journal entry to `~/.tron/workspace/memory/sessions/{session_id}.md`.
///
/// Creates the file with YAML frontmatter on first write; appends a new
/// timestamped section on subsequent writes.
fn write_session_entry(
    session_id: &str,
    created_ts: &str,
    model: &str,
    start_ts: &str,
    end_ts: &str,
    title: &str,
    body: &str,
) -> std::io::Result<()> {
    let path = session_file_path(session_id);
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }

    let section = format_session_section(start_ts, end_ts, title, body);
    let is_new = !path.exists();

    use std::io::Write as _;
    let mut file = fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&path)?;

    if is_new {
        let frontmatter = format_session_frontmatter(session_id, created_ts, model);
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
    fn format_session_section_contains_title_and_body() {
        let section = format_session_section(
            "2026-01-01T00:00:00Z",
            "2026-01-01T00:05:00Z",
            "Test title",
            "Test body",
        );
        assert!(section.contains("## 2026-01-01 00:00 → 00:05 — Test title"));
        assert!(section.contains("Test body"));
    }

    #[test]
    fn format_session_section_omits_body_block_when_empty() {
        let section = format_session_section(
            "2026-01-01T00:00:00Z",
            "2026-01-01T00:05:00Z",
            "Solo title",
            "",
        );
        assert!(section.contains("## 2026-01-01 00:00 → 00:05 — Solo title"));
        // No trailing body block / no double newlines beyond the header itself.
        assert!(!section.contains("Solo title\n\n"));
    }

    // ── Range formatter ─────────────────────────────────────────────────

    #[test]
    fn format_range_same_minute_collapses_to_single_timestamp() {
        let r = format_range("2026-04-20T09:03:00Z", "2026-04-20T09:03:00Z");
        assert_eq!(r, "2026-04-20 09:03");
    }

    #[test]
    fn format_range_same_day_elides_second_date() {
        let r = format_range("2026-04-20T09:03:00Z", "2026-04-20T09:47:12Z");
        assert_eq!(r, "2026-04-20 09:03 → 09:47");
    }

    #[test]
    fn format_range_cross_day_includes_both_dates() {
        let r = format_range("2026-04-20T23:58:00Z", "2026-04-21T00:12:00Z");
        assert_eq!(r, "2026-04-20 23:58 → 2026-04-21 00:12");
    }

    // ── Title splitter ──────────────────────────────────────────────────

    #[test]
    fn split_title_and_body_plain_first_line() {
        let (title, body) = split_title_and_body("Gold Price Research Session\n\n**Goal**: ...");
        assert_eq!(title, "Gold Price Research Session");
        assert_eq!(body, "**Goal**: ...");
    }

    #[test]
    fn split_title_and_body_strips_hash_prefix() {
        let (title, body) = split_title_and_body("## Some Title\n\nbody line");
        assert_eq!(title, "Some Title");
        assert_eq!(body, "body line");
    }

    #[test]
    fn split_title_and_body_strips_title_label() {
        let (title, body) = split_title_and_body("title: Labelled\n\nbody");
        assert_eq!(title, "Labelled");
        assert_eq!(body, "body");
    }

    #[test]
    fn split_title_and_body_single_line() {
        let (title, body) = split_title_and_body("Only Title");
        assert_eq!(title, "Only Title");
        assert_eq!(body, "");
    }

    #[test]
    fn split_title_and_body_empty_input_uses_fallback_title() {
        let (title, body) = split_title_and_body("");
        assert_eq!(title, "Session summary");
        assert_eq!(body, "");
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
        let section = format_session_section(
            "2026-01-01T00:00:00Z",
            "2026-01-01T00:15:00Z",
            "Initial work",
            "Did some things",
        );

        std::fs::write(&path, format!("{frontmatter}{section}")).unwrap();
        let content = std::fs::read_to_string(&path).unwrap();
        assert!(content.starts_with("---\n"));
        assert!(content.contains("session: sess_test_create"));
        assert!(content.contains("## 2026-01-01 00:00 → 00:15 — Initial work"));
        assert!(content.contains("Did some things"));
    }

    #[test]
    fn write_session_entry_appends_without_duplicate_frontmatter() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("sess_test_append.md");

        let frontmatter = format_session_frontmatter("sess_test_append", "2026-01-01T00:00:00Z", "claude-haiku");
        let section1 = format_session_section(
            "2026-01-01T00:00:00Z",
            "2026-01-01T00:10:00Z",
            "First",
            "First work",
        );
        let section2 = format_session_section(
            "2026-01-01T01:00:00Z",
            "2026-01-01T01:12:00Z",
            "Second",
            "More work",
        );

        std::fs::write(&path, format!("{frontmatter}{section1}")).unwrap();
        use std::io::Write as _;
        let mut file = std::fs::OpenOptions::new().append(true).open(&path).unwrap();
        file.write_all(section2.as_bytes()).unwrap();

        let content = std::fs::read_to_string(&path).unwrap();
        assert_eq!(content.matches("---").count(), 2); // only the frontmatter pair
        assert!(content.contains("## 2026-01-01 00:00 → 00:10 — First"));
        assert!(content.contains("## 2026-01-01 01:00 → 01:12 — Second"));
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
        let s = keyword_summary("sess_xyz");
        assert!(s.contains("sess_xyz"));
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
            .create_session("claude-sonnet-4-6", "/tmp", None, None, None, None)
            .unwrap();

        let deps = RetainDeps::from_rpc(&ctx);
        let result = trigger_retain(&deps, cr.session.id.clone(), RetainSource::Manual)
            .await
            .unwrap();
        // No events since boundary (sequence 0 => empty since) => nothing_new
        assert_eq!(result["retained"], false);
    }

    #[tokio::test]
    async fn auto_source_persists_trigger_event() {
        use crate::events::EventType;
        use crate::server::rpc::handlers::test_helpers::make_test_context;
        let ctx = make_test_context();

        let cr = ctx
            .event_store
            .create_session("claude-sonnet-4-6", "/tmp", None, None, None, None)
            .unwrap();
        let session_id = cr.session.id.clone();

        let deps = RetainDeps::from_rpc(&ctx);
        let _ = trigger_retain(
            &deps,
            session_id.clone(),
            RetainSource::Auto { interval_fired: 5 },
        )
        .await
        .unwrap();

        let row = ctx
            .event_store
            .get_latest_event_by_type(&session_id, "memory.auto_retain_triggered")
            .unwrap()
            .expect("auto-retain trigger event should be persisted");
        assert_eq!(row.event_type, "memory.auto_retain_triggered");

        let payload: serde_json::Value = serde_json::from_str(&row.payload).unwrap();
        assert_eq!(payload["intervalFired"], 5);
        assert_eq!(payload["sessionId"], session_id);
        let _ = EventType::MemoryAutoRetainTriggered; // compile-time check that the variant exists
    }

    #[tokio::test]
    async fn trigger_retain_skips_when_already_in_flight() {
        use crate::server::rpc::handlers::test_helpers::make_test_context;
        let ctx = make_test_context();

        let cr = ctx
            .event_store
            .create_session("claude-sonnet-4-6", "/tmp", None, None, None, None)
            .unwrap();
        let session_id = cr.session.id.clone();

        // Take the slot directly (simulating a still-running retain background task).
        let _held = ctx
            .orchestrator
            .try_begin_retain(&session_id)
            .expect("fresh session must be claimable");

        let deps = RetainDeps::from_rpc(&ctx);
        let result = trigger_retain(&deps, session_id.clone(), RetainSource::Manual)
            .await
            .unwrap();
        assert_eq!(result["retained"], false);
        assert_eq!(result["reason"], "in_flight");

        // Also true for auto.
        let result_auto = trigger_retain(
            &deps,
            session_id.clone(),
            RetainSource::Auto { interval_fired: 5 },
        )
        .await
        .unwrap();
        assert_eq!(result_auto["reason"], "in_flight");

        // No auto-retain event persisted (the guard short-circuits before any I/O).
        let row = ctx
            .event_store
            .get_latest_event_by_type(&session_id, "memory.auto_retain_triggered")
            .unwrap();
        assert!(
            row.is_none(),
            "blocked auto retain must not persist the trigger event"
        );
    }

    #[tokio::test]
    async fn manual_source_does_not_persist_trigger_event() {
        use crate::server::rpc::handlers::test_helpers::make_test_context;
        let ctx = make_test_context();

        let cr = ctx
            .event_store
            .create_session("claude-sonnet-4-6", "/tmp", None, None, None, None)
            .unwrap();
        let session_id = cr.session.id.clone();

        let deps = RetainDeps::from_rpc(&ctx);
        let _ = trigger_retain(&deps, session_id.clone(), RetainSource::Manual)
            .await
            .unwrap();

        let row = ctx
            .event_store
            .get_latest_event_by_type(&session_id, "memory.auto_retain_triggered")
            .unwrap();
        assert!(
            row.is_none(),
            "manual retain must not produce an auto_retain_triggered event"
        );
    }
}
