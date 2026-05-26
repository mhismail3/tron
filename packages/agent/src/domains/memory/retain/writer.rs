//! Memory retain path and markdown formatting helpers.
//!
//! Durable retain truth is persisted through engine resources. The helpers in
//! this module only compute projection paths and markdown bodies for
//! `materialized_file` resources; they do not own filesystem writes.

use chrono::Utc;

use super::parsing::ArgumentContent;

/// Return the path for a session's journal file:
/// `~/.tron/memory/sessions/{session_id}.md`.
pub(super) fn session_file_path(session_id: &str) -> std::path::PathBuf {
    crate::shared::paths::memory_sessions_dir().join(format!("{session_id}.md"))
}

/// Return the path for a core memory file: `~/.tron/memory/rules/{filename}`.
pub(super) fn core_memory_file_path(filename: &str) -> std::path::PathBuf {
    crate::shared::paths::memory_rules_dir().join(filename)
}

/// Return the path for an argument file:
/// `~/.tron/workspace/knowledge/arguments/{slug}.md`.
pub(super) fn argument_file_path(slug: &str) -> std::path::PathBuf {
    crate::shared::paths::knowledge_dir()
        .join("arguments")
        .join(format!("{slug}.md"))
}

/// Format YAML frontmatter for a new session memory file.
pub(super) fn format_session_frontmatter(session_id: &str, ts: &str, model: &str) -> String {
    format!("---\nsession: {session_id}\ncreated: {ts}\nmodel: {model}\n---\n")
}

fn short_ts(iso: &str) -> String {
    if iso.len() >= 16 {
        iso[..16].replace('T', " ")
    } else {
        iso.replace('T', " ")
    }
}

/// Format the section header's time component as a range.
pub(super) fn format_range(start_ts: &str, end_ts: &str) -> String {
    let start = short_ts(start_ts);
    let end = short_ts(end_ts);

    if start == end {
        return start;
    }

    let start_date = start.split_once(' ').map(|(d, _)| d).unwrap_or(&start);
    let end_parts = end.split_once(' ');

    match end_parts {
        Some((end_date, end_time)) if end_date == start_date => {
            format!("{start} → {end_time}")
        }
        _ => format!("{start} → {end}"),
    }
}

/// Format a timestamped section entry.
pub(super) fn format_session_section(
    start_ts: &str,
    end_ts: &str,
    title: &str,
    body: &str,
) -> String {
    let range = format_range(start_ts, end_ts);
    let body_trimmed = body.trim();
    if body_trimmed.is_empty() {
        format!("\n## {range} — {title}\n")
    } else {
        format!("\n## {range} — {title}\n\n{body_trimmed}\n")
    }
}

/// Split the journal text into a clean title and the body below it.
pub(super) fn split_title_and_body(journal_text: &str) -> (String, String) {
    let trimmed = journal_text.trim_start();
    let (first_line, rest) = match trimmed.split_once('\n') {
        Some((head, tail)) => (head, tail),
        None => (trimmed, ""),
    };

    let mut t = first_line.trim().trim_start_matches('#').trim();
    if let Some(after) = t
        .strip_prefix("title:")
        .or_else(|| t.strip_prefix("TITLE:"))
    {
        t = after.trim();
    }

    let title = if t.is_empty() {
        "Session summary".to_owned()
    } else {
        t.to_owned()
    };

    (title, rest.trim_start().to_owned())
}

/// Format frontmatter for a resource-backed core memory projection.
pub(super) fn format_core_memory_frontmatter(created_ts: &str) -> String {
    let today = created_ts
        .split_once('T')
        .map(|(date, _)| date)
        .unwrap_or(created_ts);
    format!("---\ntype: core-memory\ncreated: \"{today}\"\nupdated: \"{today}\"\n---\n\n")
}

/// Format a timestamped core memory update entry.
pub(super) fn format_core_memory_entry(created_ts: &str, update: &str) -> String {
    let ts = short_ts(created_ts);
    format!("\n## {ts}\n\n- {update}\n")
}

/// Format an argument document for `knowledge/arguments/{slug}.md`.
pub(super) fn format_argument_document(arg: &ArgumentContent) -> String {
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

    format!(
        "---\ntype: argument\ntags: []\ntopics: {topics_yaml}\nsources: {sources_yaml}\ncreated: \"{today}\"\norigin: retain\n---\n\n# {title}\n\n## Thesis\n\n{thesis}\n\n## Evidence\n\n{evidence}\n",
        title = arg.title,
        thesis = arg.thesis,
        evidence = arg.evidence,
    )
}
