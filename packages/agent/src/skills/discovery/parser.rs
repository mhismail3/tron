//! SKILL.md parser.
//!
//! Parses SKILL.md files with optional YAML frontmatter delimited by `---`.
//! Uses a hand-written YAML subset parser (no external YAML dependency)
//! supporting key-value pairs, booleans, strings, and arrays.
//!
//! # Bounds
//!
//! Parser enforces defense-in-depth limits independently of the caller:
//! - [`MAX_PARSE_BYTES`]: raw input byte count.
//! - [`MAX_YAML_LINES`]: frontmatter line count.
//! - [`MAX_ARRAY_ITEMS`]: size of any single YAML array (tags, allowedTools, …).
//!
//! Callers like [`crate::skills::discovery::loader`] already enforce an
//! on-disk file-size cap; these parser-side bounds protect any future caller
//! that passes in-memory content (tests, imports, IPC), ensuring a crafted
//! input cannot OOM the process or stall the discovery thread.

use thiserror::Error;

use crate::skills::types::{SkillFrontmatter, SkillSubagentMode};

/// Maximum accepted input byte count. Matches the on-disk file-size cap in
/// `crate::skills::constants::MAX_SKILL_FILE_SIZE` and provides defense in
/// depth for non-loader callers. Any input exceeding this is rejected outright.
pub const MAX_PARSE_BYTES: usize = 100 * 1024;

/// Maximum frontmatter line count. A SKILL.md with more than this many
/// frontmatter lines is either malformed or malicious; refuse rather than
/// spend CPU linearly scanning all of them.
pub const MAX_YAML_LINES: usize = 1024;

/// Maximum number of items in any single YAML array (tags, allowedTools,
/// deniedTools). Well above any realistic skill manifest.
pub const MAX_ARRAY_ITEMS: usize = 256;

/// Errors from [`parse_skill_md`]. Each variant carries enough context that
/// the discovery pipeline can surface an actionable message to the operator.
#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum ParseSkillError {
    /// Input exceeded [`MAX_PARSE_BYTES`].
    #[error("SKILL.md is {bytes} bytes, exceeds limit of {MAX_PARSE_BYTES} bytes")]
    Oversized {
        /// Observed byte count.
        bytes: usize,
    },

    /// YAML frontmatter exceeded [`MAX_YAML_LINES`] lines.
    #[error("SKILL.md frontmatter has {lines} lines, exceeds limit of {MAX_YAML_LINES}")]
    TooManyYamlLines {
        /// Observed line count.
        lines: usize,
    },

    /// A YAML array (tags, allowedTools, deniedTools, …) exceeded [`MAX_ARRAY_ITEMS`].
    #[error("SKILL.md frontmatter key '{key}' has {count} items, exceeds limit of {MAX_ARRAY_ITEMS}")]
    TooManyArrayItems {
        /// YAML key whose array was oversized.
        key: String,
        /// Observed item count.
        count: usize,
    },

    /// `subagent:` had a value other than yes/no/true/false/ask.
    ///
    /// Historically this was silently coerced to `None`, which hid typos
    /// like `subagent: maybe`. Strict parsing surfaces the error so the
    /// operator can fix the manifest.
    #[error("SKILL.md frontmatter has invalid subagent value '{value}' (expected one of: yes, no, true, false, ask)")]
    InvalidSubagentMode {
        /// The offending value as written.
        value: String,
    },
}

/// Result of parsing a SKILL.md file.
#[derive(Debug, Clone)]
pub struct ParsedSkillMd {
    /// Parsed YAML frontmatter (empty defaults if none present).
    pub frontmatter: SkillFrontmatter,
    /// Content after frontmatter (the markdown body).
    pub content: String,
    /// First non-header, non-empty line (up to 200 chars).
    pub description: String,
}

/// Parse a SKILL.md file's raw content into frontmatter, body, and description.
///
/// INVARIANT: enforces [`MAX_PARSE_BYTES`], [`MAX_YAML_LINES`], and
/// [`MAX_ARRAY_ITEMS`] independently of the caller. Rejects unknown
/// `subagent:` values rather than silently defaulting to `None`.
pub fn parse_skill_md(raw_content: &str) -> Result<ParsedSkillMd, ParseSkillError> {
    if raw_content.len() > MAX_PARSE_BYTES {
        return Err(ParseSkillError::Oversized {
            bytes: raw_content.len(),
        });
    }

    let (yaml, body) = extract_frontmatter(raw_content);
    let frontmatter = match yaml {
        Some(yaml_str) => parse_simple_yaml(&yaml_str)?,
        None => SkillFrontmatter::default(),
    };
    let description = extract_description(&body);

    Ok(ParsedSkillMd {
        frontmatter,
        content: body,
        description,
    })
}

/// Extract YAML frontmatter from content.
///
/// Looks for `---` delimited blocks at the start of the content.
/// Returns `(yaml_string, body_after_frontmatter)`.
fn extract_frontmatter(content: &str) -> (Option<String>, String) {
    let trimmed = content.trim_start();
    if !trimmed.starts_with("---") {
        return (None, content.to_string());
    }

    // Find the closing ---
    let after_first = &trimmed[3..];
    let after_first = after_first.strip_prefix('\n').unwrap_or(after_first);

    if let Some(end_idx) = after_first.find("\n---") {
        let yaml = after_first[..end_idx].to_string();
        let body_start = end_idx + 4; // "\n---".len()
        let body = if body_start < after_first.len() {
            let rest = &after_first[body_start..];
            rest.strip_prefix('\n').unwrap_or(rest).to_string()
        } else {
            String::new()
        };
        (Some(yaml), body)
    } else {
        // No closing --- found, treat entire content as body
        (None, content.to_string())
    }
}

/// Parse a simple YAML string into `SkillFrontmatter`.
///
/// Supports:
/// - Simple key-value pairs: `name: value`
/// - Boolean values: `true`/`false` (case-insensitive)
/// - Inline arrays: `tags: [tag1, tag2]`
/// - Multi-line arrays: `tags:\n  - item1\n  - item2`
/// - Quoted strings: `name: "My Skill"`
fn parse_simple_yaml(yaml: &str) -> Result<SkillFrontmatter, ParseSkillError> {
    let lines: Vec<&str> = yaml.lines().collect();
    if lines.len() > MAX_YAML_LINES {
        return Err(ParseSkillError::TooManyYamlLines { lines: lines.len() });
    }

    let mut fm = SkillFrontmatter::default();
    let mut i = 0;

    while i < lines.len() {
        let line = lines[i].trim();
        i += 1;

        if line.is_empty() || line.starts_with('#') {
            continue;
        }

        let Some((key, value)) = line.split_once(':') else {
            continue;
        };

        let key = key.trim();
        let value = value.trim();

        match key {
            "name" => fm.name = Some(unquote(value)),
            "description" => fm.description = Some(unquote(value)),
            "version" => fm.version = Some(unquote(value)),
            "subagentModel" | "subagent_model" => {
                fm.subagent_model = Some(unquote(value));
            }
            "subagent" => {
                fm.subagent = parse_subagent_mode(value)?;
            }
            "tags" => {
                fm.tags = Some(parse_array_value("tags", value, &lines, &mut i)?);
            }
            "allowedTools" | "allowed_tools" => {
                fm.allowed_tools = Some(parse_array_value(
                    "allowedTools",
                    value,
                    &lines,
                    &mut i,
                )?);
            }
            "deniedTools" | "denied_tools" => {
                fm.denied_tools = Some(parse_array_value(
                    "deniedTools",
                    value,
                    &lines,
                    &mut i,
                )?);
            }
            _ => {}
        }
    }

    Ok(fm)
}

/// Parse an array value, either inline `[a, b]` or multi-line `- item`.
fn parse_array_value(
    key: &str,
    value: &str,
    lines: &[&str],
    i: &mut usize,
) -> Result<Vec<String>, ParseSkillError> {
    // Inline array: [item1, item2]
    if value.starts_with('[') {
        return parse_inline_array(key, value);
    }

    // If value is non-empty and not a bracket, treat as single item.
    if !value.is_empty() {
        return Ok(vec![unquote(value)]);
    }

    // Multi-line array: subsequent lines starting with -
    let mut items = Vec::new();
    while *i < lines.len() {
        let line = lines[*i];
        let trimmed = line.trim();
        let parsed = if let Some(item) = trimmed.strip_prefix("- ") {
            Some(unquote(item.trim()))
        } else if trimmed.starts_with('-') && trimmed.len() > 1 {
            Some(unquote(trimmed[1..].trim()))
        } else {
            None
        };
        match parsed {
            Some(item) => {
                if items.len() >= MAX_ARRAY_ITEMS {
                    return Err(ParseSkillError::TooManyArrayItems {
                        key: key.to_string(),
                        count: items.len() + 1,
                    });
                }
                items.push(item);
                *i += 1;
            }
            None => break,
        }
    }
    Ok(items)
}

/// Parse an inline array like `[item1, item2, item3]`.
fn parse_inline_array(key: &str, value: &str) -> Result<Vec<String>, ParseSkillError> {
    let inner = value.trim_start_matches('[').trim_end_matches(']').trim();

    if inner.is_empty() {
        return Ok(Vec::new());
    }

    let items: Vec<String> = inner.split(',').map(|s| unquote(s.trim())).collect();
    if items.len() > MAX_ARRAY_ITEMS {
        return Err(ParseSkillError::TooManyArrayItems {
            key: key.to_string(),
            count: items.len(),
        });
    }
    Ok(items)
}

/// Parse a subagent mode value.
///
/// Strict: unknown values yield [`ParseSkillError::InvalidSubagentMode`] so
/// that typos (`subagent: maybe`) surface instead of silently defaulting to
/// "no subagent" behavior. An empty value (absent key, trailing-colon) is
/// treated as "no preference" and yields `Ok(None)`.
fn parse_subagent_mode(value: &str) -> Result<Option<SkillSubagentMode>, ParseSkillError> {
    let cleaned = unquote(value).trim().to_lowercase();
    if cleaned.is_empty() {
        return Ok(None);
    }
    match cleaned.as_str() {
        "no" | "false" => Ok(Some(SkillSubagentMode::No)),
        "ask" => Ok(Some(SkillSubagentMode::Ask)),
        "yes" | "true" => Ok(Some(SkillSubagentMode::Yes)),
        _ => Err(ParseSkillError::InvalidSubagentMode {
            value: unquote(value).trim().to_string(),
        }),
    }
}

/// Remove surrounding quotes from a string value.
fn unquote(s: &str) -> String {
    let trimmed = s.trim();
    if (trimmed.starts_with('"') && trimmed.ends_with('"'))
        || (trimmed.starts_with('\'') && trimmed.ends_with('\''))
    {
        trimmed[1..trimmed.len() - 1].to_string()
    } else {
        trimmed.to_string()
    }
}

/// Extract a description from the content body.
///
/// Returns the first non-header, non-empty, non-horizontal-rule line,
/// truncated to 200 characters.
fn extract_description(content: &str) -> String {
    let mut in_code_block = false;

    for line in content.lines() {
        let trimmed = line.trim();

        // Track code blocks
        if trimmed.starts_with("```") {
            in_code_block = !in_code_block;
            continue;
        }

        if in_code_block {
            continue;
        }

        // Skip empty lines
        if trimmed.is_empty() {
            continue;
        }

        // Skip headers
        if trimmed.starts_with('#') {
            continue;
        }

        // Skip horizontal rules (3+ dashes, asterisks, or underscores)
        if is_horizontal_rule(trimmed) {
            continue;
        }

        // Found a content line
        let desc = trimmed.to_string();
        if desc.len() > 200 {
            return desc[..desc.floor_char_boundary(200)].to_string();
        }
        return desc;
    }

    String::new()
}

/// Check if a line is a markdown horizontal rule.
fn is_horizontal_rule(line: &str) -> bool {
    if line.len() < 3 {
        return false;
    }
    let mut chars = line.chars();
    let Some(first) = chars.next() else {
        return false;
    };
    if first != '-' && first != '*' && first != '_' {
        return false;
    }
    chars.all(|c| c == first)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_valid_frontmatter() {
        let content = r"---
name: My Skill
description: A great skill
version: 1.0.0
tags: [tag1, tag2]
---
# My Skill

This is the body.";

        let result = parse_skill_md(content).unwrap();
        assert_eq!(result.frontmatter.name.as_deref(), Some("My Skill"));
        assert_eq!(
            result.frontmatter.description.as_deref(),
            Some("A great skill")
        );
        assert_eq!(result.frontmatter.version.as_deref(), Some("1.0.0"));
        assert_eq!(
            result.frontmatter.tags,
            Some(vec!["tag1".to_string(), "tag2".to_string()])
        );
        assert!(result.content.contains("This is the body."));
    }

    #[test]
    fn test_parse_no_frontmatter() {
        let content = "# My Skill\n\nJust a body.";
        let result = parse_skill_md(content).unwrap();
        assert!(result.frontmatter.name.is_none());
        assert_eq!(result.content, content);
    }

    #[test]
    fn test_parse_empty_body() {
        let content = "---\nname: Empty\n---\n";
        let result = parse_skill_md(content).unwrap();
        assert_eq!(result.frontmatter.name.as_deref(), Some("Empty"));
        assert!(result.content.is_empty() || result.content.trim().is_empty());
    }

    #[test]
    fn test_parse_multiline_tags() {
        let content = "---\ntags:\n  - alpha\n  - beta\n  - gamma\n---\nBody";
        let result = parse_skill_md(content).unwrap();
        assert_eq!(
            result.frontmatter.tags,
            Some(vec![
                "alpha".to_string(),
                "beta".to_string(),
                "gamma".to_string()
            ])
        );
    }

    #[test]
    fn test_parse_boolean_subagent() {
        let content = "---\nsubagent: yes\n---\nBody";
        let result = parse_skill_md(content).unwrap();
        assert_eq!(result.frontmatter.subagent, Some(SkillSubagentMode::Yes));
    }

    #[test]
    fn test_parse_subagent_ask() {
        let content = "---\nsubagent: ask\n---\nBody";
        let result = parse_skill_md(content).unwrap();
        assert_eq!(result.frontmatter.subagent, Some(SkillSubagentMode::Ask));
    }

    #[test]
    fn test_parse_quoted_strings() {
        let content = "---\nname: \"Quoted Name\"\ndescription: 'Single Quoted'\n---\nBody";
        let result = parse_skill_md(content).unwrap();
        assert_eq!(result.frontmatter.name.as_deref(), Some("Quoted Name"));
        assert_eq!(
            result.frontmatter.description.as_deref(),
            Some("Single Quoted")
        );
    }

    #[test]
    fn test_parse_no_closing_frontmatter() {
        let content = "---\nname: Incomplete\nSome content";
        let result = parse_skill_md(content).unwrap();
        // No closing --- means no frontmatter parsed
        assert!(result.frontmatter.name.is_none());
        assert_eq!(result.content, content);
    }

    #[test]
    fn test_parse_denied_tools() {
        let content = "---\ndeniedTools: [Bash, Write]\n---\nBody";
        let result = parse_skill_md(content).unwrap();
        assert_eq!(
            result.frontmatter.denied_tools,
            Some(vec!["Bash".to_string(), "Write".to_string()])
        );
    }

    #[test]
    fn test_parse_allowed_tools() {
        let content = "---\nallowedTools:\n  - Read\n  - Grep\n---\nBody";
        let result = parse_skill_md(content).unwrap();
        assert_eq!(
            result.frontmatter.allowed_tools,
            Some(vec!["Read".to_string(), "Grep".to_string()])
        );
    }

    #[test]
    fn test_description_extraction_skips_headers() {
        let content = "# Title\n## Subtitle\n\nActual description here.";
        let result = parse_skill_md(content).unwrap();
        assert_eq!(result.description, "Actual description here.");
    }

    #[test]
    fn test_description_extraction_skips_horizontal_rules() {
        let content = "---\nname: Test\n---\n---\n***\nActual content.";
        let result = parse_skill_md(content).unwrap();
        assert_eq!(result.description, "Actual content.");
    }

    #[test]
    fn test_description_extraction_skips_code_blocks() {
        let content = "```\ncode line\n```\nDescription after code.";
        let result = parse_skill_md(content).unwrap();
        assert_eq!(result.description, "Description after code.");
    }

    #[test]
    fn test_description_truncation() {
        let long_line = "a".repeat(300);
        let content = format!("# Header\n\n{long_line}");
        let result = parse_skill_md(&content).unwrap();
        assert_eq!(result.description.len(), 200);
    }

    #[test]
    fn test_description_truncation_multibyte_utf8() {
        // Each emoji is 4 bytes. 51 emojis = 204 bytes, so byte 200 is mid-char.
        let emojis = "\u{1F600}".repeat(51);
        let content = format!("# Header\n\n{emojis}");
        let result = parse_skill_md(&content).unwrap();
        assert!(result.description.len() <= 200);
        assert!(
            result
                .description
                .is_char_boundary(result.description.len())
        );
        // Should truncate to 50 emojis = 200 bytes
        assert_eq!(result.description.chars().count(), 50);
    }

    #[test]
    fn test_description_empty_content() {
        let result = parse_skill_md("").unwrap();
        assert_eq!(result.description, "");
    }

    #[test]
    fn test_unquote() {
        assert_eq!(unquote("\"hello\""), "hello");
        assert_eq!(unquote("'world'"), "world");
        assert_eq!(unquote("plain"), "plain");
        assert_eq!(unquote("  spaces  "), "spaces");
    }

    #[test]
    fn test_inline_array_empty() {
        assert!(parse_inline_array("tags", "[]").unwrap().is_empty());
    }

    #[test]
    fn test_inline_array_single() {
        assert_eq!(parse_inline_array("tags", "[one]").unwrap(), vec!["one"]);
    }

    #[test]
    fn test_is_horizontal_rule() {
        assert!(is_horizontal_rule("---"));
        assert!(is_horizontal_rule("***"));
        assert!(is_horizontal_rule("___"));
        assert!(is_horizontal_rule("-----"));
        assert!(!is_horizontal_rule("--"));
        assert!(!is_horizontal_rule("abc"));
        assert!(!is_horizontal_rule("-*-"));
    }

    #[test]
    fn test_subagent_model() {
        let content = "---\nsubagentModel: claude-haiku\n---\nBody";
        let result = parse_skill_md(content).unwrap();
        assert_eq!(
            result.frontmatter.subagent_model.as_deref(),
            Some("claude-haiku")
        );
    }

    #[test]
    fn test_denied_patterns_in_frontmatter_ignored() {
        // deniedPatterns was removed; unknown keys are silently skipped
        let content = "---\ndeniedPatterns:\n  - tool: Bash\n---\nBody";
        let result = parse_skill_md(content).unwrap();
        assert_eq!(result.content, "Body");
        assert!(result.frontmatter.denied_tools.is_none());
    }

    #[test]
    fn test_snake_case_keys() {
        let content = "---\nallowed_tools: [Read]\nsubagent_model: haiku\n---\nBody";
        let result = parse_skill_md(content).unwrap();
        assert_eq!(
            result.frontmatter.allowed_tools,
            Some(vec!["Read".to_string()])
        );
        assert_eq!(result.frontmatter.subagent_model.as_deref(), Some("haiku"));
    }

    // ── H19 bounds + M23 strict subagent parsing ─────────────────────────────

    #[test]
    fn rejects_oversized_input() {
        let content = "a".repeat(MAX_PARSE_BYTES + 1);
        let err = parse_skill_md(&content).unwrap_err();
        assert!(
            matches!(err, ParseSkillError::Oversized { bytes } if bytes == MAX_PARSE_BYTES + 1),
            "expected Oversized error, got {err:?}"
        );
    }

    #[test]
    fn accepts_input_at_exact_limit() {
        // A file at exactly MAX_PARSE_BYTES is fine — boundary inclusive.
        let body = "a".repeat(MAX_PARSE_BYTES);
        assert_eq!(body.len(), MAX_PARSE_BYTES);
        let _ = parse_skill_md(&body).expect("limit-sized input must parse");
    }

    #[test]
    fn rejects_too_many_yaml_lines() {
        let mut yaml = String::from("---\n");
        for _ in 0..(MAX_YAML_LINES + 1) {
            yaml.push_str("# comment\n");
        }
        yaml.push_str("---\nbody");
        // Only attempt if under the byte cap; otherwise Oversized fires first.
        if yaml.len() <= MAX_PARSE_BYTES {
            let err = parse_skill_md(&yaml).unwrap_err();
            assert!(
                matches!(err, ParseSkillError::TooManyYamlLines { .. }),
                "expected TooManyYamlLines, got {err:?}"
            );
        }
    }

    #[test]
    fn rejects_inline_array_with_too_many_items() {
        let items: Vec<String> = (0..=MAX_ARRAY_ITEMS).map(|i| format!("t{i}")).collect();
        let inline = format!("[{}]", items.join(","));
        let content = format!("---\ntags: {inline}\n---\nBody");
        let err = parse_skill_md(&content).unwrap_err();
        assert!(
            matches!(&err, ParseSkillError::TooManyArrayItems { key, count } if key == "tags" && *count > MAX_ARRAY_ITEMS),
            "expected TooManyArrayItems on inline array, got {err:?}"
        );
    }

    #[test]
    fn rejects_multiline_array_with_too_many_items() {
        let mut content = String::from("---\ntags:\n");
        for i in 0..=MAX_ARRAY_ITEMS {
            content.push_str(&format!("  - t{i}\n"));
        }
        content.push_str("---\nBody");
        if content.len() <= MAX_PARSE_BYTES {
            let err = parse_skill_md(&content).unwrap_err();
            assert!(
                matches!(&err, ParseSkillError::TooManyArrayItems { key, .. } if key == "tags"),
                "expected TooManyArrayItems on multi-line array, got {err:?}"
            );
        }
    }

    #[test]
    fn rejects_array_items_limit_shared_across_keys() {
        // Per-key enforcement: allowedTools with many items triggers with
        // its own key name, not "tags".
        let items: Vec<String> = (0..=MAX_ARRAY_ITEMS).map(|i| format!("T{i}")).collect();
        let inline = format!("[{}]", items.join(","));
        let content = format!("---\nallowedTools: {inline}\n---\nBody");
        let err = parse_skill_md(&content).unwrap_err();
        assert!(
            matches!(&err, ParseSkillError::TooManyArrayItems { key, .. } if key == "allowedTools"),
            "expected allowedTools key in error, got {err:?}"
        );
    }

    #[test]
    fn rejects_subagent_typo() {
        let content = "---\nsubagent: maybe\n---\nBody";
        let err = parse_skill_md(content).unwrap_err();
        assert!(
            matches!(err, ParseSkillError::InvalidSubagentMode { value } if value == "maybe"),
            "expected InvalidSubagentMode(\"maybe\")"
        );
    }

    #[test]
    fn rejects_subagent_with_leading_whitespace_typo() {
        // Defends against a subtle cause of the pre-fix silent default:
        // `subagent:   maybe` with padding still yielded None.
        let content = "---\nsubagent:     maybe\n---\nBody";
        let err = parse_skill_md(content).unwrap_err();
        assert!(matches!(err, ParseSkillError::InvalidSubagentMode { .. }));
    }

    #[test]
    fn empty_subagent_value_is_none_not_error() {
        // An absent or empty `subagent:` value is a reasonable "no preference"
        // signal, not a typo. Keep it as Ok(None) for backwards compatibility
        // with skills that omit the key.
        let content = "---\nsubagent:\n---\nBody";
        let result = parse_skill_md(content).unwrap();
        assert!(result.frontmatter.subagent.is_none());
    }

    #[test]
    fn subagent_value_trimmed_before_matching() {
        let content = "---\nsubagent:    yes   \n---\nBody";
        let result = parse_skill_md(content).unwrap();
        assert_eq!(result.frontmatter.subagent, Some(SkillSubagentMode::Yes));
    }
}
