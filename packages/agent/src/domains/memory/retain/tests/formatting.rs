use super::support::*;

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
