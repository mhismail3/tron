//! SKILL.md parser.
//!
//! Parses SKILL.md files with optional YAML frontmatter delimited by `---`.
//! Uses a hand-written YAML subset parser (no external YAML dependency)
//! supporting key-value pairs, booleans, strings, and arrays.

use crate::types::{SkillFrontmatter, SkillSubagentMode};

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
pub fn parse_skill_md(raw_content: &str) -> ParsedSkillMd {
    let (yaml, body) = extract_frontmatter(raw_content);
    let frontmatter = match yaml {
        Some(yaml_str) => parse_simple_yaml(&yaml_str),
        None => SkillFrontmatter::default(),
    };
    let description = extract_description(&body);

    ParsedSkillMd {
        frontmatter,
        content: body,
        description,
    }
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
fn parse_simple_yaml(yaml: &str) -> SkillFrontmatter {
    let mut fm = SkillFrontmatter::default();
    let lines: Vec<&str> = yaml.lines().collect();
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
                fm.subagent = parse_subagent_mode(value);
            }
            "tags" => {
                fm.tags = Some(parse_array_value(value, &lines, &mut i));
            }
            "allowedTools" | "allowed_tools" => {
                fm.allowed_tools = Some(parse_array_value(value, &lines, &mut i));
            }
            "deniedTools" | "denied_tools" => {
                fm.denied_tools = Some(parse_array_value(value, &lines, &mut i));
            }
            _ => {}
        }
    }

    fm
}

/// Parse an array value, either inline `[a, b]` or multi-line `- item`.
fn parse_array_value(value: &str, lines: &[&str], i: &mut usize) -> Vec<String> {
    // Inline array: [item1, item2]
    if value.starts_with('[') {
        return parse_inline_array(value);
    }

    // If value is non-empty and not a bracket, treat as single item
    if !value.is_empty() {
        return vec![unquote(value)];
    }

    // Multi-line array: subsequent lines starting with -
    let mut items = Vec::new();
    while *i < lines.len() {
        let line = lines[*i];
        let trimmed = line.trim();
        if let Some(item) = trimmed.strip_prefix("- ") {
            items.push(unquote(item.trim()));
            *i += 1;
        } else if trimmed.starts_with('-') && trimmed.len() > 1 {
            items.push(unquote(trimmed[1..].trim()));
            *i += 1;
        } else {
            break;
        }
    }
    items
}

/// Parse an inline array like `[item1, item2, item3]`.
fn parse_inline_array(value: &str) -> Vec<String> {
    let inner = value
        .trim_start_matches('[')
        .trim_end_matches(']')
        .trim();

    if inner.is_empty() {
        return Vec::new();
    }

    inner.split(',').map(|s| unquote(s.trim())).collect()
}

/// Parse a subagent mode value.
fn parse_subagent_mode(value: &str) -> Option<SkillSubagentMode> {
    let cleaned = unquote(value).to_lowercase();
    match cleaned.as_str() {
        "no" | "false" => Some(SkillSubagentMode::No),
        "ask" => Some(SkillSubagentMode::Ask),
        "yes" | "true" => Some(SkillSubagentMode::Yes),
        _ => None,
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
            return desc[..200].to_string();
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
    let chars: Vec<char> = line.chars().collect();
    let first = chars[0];
    if first != '-' && first != '*' && first != '_' {
        return false;
    }
    chars.iter().all(|&c| c == first)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_valid_frontmatter() {
        let content = r#"---
name: My Skill
description: A great skill
version: 1.0.0
tags: [tag1, tag2]
---
# My Skill

This is the body."#;

        let result = parse_skill_md(content);
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
        let result = parse_skill_md(content);
        assert!(result.frontmatter.name.is_none());
        assert_eq!(result.content, content);
    }

    #[test]
    fn test_parse_empty_body() {
        let content = "---\nname: Empty\n---\n";
        let result = parse_skill_md(content);
        assert_eq!(result.frontmatter.name.as_deref(), Some("Empty"));
        assert!(result.content.is_empty() || result.content.trim().is_empty());
    }

    #[test]
    fn test_parse_multiline_tags() {
        let content = "---\ntags:\n  - alpha\n  - beta\n  - gamma\n---\nBody";
        let result = parse_skill_md(content);
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
        let result = parse_skill_md(content);
        assert_eq!(result.frontmatter.subagent, Some(SkillSubagentMode::Yes));
    }

    #[test]
    fn test_parse_subagent_ask() {
        let content = "---\nsubagent: ask\n---\nBody";
        let result = parse_skill_md(content);
        assert_eq!(result.frontmatter.subagent, Some(SkillSubagentMode::Ask));
    }

    #[test]
    fn test_parse_quoted_strings() {
        let content = "---\nname: \"Quoted Name\"\ndescription: 'Single Quoted'\n---\nBody";
        let result = parse_skill_md(content);
        assert_eq!(result.frontmatter.name.as_deref(), Some("Quoted Name"));
        assert_eq!(
            result.frontmatter.description.as_deref(),
            Some("Single Quoted")
        );
    }

    #[test]
    fn test_parse_no_closing_frontmatter() {
        let content = "---\nname: Incomplete\nSome content";
        let result = parse_skill_md(content);
        // No closing --- means no frontmatter parsed
        assert!(result.frontmatter.name.is_none());
        assert_eq!(result.content, content);
    }

    #[test]
    fn test_parse_denied_tools() {
        let content = "---\ndeniedTools: [Bash, Write]\n---\nBody";
        let result = parse_skill_md(content);
        assert_eq!(
            result.frontmatter.denied_tools,
            Some(vec!["Bash".to_string(), "Write".to_string()])
        );
    }

    #[test]
    fn test_parse_allowed_tools() {
        let content = "---\nallowedTools:\n  - Read\n  - Grep\n---\nBody";
        let result = parse_skill_md(content);
        assert_eq!(
            result.frontmatter.allowed_tools,
            Some(vec!["Read".to_string(), "Grep".to_string()])
        );
    }

    #[test]
    fn test_description_extraction_skips_headers() {
        let content = "# Title\n## Subtitle\n\nActual description here.";
        let result = parse_skill_md(content);
        assert_eq!(result.description, "Actual description here.");
    }

    #[test]
    fn test_description_extraction_skips_horizontal_rules() {
        let content = "---\nname: Test\n---\n---\n***\nActual content.";
        let result = parse_skill_md(content);
        assert_eq!(result.description, "Actual content.");
    }

    #[test]
    fn test_description_extraction_skips_code_blocks() {
        let content = "```\ncode line\n```\nDescription after code.";
        let result = parse_skill_md(content);
        assert_eq!(result.description, "Description after code.");
    }

    #[test]
    fn test_description_truncation() {
        let long_line = "a".repeat(300);
        let content = format!("# Header\n\n{long_line}");
        let result = parse_skill_md(&content);
        assert_eq!(result.description.len(), 200);
    }

    #[test]
    fn test_description_empty_content() {
        let result = parse_skill_md("");
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
        assert!(parse_inline_array("[]").is_empty());
    }

    #[test]
    fn test_inline_array_single() {
        assert_eq!(parse_inline_array("[one]"), vec!["one"]);
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
        let result = parse_skill_md(content);
        assert_eq!(
            result.frontmatter.subagent_model.as_deref(),
            Some("claude-haiku")
        );
    }

    #[test]
    fn test_snake_case_keys() {
        let content = "---\nallowed_tools: [Read]\nsubagent_model: haiku\n---\nBody";
        let result = parse_skill_md(content);
        assert_eq!(
            result.frontmatter.allowed_tools,
            Some(vec!["Read".to_string()])
        );
        assert_eq!(
            result.frontmatter.subagent_model.as_deref(),
            Some("haiku")
        );
    }
}
