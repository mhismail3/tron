use super::support::*;

#[test]
fn session_projection_formats_frontmatter_and_section() {
    let session_id = "sess_test_create";

    let frontmatter =
        format_session_frontmatter(session_id, "2026-01-01T00:00:00Z", "claude-haiku");
    let section = format_session_section(
        "2026-01-01T00:00:00Z",
        "2026-01-01T00:15:00Z",
        "Initial work",
        "Did some things",
    );

    let content = format!("{frontmatter}{section}");
    assert!(content.starts_with("---\n"));
    assert!(content.contains("session: sess_test_create"));
    assert!(content.contains("## 2026-01-01 00:00 → 00:15 — Initial work"));
    assert!(content.contains("Did some things"));
}

#[test]
fn session_projection_appends_without_duplicate_frontmatter() {
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

    let content = format!("{frontmatter}{section1}{section2}");
    assert_eq!(content.matches("---").count(), 2); // only the frontmatter pair
    assert!(content.contains("## 2026-01-01 00:00 → 00:10 — First"));
    assert!(content.contains("## 2026-01-01 01:00 → 01:12 — Second"));
}

#[test]
fn core_memory_projection_formats_frontmatter_and_entry() {
    let content = format!(
        "{}{}",
        format_core_memory_frontmatter("2026-01-01T00:00:00Z"),
        format_core_memory_entry("2026-01-01T00:00:00Z", "Prefers Rust over Go")
    );
    assert!(content.contains("type: core-memory"));
    assert!(content.contains("Prefers Rust over Go"));
}

#[test]
fn core_memory_projection_appends_to_existing_body() {
    let content = format!(
        "---\ntype: core-memory\n---\n\n## Existing\n- Old pref\n{}",
        format_core_memory_entry("2026-01-01T01:00:00Z", "Also prefers dark mode")
    );
    assert!(content.contains("Old pref"));
    assert!(content.contains("Also prefers dark mode"));
}

#[test]
fn argument_projection_formats_document() {
    let arg = ArgumentContent {
        title: "Test Argument".to_owned(),
        thesis: "Things connect".to_owned(),
        topics: vec!["topic-a".to_owned(), "topic-b".to_owned()],
        sources: vec!["source-x".to_owned()],
        evidence: "- Evidence line 1\n- Evidence line 2".to_owned(),
    };
    let content = format_argument_document(&arg);
    assert!(content.contains("type: argument"));
    assert!(content.contains("# Test Argument"));
    assert!(content.contains("Things connect"));
    assert!(content.contains("topics: [topic-a, topic-b]"));
    assert!(content.contains("origin: retain"));
}

#[test]
fn keyword_summary_includes_session_id() {
    let s = keyword_summary("sess_xyz");
    assert!(s.contains("sess_xyz"));
}
