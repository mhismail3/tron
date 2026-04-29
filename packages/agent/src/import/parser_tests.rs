use super::*;
use std::io::Write;

#[test]
fn decode_project_dir_standard() {
    // Create a real nested path under a tempdir so the decoder's filesystem
    // walk-up finds it. Using an FS-independent fixture (not the caller's
    // home dir) keeps this test portable across machines.
    let dir = tempfile::tempdir().unwrap();
    let nested = dir.path().join("projects").join("tron");
    fs::create_dir_all(&nested).unwrap();
    let nested_str = nested.to_str().unwrap();
    let encoded = format!("-{}", nested_str.trim_start_matches('/').replace('/', "-"));
    assert_eq!(decode_project_dir(&encoded), nested_str);
}

#[test]
fn decode_project_dir_root() {
    assert_eq!(decode_project_dir("-"), "/");
}

#[test]
fn decode_project_dir_empty() {
    assert_eq!(decode_project_dir(""), "");
}

#[test]
fn decode_project_dir_short_path() {
    assert_eq!(decode_project_dir("-tmp"), "/tmp");
}

#[test]
fn discover_projects_empty_dir() {
    let dir = tempfile::tempdir().unwrap();
    let projects = discover_projects(dir.path()).unwrap();
    assert!(projects.is_empty());
}

#[test]
fn discover_projects_nonexistent_dir() {
    let result = discover_projects(Path::new("/nonexistent/path"));
    assert!(matches!(result, Err(ImportError::NoClaudeDirectory { .. })));
}

#[test]
fn discover_projects_with_sessions() {
    let claude_dir = tempfile::tempdir().unwrap();
    let real_root = tempfile::tempdir().unwrap();
    let real_parent = real_root.path().join("projects");
    fs::create_dir_all(&real_parent).unwrap();

    let expected_project = real_parent.join("test-project");
    let expected_project_str = expected_project.to_str().unwrap();
    let encoded_project = format!(
        "-{}",
        expected_project_str
            .trim_start_matches('/')
            .replace('/', "-")
    );
    let proj_dir = claude_dir.path().join(encoded_project);
    fs::create_dir(&proj_dir).unwrap();

    // Write a sample JSONL file
    let session_file = proj_dir.join("abc-123.jsonl");
    let mut f = fs::File::create(&session_file).unwrap();
    writeln!(f, r#"{{"type":"user","uuid":"u1","timestamp":"2026-01-01T00:00:00Z","message":{{"role":"user","content":"hi"}}}}"#).unwrap();

    let projects = discover_projects(claude_dir.path()).unwrap();
    assert_eq!(projects.len(), 1);
    assert_eq!(projects[0].project_path, expected_project_str);
    assert_eq!(projects[0].session_count, 1);
}

#[test]
fn discover_projects_skips_empty_dirs() {
    let dir = tempfile::tempdir().unwrap();
    let proj_dir = dir.path().join("-Users-empty");
    fs::create_dir(&proj_dir).unwrap();
    // No JSONL files

    let projects = discover_projects(dir.path()).unwrap();
    assert!(projects.is_empty());
}

#[test]
fn discover_sessions_extracts_metadata() {
    let dir = tempfile::tempdir().unwrap();
    let session_file = dir.path().join("sess-001.jsonl");
    let mut f = fs::File::create(&session_file).unwrap();

    // User message
    writeln!(f, r#"{{"type":"user","uuid":"u1","parentUuid":null,"timestamp":"2026-01-01T00:00:00Z","promptId":"p1","message":{{"role":"user","content":"hello"}}}}"#).unwrap();
    // Assistant message
    writeln!(f, r#"{{"type":"assistant","uuid":"a1","parentUuid":"u1","timestamp":"2026-01-01T00:00:01Z","slug":"my-slug","message":{{"id":"msg1","role":"assistant","model":"claude-opus-4-6","content":[{{"type":"text","text":"hi"}}],"usage":{{"input_tokens":100,"output_tokens":50}}}}}}"#).unwrap();
    // Custom title
    writeln!(
        f,
        r#"{{"type":"custom-title","customTitle":"My Session","sessionId":"sess-001"}}"#
    )
    .unwrap();

    let sessions = discover_sessions(dir.path()).unwrap();
    assert_eq!(sessions.len(), 1);

    let s = &sessions[0];
    assert_eq!(s.session_uuid, "sess-001");
    assert_eq!(s.title.as_deref(), Some("My Session"));
    assert_eq!(s.slug.as_deref(), Some("my-slug"));
    assert_eq!(s.model.as_deref(), Some("claude-opus-4-6"));
    assert_eq!(s.first_timestamp.as_deref(), Some("2026-01-01T00:00:00Z"));
    assert_eq!(s.last_timestamp.as_deref(), Some("2026-01-01T00:00:01Z"));
    assert_eq!(s.message_count, 2); // 1 user + 1 assistant
    assert_eq!(s.input_tokens, 100);
    assert_eq!(s.output_tokens, 50);
}

#[test]
fn parse_session_skips_malformed_lines() {
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("test.jsonl");
    let mut f = fs::File::create(&file).unwrap();

    writeln!(f, r#"{{"type":"user","uuid":"u1","timestamp":"2026-01-01T00:00:00Z","message":{{"role":"user","content":"ok"}}}}"#).unwrap();
    writeln!(f, "NOT VALID JSON").unwrap();
    writeln!(f, r#"{{"type":"assistant","uuid":"a1","timestamp":"2026-01-01T00:00:01Z","message":{{"role":"assistant","content":[{{"type":"text","text":"hi"}}]}}}}"#).unwrap();

    let records = parse_session(&file).unwrap();
    assert_eq!(records.len(), 2);
    assert_eq!(records[0].record_type, "user");
    assert_eq!(records[1].record_type, "assistant");
}

#[test]
fn parse_session_empty_file() {
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("empty.jsonl");
    fs::File::create(&file).unwrap();

    let records = parse_session(&file).unwrap();
    assert!(records.is_empty());
}

#[test]
fn parse_session_file_not_found() {
    let result = parse_session(Path::new("/nonexistent/file.jsonl"));
    assert!(matches!(result, Err(ImportError::SessionNotFound { .. })));
}

#[test]
fn parse_session_skips_blank_lines() {
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("blanks.jsonl");
    let mut f = fs::File::create(&file).unwrap();

    writeln!(
        f,
        r#"{{"type":"user","uuid":"u1","message":{{"role":"user","content":"a"}}}}"#
    )
    .unwrap();
    writeln!(f).unwrap(); // blank line
    writeln!(f, "   ").unwrap(); // whitespace-only line
    writeln!(
        f,
        r#"{{"type":"user","uuid":"u2","message":{{"role":"user","content":"b"}}}}"#
    )
    .unwrap();

    let records = parse_session(&file).unwrap();
    assert_eq!(records.len(), 2);
}

#[test]
fn discover_sessions_nonexistent_dir() {
    let result = discover_sessions(Path::new("/nonexistent"));
    assert!(matches!(result, Err(ImportError::SessionNotFound { .. })));
}

#[test]
fn parse_session_detailed_tracks_line_numbers_for_unparseable_lines() {
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("detailed.jsonl");
    let mut f = fs::File::create(&file).unwrap();

    // line 1: good user message
    writeln!(
        f,
        r#"{{"type":"user","uuid":"u1","timestamp":"2026-01-01T00:00:00Z","message":{{"role":"user","content":"ok"}}}}"#
    )
    .unwrap();
    // line 2: blank (not counted in total_non_blank_lines)
    writeln!(f).unwrap();
    // line 3: unparseable
    writeln!(f, "NOT JSON").unwrap();
    // line 4: good user message
    writeln!(
        f,
        r#"{{"type":"user","uuid":"u2","timestamp":"2026-01-01T00:00:01Z","message":{{"role":"user","content":"ok2"}}}}"#
    )
    .unwrap();

    let outcome = parse_session_detailed(&file).unwrap();
    assert_eq!(outcome.records.len(), 2);
    assert_eq!(outcome.warnings.len(), 1);
    assert_eq!(outcome.warnings[0].line_number, 3);
    assert_eq!(outcome.total_non_blank_lines, 3);
    // Invariant: records + warnings == non-blank lines
    assert_eq!(
        outcome.records.len() + outcome.warnings.len(),
        outcome.total_non_blank_lines
    );
}

#[test]
fn parse_session_detailed_warning_snippet_truncates_long_lines() {
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("long.jsonl");
    let mut f = fs::File::create(&file).unwrap();

    // 200 x's — longer than the 120-char snippet cap.
    let garbage: String = "x".repeat(200);
    writeln!(f, "{garbage}").unwrap();

    let outcome = parse_session_detailed(&file).unwrap();
    assert_eq!(outcome.warnings.len(), 1);
    let w = &outcome.warnings[0];
    assert!(
        w.snippet.ends_with('…'),
        "long snippet should end with ellipsis; got: {}",
        w.snippet
    );
    // The truncation includes 120 x's plus the ellipsis.
    assert!(w.snippet.len() < garbage.len());
}

#[test]
fn parse_session_wrapper_discards_warnings() {
    // Regression guard: the legacy `parse_session` API must remain a thin
    // wrapper that drops warnings; callers that want warnings use
    // `parse_session_detailed`.
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("mixed.jsonl");
    let mut f = fs::File::create(&file).unwrap();
    writeln!(f, "NOT JSON").unwrap();
    writeln!(
        f,
        r#"{{"type":"user","uuid":"u1","message":{{"role":"user","content":"ok"}}}}"#
    )
    .unwrap();

    let records = parse_session(&file).unwrap();
    assert_eq!(records.len(), 1);
    assert_eq!(records[0].record_type, "user");
}
