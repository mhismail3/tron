use super::support::*;

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

#[test]
fn keyword_summary_includes_session_id() {
    let s = keyword_summary("sess_xyz");
    assert!(s.contains("sess_xyz"));
}
