use super::events::*;
use super::parsing::*;
use super::summarizer::*;
use super::transcript::*;
use super::writer::*;
use super::{
    RetainDeps, RetainSource, emit_auto_retain_triggered, serialize_for_memory,
    trigger_manual_retain, trigger_retain,
};
use crate::domains::session::event_store::AppendOptions;
use crate::domains::session::event_store::types::EventType;
use crate::domains::session::event_store::types::state::Message;
use serde_json::Value;
use serde_json::json;
use std::sync::Arc;

// ── Path tests ──────────────────────────────────────────────────────

#[test]
fn session_file_path_uses_memory_sessions() {
    let path = session_file_path("sess_019d4a32");
    assert_eq!(
        path.file_name().unwrap().to_str().unwrap(),
        "sess_019d4a32.md"
    );
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
fn split_title_and_body_empty_input_uses_recovery_title() {
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
    // Recovery: treat entire output as journal
    assert!(parsed.journal.is_some());
    assert_eq!(parsed.journal.unwrap(), output);
    assert!(parsed.core_memory.is_none());
    assert!(parsed.argument.is_none());
}

#[test]
fn parse_retain_output_partial_core_memory_ignored() {
    // Missing update field — should not produce a core memory
    let output =
        "<journal>Summary</journal>\n<core_memory>\nfile: user-preferences.md\n</core_memory>";
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
    assert_eq!(parse_bracket_list("[a, b, c]"), vec!["a", "b", "c"]);
}

#[test]
fn parse_bracket_list_empty() {
    assert!(parse_bracket_list("[]").is_empty());
}

#[test]
fn slugify_basic() {
    assert_eq!(
        slugify("Connection between X and Y"),
        "connection-between-x-and-y"
    );
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

    let frontmatter =
        format_session_frontmatter(session_id, "2026-01-01T00:00:00Z", "claude-haiku");
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

    let frontmatter =
        format_session_frontmatter("sess_test_append", "2026-01-01T00:00:00Z", "claude-haiku");
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
    let mut file = std::fs::OpenOptions::new()
        .append(true)
        .open(&path)
        .unwrap();
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
    std::fs::write(
        &path,
        "---\ntype: core-memory\n---\n\n## Existing\n- Old pref\n",
    )
    .unwrap();
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
    use crate::shared::server::test_support::make_test_context;
    let ctx = make_test_context();
    let err = trigger_manual_retain(
        Some(&serde_json::json!({})),
        &crate::domains::memory::Deps::from_engine(
            &crate::domains::worker::DomainRegistrationContext::from_context(&ctx),
        ),
    )
    .await
    .unwrap_err();
    assert_eq!(err.code(), "INVALID_PARAMS");
}

#[tokio::test]
async fn handler_returns_nothing_new_for_empty_session() {
    use crate::shared::server::test_support::make_test_context;
    let ctx = make_test_context();

    // Create a session first so the handler can find it
    let cr = ctx
        .event_store
        .create_session("claude-sonnet-4-6", "/tmp", None, None, None, None)
        .unwrap();

    let deps = RetainDeps::from_test_context(&ctx);
    let result = trigger_retain(&deps, cr.session.id.clone(), RetainSource::Manual)
        .await
        .unwrap();
    // No events since boundary (sequence 0 => empty since) => nothing_new
    assert_eq!(result["retained"], false);
}

#[tokio::test]
async fn auto_source_persists_trigger_event() {
    use crate::domains::session::event_store::EventType;
    use crate::shared::server::test_support::make_test_context;
    let ctx = make_test_context();

    let cr = ctx
        .event_store
        .create_session("claude-sonnet-4-6", "/tmp", None, None, None, None)
        .unwrap();
    let session_id = cr.session.id.clone();

    let deps = RetainDeps::from_test_context(&ctx);
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
    use crate::shared::server::test_support::make_test_context;
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

    let deps = RetainDeps::from_test_context(&ctx);
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
    use crate::shared::server::test_support::make_test_context;
    let ctx = make_test_context();

    let cr = ctx
        .event_store
        .create_session("claude-sonnet-4-6", "/tmp", None, None, None, None)
        .unwrap();
    let session_id = cr.session.id.clone();

    let deps = RetainDeps::from_test_context(&ctx);
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

// ── memory.auto_retain_failed unit tests ─────────────────────────────

/// Direct unit test of the failure-emitter. Persists a
/// `memory.auto_retain_failed` event with payload fields matching
/// the triggered/failed pair iOS consumes.
#[tokio::test]
async fn emit_auto_retain_failed_persists_event_with_reason() {
    use crate::shared::server::test_support::make_test_context;
    let ctx = make_test_context();

    let cr = ctx
        .event_store
        .create_session("claude-sonnet-4-6", "/tmp", None, None, None, None)
        .unwrap();
    let session_id = cr.session.id.clone();

    let broadcast = Arc::clone(ctx.orchestrator.broadcast());

    emit_auto_retain_failed(
        &ctx.event_store,
        &broadcast,
        &session_id,
        7,
        "subagent spawn failed: subsession cap reached",
    )
    .await;

    let row = ctx
        .event_store
        .get_latest_event_by_type(&session_id, "memory.auto_retain_failed")
        .unwrap()
        .expect("auto_retain_failed event should be persisted");
    assert_eq!(row.event_type, "memory.auto_retain_failed");

    let payload: serde_json::Value = serde_json::from_str(&row.payload).unwrap();
    assert_eq!(payload["intervalFired"], 7);
    assert_eq!(payload["sessionId"], session_id);
    assert!(
        payload["reason"]
            .as_str()
            .unwrap_or("")
            .contains("subsession cap reached"),
        "reason should be preserved verbatim; got {:?}",
        payload["reason"]
    );
}

/// The `triggered` and `failed` events land in the correct order when
/// an auto-retain pipeline starts and then fails. iOS depends on this
/// ordering to transition the retain pill from "started" → "failed".
#[tokio::test]
async fn auto_retain_triggered_and_failed_land_in_order() {
    use crate::shared::server::test_support::make_test_context;
    let ctx = make_test_context();

    let cr = ctx
        .event_store
        .create_session("claude-sonnet-4-6", "/tmp", None, None, None, None)
        .unwrap();
    let session_id = cr.session.id.clone();

    // Step 1: record the triggered event.
    emit_auto_retain_triggered(&RetainDeps::from_test_context(&ctx), &session_id, 3).await;

    // Step 2: record the failed event.
    let broadcast = Arc::clone(ctx.orchestrator.broadcast());
    emit_auto_retain_failed(&ctx.event_store, &broadcast, &session_id, 3, "test failure").await;

    let triggered = ctx
        .event_store
        .get_latest_event_by_type(&session_id, "memory.auto_retain_triggered")
        .unwrap()
        .expect("triggered must exist");
    let failed = ctx
        .event_store
        .get_latest_event_by_type(&session_id, "memory.auto_retain_failed")
        .unwrap()
        .expect("failed must exist");

    assert!(
        triggered.sequence < failed.sequence,
        "triggered must come before failed; got triggered.seq={} failed.seq={}",
        triggered.sequence,
        failed.sequence
    );
}

/// A manual retain that encounters a summarizer error must NOT emit
/// `auto_retain_failed` — that event is auto-only.
#[tokio::test]
async fn manual_retain_never_emits_auto_retain_failed() {
    use crate::shared::server::test_support::make_test_context;
    let ctx = make_test_context();

    let cr = ctx
        .event_store
        .create_session("claude-sonnet-4-6", "/tmp", None, None, None, None)
        .unwrap();
    let session_id = cr.session.id.clone();

    // Seed a user message so the retain pipeline has content to summarize.
    let _ = ctx
        .event_store
        .append(&AppendOptions {
            session_id: &session_id,
            event_type: EventType::MessageUser,
            payload: json!({"text": "hello"}),
            parent_id: None,
            sequence: None,
        })
        .unwrap();

    let deps = RetainDeps::from_test_context(&ctx);
    let _ = trigger_retain(&deps, session_id.clone(), RetainSource::Manual)
        .await
        .unwrap();

    // trigger_retain spawns the background task; give it a moment to complete.
    tokio::time::sleep(std::time::Duration::from_millis(500)).await;

    let failed = ctx
        .event_store
        .get_latest_event_by_type(&session_id, "memory.auto_retain_failed")
        .unwrap();
    assert!(
        failed.is_none(),
        "manual retain must never produce an auto_retain_failed event"
    );
}

// ── serialize_for_memory + collect_interactive_tool_use_ids ──────────

/// Build an assistant message that emits a `tool_use` block for `tool_name`
/// with the given id and (optional) input payload.
fn assistant_tool_use_with_input(tool_name: &str, tool_id: &str, input: Value) -> Message {
    Message {
        role: "assistant".to_string(),
        content: json!([{
            "type": "tool_use",
            "id": tool_id,
            "name": tool_name,
            "input": input
        }]),
        tool_call_id: None,
        is_error: None,
    }
}

/// Minimal `tool_use` assistant message — input is an empty object.
/// Use this when the id/name are all that matters for the test.
fn assistant_tool_use(tool_name: &str, tool_id: &str) -> Message {
    assistant_tool_use_with_input(tool_name, tool_id, json!({}))
}

/// Assistant message for an `agent::ask_user` tool call with real question
/// text (what the agent would actually send at runtime).
fn assistant_ask_user_question(tool_id: &str, questions: &[&str]) -> Message {
    let qs: Vec<Value> = questions
        .iter()
        .map(|q| {
            json!({
                "question": q,
                "options": [{"label": "A"}, {"label": "B"}],
                "mode": "single"
            })
        })
        .collect();
    assistant_tool_use_with_input("agent::ask_user", tool_id, json!({"questions": qs}))
}

fn assistant_text(text: &str) -> Message {
    Message {
        role: "assistant".to_string(),
        content: json!([{"type": "text", "text": text}]),
        tool_call_id: None,
        is_error: None,
    }
}

fn user_text(text: &str) -> Message {
    Message {
        role: "user".to_string(),
        content: json!(text),
        tool_call_id: None,
        is_error: None,
    }
}

fn tool_result(tool_call_id: &str, text: &str) -> Message {
    Message {
        role: "tool_result".to_string(),
        content: json!([{"type": "text", "text": text}]),
        tool_call_id: Some(tool_call_id.to_string()),
        is_error: None,
    }
}

// ── collect_interactive_tool_use_ids ──

#[test]
fn collect_interactive_ids_finds_ask_user_question() {
    let msgs = vec![assistant_tool_use("agent::ask_user", "aq_1")];
    let ids = collect_interactive_tool_use_ids(&msgs);
    assert!(ids.contains("aq_1"));
    assert_eq!(ids.len(), 1);
}

#[test]
fn collect_interactive_ids_ignores_non_interactive_tools() {
    let msgs = vec![
        assistant_tool_use("filesystem::read_file", "r_1"),
        assistant_tool_use("process::run", "b_1"),
    ];
    let ids = collect_interactive_tool_use_ids(&msgs);
    assert!(
        ids.is_empty(),
        "should not collect non-interactive tool ids"
    );
}

#[test]
fn collect_interactive_ids_mixed_tool_use() {
    let msgs = vec![Message {
        role: "assistant".to_string(),
        content: json!([
            {"type": "tool_use", "id": "aq_1", "name": "agent::ask_user", "input": {}},
            {"type": "tool_use", "id": "r_1", "name": "filesystem::read_file", "input": {}}
        ]),
        tool_call_id: None,
        is_error: None,
    }];
    let ids = collect_interactive_tool_use_ids(&msgs);
    assert!(ids.contains("aq_1"));
    assert!(!ids.contains("r_1"));
    assert_eq!(ids.len(), 1);
}

#[test]
fn collect_interactive_ids_string_content_skipped_safely() {
    let msgs = vec![Message {
        role: "user".to_string(),
        content: json!("plain string content"),
        tool_call_id: None,
        is_error: None,
    }];
    let ids = collect_interactive_tool_use_ids(&msgs);
    assert!(ids.is_empty());
}

#[test]
fn collect_interactive_ids_block_without_type_field() {
    let msgs = vec![Message {
        role: "assistant".to_string(),
        content: json!([{"name": "agent::ask_user", "id": "aq_1"}]),
        tool_call_id: None,
        is_error: None,
    }];
    let ids = collect_interactive_tool_use_ids(&msgs);
    assert!(ids.is_empty(), "blocks without type field must be ignored");
}

#[test]
fn collect_interactive_ids_tool_use_without_id() {
    let msgs = vec![Message {
        role: "assistant".to_string(),
        content: json!([{"type": "tool_use", "name": "agent::ask_user"}]),
        tool_call_id: None,
        is_error: None,
    }];
    let ids = collect_interactive_tool_use_ids(&msgs);
    assert!(ids.is_empty(), "tool_use without id produces no entry");
}

#[test]
fn collect_interactive_ids_multiple_ask_user_calls() {
    let msgs = vec![
        assistant_tool_use("agent::ask_user", "aq_1"),
        assistant_tool_use("agent::ask_user", "aq_2"),
        assistant_tool_use("agent::ask_user", "aq_3"),
    ];
    let ids = collect_interactive_tool_use_ids(&msgs);
    assert_eq!(ids.len(), 3);
    assert!(ids.contains("aq_1"));
    assert!(ids.contains("aq_2"));
    assert!(ids.contains("aq_3"));
}

// ── serialize_for_memory ──

#[test]
fn serialize_empty_messages_returns_empty_string() {
    let out = serialize_for_memory(&[]);
    assert_eq!(out, "");
}

#[test]
fn serialize_handles_string_content_message() {
    let msgs = vec![user_text("hi there")];
    let out = serialize_for_memory(&msgs);
    assert!(out.contains("[USER] hi there"), "got: {out}");
}

#[test]
fn serialize_filters_ask_user_question_result_but_keeps_question_text() {
    let msgs = vec![
        assistant_ask_user_question("aq_1", &["What's your favorite color?"]),
        tool_result(
            "aq_1",
            "Q1: What's your favorite color? [single] (Red, Blue)",
        ),
        user_text("Red"),
    ];
    let out = serialize_for_memory(&msgs);
    // Verbose tool_result recap is filtered.
    assert!(
        !out.contains("[TOOL_RESULT]"),
        "interactive tool_result should be filtered: {out}"
    );
    // Option list noise stays out.
    assert!(
        !out.contains("(Red, Blue)"),
        "option list from recap should not appear: {out}"
    );
    // But the question context survives via the assistant line.
    assert!(
        out.contains("[ASSISTANT] Asked: \"What's your favorite color?\""),
        "question context should appear in assistant line: {out}"
    );
    // And the user's answer is preserved.
    assert!(out.contains("[USER] Red"), "user answer preserved: {out}");
}

#[test]
fn serialize_retains_non_interactive_tool_result() {
    let msgs = vec![
        assistant_tool_use("filesystem::read_file", "r_1"),
        tool_result("r_1", "file contents here"),
    ];
    let out = serialize_for_memory(&msgs);
    assert!(
        out.contains("[TOOL_RESULT] file contents here"),
        "non-interactive tool result should appear: {out}"
    );
}

#[test]
fn serialize_filters_multiple_interactive_in_slice() {
    let msgs = vec![
        assistant_tool_use("agent::ask_user", "aq_1"),
        tool_result("aq_1", "Q1: first"),
        user_text("a1"),
        assistant_tool_use("agent::ask_user", "aq_2"),
        tool_result("aq_2", "Q2: second"),
        user_text("a2"),
        assistant_tool_use("agent::ask_user", "aq_3"),
        tool_result("aq_3", "Q3: third"),
        user_text("a3"),
    ];
    let out = serialize_for_memory(&msgs);
    assert!(
        !out.contains("[TOOL_RESULT]"),
        "all three should be filtered: {out}"
    );
    assert!(!out.contains("Q1:"), "no question echo: {out}");
    assert!(!out.contains("Q2:"), "no question echo: {out}");
    assert!(!out.contains("Q3:"), "no question echo: {out}");
    assert!(out.contains("[USER] a1"));
    assert!(out.contains("[USER] a2"));
    assert!(out.contains("[USER] a3"));
}

#[test]
fn serialize_keeps_orphan_tool_result() {
    // Tool result whose tool_call_id has no matching tool_use in the slice.
    // Default: preserve it — we only filter when we can confidently identify
    // the source as interactive.
    let msgs = vec![tool_result("orphan_id", "some tool output")];
    let out = serialize_for_memory(&msgs);
    assert!(
        out.contains("[TOOL_RESULT] some tool output"),
        "orphan tool_result should be preserved: {out}"
    );
}

#[test]
fn serialize_preserves_mixed_interactive_and_regular() {
    let msgs = vec![
        assistant_tool_use("agent::ask_user", "aq_1"),
        tool_result("aq_1", "Q1: pick one"),
        user_text("done"),
        assistant_tool_use("filesystem::read_file", "r_1"),
        tool_result("r_1", "file body"),
        assistant_text("final thoughts"),
    ];
    let out = serialize_for_memory(&msgs);
    assert!(!out.contains("pick one"), "interactive filtered: {out}");
    assert!(
        out.contains("[TOOL_RESULT] file body"),
        "filesystem read kept: {out}"
    );
    assert!(out.contains("[ASSISTANT] final thoughts"));
    assert!(out.contains("[USER] done"));
}

#[test]
fn serialize_flags_errored_non_interactive_tool_result() {
    let msgs = vec![
        assistant_tool_use("process::run", "b_1"),
        Message {
            role: "tool_result".to_string(),
            content: json!([{"type": "text", "text": "command failed"}]),
            tool_call_id: Some("b_1".to_string()),
            is_error: Some(true),
        },
    ];
    let out = serialize_for_memory(&msgs);
    assert!(
        out.contains("[TOOL_ERROR] command failed"),
        "error label preserved: {out}"
    );
}

// ── extract_interactive_tool_summary ──

#[test]
fn extract_summary_returns_none_for_text_block() {
    let block = json!({"type": "text", "text": "hello"});
    assert_eq!(extract_interactive_tool_summary(&block), None);
}

#[test]
fn extract_summary_returns_none_for_non_interactive_tool_use() {
    let block = json!({
        "type": "tool_use",
        "id": "r_1",
        "name": "filesystem::read_file",
        "input": {"path": "/tmp/x"}
    });
    assert_eq!(extract_interactive_tool_summary(&block), None);
}

#[test]
fn extract_summary_returns_none_when_input_missing() {
    let block = json!({
        "type": "tool_use",
        "id": "aq_1",
        "name": "agent::ask_user"
    });
    assert_eq!(extract_interactive_tool_summary(&block), None);
}

#[test]
fn extract_summary_ask_user_single_question() {
    let block = json!({
        "type": "tool_use",
        "id": "aq_1",
        "name": "agent::ask_user",
        "input": {
            "questions": [{"question": "What's next?", "options": [{"label":"A"},{"label":"B"}], "mode":"single"}]
        }
    });
    assert_eq!(
        extract_interactive_tool_summary(&block),
        Some("Asked: \"What's next?\"".to_string())
    );
}

#[test]
fn extract_summary_ask_user_multiple_questions_joined() {
    let block = json!({
        "type": "tool_use",
        "id": "aq_1",
        "name": "agent::ask_user",
        "input": {
            "questions": [
                {"question": "Q one?", "options": [{"label":"A"},{"label":"B"}]},
                {"question": "Q two?", "options": [{"label":"X"},{"label":"Y"}]}
            ]
        }
    });
    let out = extract_interactive_tool_summary(&block).unwrap();
    assert_eq!(out, "Asked: \"Q one?\"; \"Q two?\"");
}

#[test]
fn extract_summary_ask_user_without_questions_returns_none() {
    let block = json!({
        "type": "tool_use",
        "id": "aq_1",
        "name": "agent::ask_user",
        "input": {"questions": []}
    });
    assert_eq!(extract_interactive_tool_summary(&block), None);
}

#[test]
fn extract_summary_ask_user_omits_options_and_mode() {
    // Options, modes, and context should NOT appear in the summary — they
    // are the upstream source of transcript pollution. Only the question
    // text itself is preserved.
    let block = json!({
        "type": "tool_use",
        "id": "aq_1",
        "name": "agent::ask_user",
        "input": {
            "questions": [{
                "question": "Pick color",
                "options": [{"label": "Crimson"}, {"label": "Cerulean"}],
                "mode": "single"
            }],
            "context": "ratification gate"
        }
    });
    let out = extract_interactive_tool_summary(&block).unwrap();
    assert!(!out.contains("Crimson"), "options should be omitted: {out}");
    assert!(
        !out.contains("Cerulean"),
        "options should be omitted: {out}"
    );
    assert!(!out.contains("[single]"), "mode should be omitted: {out}");
    assert!(
        !out.contains("ratification"),
        "context should be omitted: {out}"
    );
}

// ── serialize assistant-line question preservation ──

#[test]
fn serialize_preserves_multi_question_ask_user_transcript() {
    let msgs = vec![
        assistant_ask_user_question(
            "aq_1",
            &["What's your role?", "What timezone?", "What language?"],
        ),
        tool_result("aq_1", "verbose recap"),
        user_text("IC; PT; Swift"),
    ];
    let out = serialize_for_memory(&msgs);
    assert!(
        out.contains("Asked: \"What's your role?\""),
        "q1 missing: {out}"
    );
    assert!(out.contains("\"What timezone?\""), "q2 missing: {out}");
    assert!(out.contains("\"What language?\""), "q3 missing: {out}");
    assert!(
        !out.contains("[TOOL_RESULT]"),
        "verbose recap leaked: {out}"
    );
    assert!(out.contains("[USER] IC; PT; Swift"));
}

#[test]
fn serialize_assistant_mixes_text_and_interactive_summary() {
    // The agent often writes a short intro text block before the tool_use
    // in the same message. Both should appear on the transcript line.
    let msgs = vec![Message {
        role: "assistant".to_string(),
        content: json!([
            {"type": "text", "text": "Let me ask you something."},
            {"type": "tool_use", "id": "aq_1", "name": "agent::ask_user", "input": {
                "questions": [{"question": "Ready?", "options": [{"label":"Y"},{"label":"N"}]}]
            }}
        ]),
        tool_call_id: None,
        is_error: None,
    }];
    let out = serialize_for_memory(&msgs);
    assert!(
        out.contains("Let me ask you something"),
        "text block missing: {out}"
    );
    assert!(
        out.contains("Asked: \"Ready?\""),
        "question text missing: {out}"
    );
}

#[test]
fn serialize_ignores_non_interactive_tool_use_in_assistant_content() {
    let msgs = vec![Message {
        role: "assistant".to_string(),
        content: json!([
            {"type": "text", "text": "reading file"},
            {"type": "tool_use", "id": "r_1", "name": "filesystem::read_file", "input": {"path": "/tmp/x"}}
        ]),
        tool_call_id: None,
        is_error: None,
    }];
    let out = serialize_for_memory(&msgs);
    assert!(out.contains("[ASSISTANT] reading file"));
    assert!(!out.contains("Asked:"));
    assert!(!out.contains("Requested confirmation"));
}
