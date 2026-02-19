//! Embedding text extraction from memory ledger payloads.

use tron_events::types::payloads::memory::MemoryLedgerPayload;

/// Build a semantic embedding text from a memory ledger payload.
///
/// Concatenates title, input, actions, lessons, decisions, and tags
/// with newline separators between sections.
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
    if !payload.lessons.is_empty() {
        parts.push(payload.lessons.join(". "));
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

#[cfg(test)]
mod tests {
    use super::*;
    use tron_events::types::payloads::memory::{
        EventRange, LedgerDecision, LedgerTokenCost, TurnRange,
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
            files: vec![],
            decisions: vec![LedgerDecision {
                choice: "JWT".into(),
                reason: "stateless auth".into(),
            }],
            lessons: vec!["Always validate tokens".into()],
            thinking_insights: vec![],
            token_cost: LedgerTokenCost {
                input: 100,
                output: 50,
            },
            model: "claude".into(),
            working_directory: "/project".into(),
        }
    }

    #[test]
    fn all_fields_present() {
        let text = build_embedding_text(&make_payload());
        assert!(text.contains("Implement auth"));
        assert!(text.contains("Add user login"));
        assert!(text.contains("Created login form"));
        assert!(text.contains("JWT: stateless auth"));
        assert!(text.contains("Always validate tokens"));
        assert!(text.contains("auth security"));
    }

    #[test]
    fn empty_fields_omitted() {
        let mut payload = make_payload();
        payload.actions = vec![];
        payload.lessons = vec![];
        payload.decisions = vec![];
        payload.tags = vec![];
        let text = build_embedding_text(&payload);
        assert!(!text.contains("\n\n"), "no double newlines");
        assert_eq!(text.matches('\n').count(), 1); // title + input
    }

    #[test]
    fn title_only() {
        let mut payload = make_payload();
        payload.input = String::new();
        payload.actions = vec![];
        payload.lessons = vec![];
        payload.decisions = vec![];
        payload.tags = vec![];
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
    fn sections_joined_with_newline() {
        let payload = make_payload();
        let text = build_embedding_text(&payload);
        let lines: Vec<&str> = text.lines().collect();
        assert_eq!(lines.len(), 6); // title, input, actions, lessons, decisions, tags
    }

    #[test]
    fn empty_payload_returns_empty() {
        let mut payload = make_payload();
        payload.title = String::new();
        payload.input = String::new();
        payload.actions = vec![];
        payload.lessons = vec![];
        payload.decisions = vec![];
        payload.tags = vec![];
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
}
