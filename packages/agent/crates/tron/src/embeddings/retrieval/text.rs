//! Embedding text extraction from memory ledger payloads.

use std::path::Path;

use crate::events::types::payloads::memory::MemoryLedgerPayload;

/// Build a semantic embedding text from a memory ledger payload.
///
/// Concatenates title, input, actions, files, lessons, thinking insights,
/// decisions, tags, and project context with newline separators between sections.
pub fn build_embedding_text(payload: &MemoryLedgerPayload) -> String {
    let mut parts = Vec::new();

    if !payload.title.is_empty() {
        parts.push(payload.title.clone());
    }
    if !payload.input.is_empty() {
        parts.push(payload.input.clone());
    }
    if !payload.actions.is_empty() {
        parts.push(payload.actions.join(". "));
    }
    if !payload.files.is_empty() {
        let file_strs: Vec<String> = payload
            .files
            .iter()
            .map(|f| {
                let basename = Path::new(&f.path)
                    .file_name()
                    .map_or(f.path.as_str(), |n| n.to_str().unwrap_or(&f.path));
                let op_label = match f.op.as_str() {
                    "C" => "created",
                    "M" => "modified",
                    "D" => "deleted",
                    other => other,
                };
                format!("{basename} ({op_label})")
            })
            .collect();
        parts.push(file_strs.join(". "));
    }
    if !payload.lessons.is_empty() {
        parts.push(payload.lessons.join(". "));
    }
    if !payload.thinking_insights.is_empty() {
        parts.push(payload.thinking_insights.join(". "));
    }
    if !payload.decisions.is_empty() {
        let formatted: Vec<String> = payload
            .decisions
            .iter()
            .map(|d| format!("{}: {}", d.choice, d.reason))
            .collect();
        parts.push(formatted.join(". "));
    }
    if !payload.tags.is_empty() {
        parts.push(payload.tags.join(" "));
    }
    if !payload.entry_type.is_empty() {
        parts.push(format!("type: {}", payload.entry_type));
    }
    if !payload.working_directory.is_empty() {
        let project = Path::new(&payload.working_directory)
            .file_name()
            .map_or(payload.working_directory.as_str(), |n| {
                n.to_str().unwrap_or(&payload.working_directory)
            });
        parts.push(format!("project: {project}"));
    }

    parts.join("\n")
}

/// Build embedding text from a JSON value.
///
/// Deserializes to [`MemoryLedgerPayload`] and calls [`build_embedding_text`].
/// Returns an empty string on parse failure. Takes ownership to avoid cloning.
pub fn build_embedding_text_from_json(value: serde_json::Value) -> String {
    match serde_json::from_value::<MemoryLedgerPayload>(value) {
        Ok(payload) => build_embedding_text(&payload),
        Err(_) => String::new(),
    }
}

/// Build per-lesson embedding texts with session context.
///
/// Returns one string per lesson, each prefixed with the session title for context.
/// Empty lessons are skipped.
pub fn build_lesson_texts(payload: &MemoryLedgerPayload) -> Vec<String> {
    payload
        .lessons
        .iter()
        .filter(|l| !l.is_empty())
        .map(|lesson| {
            if payload.title.is_empty() {
                lesson.clone()
            } else {
                format!("Lesson from {}: {lesson}", payload.title)
            }
        })
        .collect()
}

/// Wrap text with `EmbeddingGemma` document prefix for indexing.
pub fn with_document_prefix(text: &str) -> String {
    format!("title: none | text: {text}")
}

/// Wrap text with `EmbeddingGemma` query prefix for search.
pub fn with_query_prefix(text: &str) -> String {
    format!("task: search result | query: {text}")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::events::types::payloads::memory::{
        EventRange, LedgerDecision, LedgerFileEntry, LedgerTokenCost, TurnRange,
    };

    fn make_payload() -> MemoryLedgerPayload {
        MemoryLedgerPayload {
            event_range: EventRange {
                first_event_id: "e1".into(),
                last_event_id: "e2".into(),
            },
            turn_range: TurnRange {
                first_turn: 1,
                last_turn: 3,
            },
            title: "Implement auth".into(),
            entry_type: "feature".into(),
            status: "completed".into(),
            tags: vec!["auth".into(), "security".into()],
            input: "Add user login".into(),
            actions: vec!["Created login form".into(), "Added JWT validation".into()],
            files: vec![
                LedgerFileEntry {
                    path: "src/auth.rs".into(),
                    op: "M".into(),
                    why: "add login handler".into(),
                },
                LedgerFileEntry {
                    path: "src/router.rs".into(),
                    op: "C".into(),
                    why: "new route".into(),
                },
            ],
            decisions: vec![LedgerDecision {
                choice: "JWT".into(),
                reason: "stateless auth".into(),
            }],
            lessons: vec!["Always validate tokens".into()],
            thinking_insights: vec!["Considered OAuth but JWT is simpler".into()],
            token_cost: LedgerTokenCost {
                input: 100,
                output: 50,
            },
            model: "claude".into(),
            working_directory: "/Users/moose/Workspace/tron".into(),
            source: "manual".into(),
        }
    }

    #[test]
    fn all_fields_present() {
        let text = build_embedding_text(&make_payload());
        assert!(text.contains("Implement auth"));
        assert!(text.contains("Add user login"));
        assert!(text.contains("Created login form"));
        assert!(text.contains("auth.rs (modified)"));
        assert!(text.contains("router.rs (created)"));
        assert!(text.contains("Always validate tokens"));
        assert!(text.contains("Considered OAuth but JWT is simpler"));
        assert!(text.contains("JWT: stateless auth"));
        assert!(text.contains("auth security"));
        assert!(text.contains("project: tron"));
    }

    #[test]
    fn empty_fields_omitted() {
        let mut payload = make_payload();
        payload.actions = vec![];
        payload.files = vec![];
        payload.lessons = vec![];
        payload.thinking_insights = vec![];
        payload.decisions = vec![];
        payload.tags = vec![];
        payload.entry_type = String::new();
        payload.working_directory = String::new();
        let text = build_embedding_text(&payload);
        assert!(!text.contains("\n\n"), "no double newlines");
        assert_eq!(text.matches('\n').count(), 1); // title + input
    }

    #[test]
    fn title_only() {
        let mut payload = make_payload();
        payload.input = String::new();
        payload.actions = vec![];
        payload.files = vec![];
        payload.lessons = vec![];
        payload.thinking_insights = vec![];
        payload.decisions = vec![];
        payload.tags = vec![];
        payload.entry_type = String::new();
        payload.working_directory = String::new();
        let text = build_embedding_text(&payload);
        assert_eq!(text, "Implement auth");
    }

    #[test]
    fn actions_joined_with_dot() {
        let payload = make_payload();
        let text = build_embedding_text(&payload);
        assert!(text.contains("Created login form. Added JWT validation"));
    }

    #[test]
    fn lessons_joined_with_dot() {
        let mut payload = make_payload();
        payload.lessons = vec!["Lesson one".into(), "Lesson two".into()];
        let text = build_embedding_text(&payload);
        assert!(text.contains("Lesson one. Lesson two"));
    }

    #[test]
    fn decisions_format() {
        let payload = make_payload();
        let text = build_embedding_text(&payload);
        assert!(text.contains("JWT: stateless auth"));
    }

    #[test]
    fn tags_joined_with_space() {
        let payload = make_payload();
        let text = build_embedding_text(&payload);
        assert!(text.contains("auth security"));
    }

    #[test]
    fn files_show_basenames_with_ops() {
        let payload = make_payload();
        let text = build_embedding_text(&payload);
        assert!(text.contains("auth.rs (modified)"));
        assert!(text.contains("router.rs (created)"));
    }

    #[test]
    fn files_with_delete_op() {
        let mut payload = make_payload();
        payload.files = vec![LedgerFileEntry {
            path: "old_file.rs".into(),
            op: "D".into(),
            why: "removed".into(),
        }];
        let text = build_embedding_text(&payload);
        assert!(text.contains("old_file.rs (deleted)"));
    }

    #[test]
    fn thinking_insights_included() {
        let payload = make_payload();
        let text = build_embedding_text(&payload);
        assert!(text.contains("Considered OAuth but JWT is simpler"));
    }

    #[test]
    fn working_directory_as_project() {
        let payload = make_payload();
        let text = build_embedding_text(&payload);
        assert!(text.contains("project: tron"));
    }

    #[test]
    fn sections_joined_with_newline() {
        let payload = make_payload();
        let text = build_embedding_text(&payload);
        let lines: Vec<&str> = text.lines().collect();
        // title, input, actions, files, lessons, insights, decisions, tags, type, project
        assert_eq!(lines.len(), 10);
    }

    #[test]
    fn empty_payload_returns_empty() {
        let mut payload = make_payload();
        payload.title = String::new();
        payload.input = String::new();
        payload.actions = vec![];
        payload.files = vec![];
        payload.lessons = vec![];
        payload.thinking_insights = vec![];
        payload.decisions = vec![];
        payload.tags = vec![];
        payload.entry_type = String::new();
        payload.working_directory = String::new();
        let text = build_embedding_text(&payload);
        assert!(text.is_empty());
    }

    #[test]
    fn from_json_roundtrip() {
        let payload = make_payload();
        let value = serde_json::to_value(&payload).unwrap();
        let from_struct = build_embedding_text(&payload);
        let from_json = build_embedding_text_from_json(value);
        assert_eq!(from_struct, from_json);
    }

    // ── Lesson text tests ──

    #[test]
    fn build_lesson_texts_with_title() {
        let payload = make_payload();
        let texts = build_lesson_texts(&payload);
        assert_eq!(texts.len(), 1);
        assert_eq!(
            texts[0],
            "Lesson from Implement auth: Always validate tokens"
        );
    }

    #[test]
    fn build_lesson_texts_multiple() {
        let mut payload = make_payload();
        payload.lessons = vec!["First lesson".into(), "Second lesson".into()];
        let texts = build_lesson_texts(&payload);
        assert_eq!(texts.len(), 2);
        assert!(texts[0].contains("First lesson"));
        assert!(texts[1].contains("Second lesson"));
    }

    #[test]
    fn build_lesson_texts_empty_lessons() {
        let mut payload = make_payload();
        payload.lessons = vec![];
        let texts = build_lesson_texts(&payload);
        assert!(texts.is_empty());
    }

    #[test]
    fn build_lesson_texts_skips_empty_strings() {
        let mut payload = make_payload();
        payload.lessons = vec!["real lesson".into(), String::new(), "another".into()];
        let texts = build_lesson_texts(&payload);
        assert_eq!(texts.len(), 2);
    }

    #[test]
    fn build_lesson_texts_no_title() {
        let mut payload = make_payload();
        payload.title = String::new();
        payload.lessons = vec!["standalone lesson".into()];
        let texts = build_lesson_texts(&payload);
        assert_eq!(texts[0], "standalone lesson");
    }

    // ── Prefix tests ──

    #[test]
    fn document_prefix_format() {
        let result = with_document_prefix("hello world");
        assert_eq!(result, "title: none | text: hello world");
    }

    #[test]
    fn query_prefix_format() {
        let result = with_query_prefix("search term");
        assert_eq!(result, "task: search result | query: search term");
    }

    #[test]
    fn from_json_backfill_payload() {
        // Backfill-imported payloads have a subset of fields with some null
        let json = serde_json::json!({
            "title": "Fix auth bug",
            "input": "Login was broken",
            "actions": ["Fixed token validation"],
            "lessons": ["Always check expiry"],
            "decisions": [{"choice": "JWT refresh", "reason": "simpler"}],
            "tags": ["auth"],
            "entryType": "bugfix",
            "status": "completed",
            "timestamp": "2026-01-01T00:00:00Z",
            "_meta": { "source": "ledger.jsonl", "id": "abc-123" }
        });
        let text = build_embedding_text_from_json(json);
        assert!(text.contains("Fix auth bug"));
        assert!(text.contains("Login was broken"));
        assert!(text.contains("Fixed token validation"));
        assert!(text.contains("Always check expiry"));
        assert!(text.contains("JWT refresh: simpler"));
        assert!(text.contains("auth"));
    }

    #[test]
    fn entry_type_included_in_text() {
        let payload = make_payload();
        let text = build_embedding_text(&payload);
        assert!(text.contains("type: feature"));
    }

    #[test]
    fn personal_entry_type_in_text() {
        let mut payload = make_payload();
        payload.entry_type = "personal".into();
        payload.files = vec![];
        let text = build_embedding_text(&payload);
        assert!(text.contains("type: personal"));
    }

    #[test]
    fn non_code_entry_produces_meaningful_text() {
        let mut payload = make_payload();
        payload.title = "User prefers Vim keybindings".into();
        payload.entry_type = "preference".into();
        payload.input = "Discussed editor preferences".into();
        payload.actions = vec!["Noted Vim preference".into()];
        payload.files = vec![];
        payload.decisions = vec![];
        payload.lessons = vec!["User uses Vim keybindings in all editors and IDEs".into()];
        payload.thinking_insights = vec![];
        payload.tags = vec!["preference".into(), "workflow".into()];
        let text = build_embedding_text(&payload);
        assert!(text.contains("User prefers Vim keybindings"));
        assert!(text.contains("type: preference"));
        assert!(text.contains("User uses Vim keybindings"));
        assert!(text.contains("preference workflow"));
        assert!(!text.contains("(modified)"));
        assert!(!text.contains("(created)"));
    }

    #[test]
    fn knowledge_entry_from_json() {
        let json = serde_json::json!({
            "title": "RRF ranking explained",
            "input": "Discussed how RRF fusion works",
            "actions": ["Explained reciprocal rank fusion algorithm"],
            "lessons": ["RRF uses k=60 by default, higher k reduces top-rank advantage"],
            "tags": ["knowledge", "search", "algorithms"],
            "entryType": "knowledge",
            "status": "completed"
        });
        let text = build_embedding_text_from_json(json);
        assert!(text.contains("RRF ranking explained"));
        assert!(text.contains("type: knowledge"));
        assert!(text.contains("reciprocal rank fusion"));
    }

    #[test]
    fn personal_entry_lessons_become_lesson_vectors() {
        let mut payload = make_payload();
        payload.title = "User background".into();
        payload.entry_type = "personal".into();
        payload.lessons = vec![
            "User is based in Austin, TX".into(),
            "User prefers async communication".into(),
        ];
        payload.files = vec![];
        let texts = build_lesson_texts(&payload);
        assert_eq!(texts.len(), 2);
        assert!(texts[0].contains("User is based in Austin"));
        assert!(texts[1].contains("async communication"));
    }

    #[test]
    fn from_json_backfill_payload_nulls() {
        // Backfill payload where Optional fields were None → null
        let json = serde_json::json!({
            "title": "Session",
            "input": null,
            "actions": null,
            "lessons": null,
            "decisions": null,
            "tags": null,
            "entryType": null,
            "status": null,
        });
        let text = build_embedding_text_from_json(json);
        assert_eq!(text, "Session");
    }
}
