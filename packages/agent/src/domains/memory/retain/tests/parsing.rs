use super::support::*;

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
