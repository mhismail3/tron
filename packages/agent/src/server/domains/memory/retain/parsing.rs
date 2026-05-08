//! Structured output parsing for memory retain.

/// Parsed output from the smart router summarizer.
#[derive(Debug, Default)]
pub(super) struct RetainOutput {
    pub(super) journal: Option<String>,
    pub(super) core_memory: Option<CoreMemoryUpdate>,
    pub(super) argument: Option<ArgumentContent>,
}

/// A core memory update to write to `memory/rules/{file}`.
#[derive(Debug)]
pub(super) struct CoreMemoryUpdate {
    pub(super) file: String,
    pub(super) update: String,
}

/// Argument content to write to `knowledge/arguments/{slug}.md`.
#[derive(Debug)]
pub(super) struct ArgumentContent {
    pub(super) title: String,
    pub(super) thesis: String,
    pub(super) topics: Vec<String>,
    pub(super) sources: Vec<String>,
    pub(super) evidence: String,
}

/// Parse structured retain output with `<journal>`, `<core_memory>`,
/// `<argument>` sections. Falls back gracefully: if no tags are found, the
/// entire output is treated as journal.
pub(super) fn parse_retain_output(raw: &str) -> RetainOutput {
    let mut result = RetainOutput::default();

    if let Some(content) = extract_tag(raw, "journal") {
        result.journal = Some(content);
    }

    if let Some(content) = extract_tag(raw, "core_memory") {
        result.core_memory = parse_core_memory(&content);
    }

    if let Some(content) = extract_tag(raw, "argument") {
        result.argument = parse_argument(&content);
    }

    if result.journal.is_none() {
        result.journal = Some(raw.to_owned());
    }

    result
}

/// Extract content between `<tag>` and `</tag>`.
pub(super) fn extract_tag(text: &str, tag: &str) -> Option<String> {
    let open = format!("<{tag}>");
    let close = format!("</{tag}>");
    let start = text.find(&open)?;
    let end = text.find(&close)?;
    if end <= start {
        return None;
    }
    Some(text[start + open.len()..end].trim().to_owned())
}

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
pub(super) fn parse_bracket_list(s: &str) -> Vec<String> {
    let s = s.trim();
    let s = s.strip_prefix('[').unwrap_or(s);
    let s = s.strip_suffix(']').unwrap_or(s);
    s.split(',')
        .map(|item| item.trim().to_owned())
        .filter(|item| !item.is_empty())
        .collect()
}

/// Convert a title to a kebab-case slug.
pub(super) fn slugify(title: &str) -> String {
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
