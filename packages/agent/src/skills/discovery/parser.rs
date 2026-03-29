//! SKILL.md parser.
//!
//! Parses SKILL.md files with optional YAML frontmatter delimited by `---`.
//! Uses a hand-written YAML subset parser (no external YAML dependency)
//! supporting key-value pairs, booleans, strings, and arrays.

use crate::skills::types::{
    CacheConfig, SecretBinding, SkillDisplay, SkillFrontmatter, SkillGuards, SkillSubagentMode,
    TruncationMode,
};

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
            "display" if value.is_empty() => {
                fm.display = Some(parse_display_block(&lines, &mut i));
            }
            "guards" if value.is_empty() => {
                fm.guards = Some(parse_guards_block(&lines, &mut i));
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
    let inner = value.trim_start_matches('[').trim_end_matches(']').trim();

    if inner.is_empty() {
        return Vec::new();
    }

    inner.split(',').map(|s| unquote(s.trim())).collect()
}

/// Get the indentation level (number of leading whitespace chars) of a line.
fn indent_of(line: &str) -> usize {
    line.len() - line.trim_start().len()
}

/// Parse a `display:` block's indented sub-keys into `SkillDisplay`.
fn parse_display_block(lines: &[&str], i: &mut usize) -> SkillDisplay {
    let mut display = SkillDisplay::default();
    while *i < lines.len() {
        let raw = lines[*i];
        if !raw.starts_with(' ') && !raw.starts_with('\t') {
            break;
        }
        let trimmed = raw.trim();
        if trimmed.is_empty() || trimmed.starts_with('#') {
            *i += 1;
            continue;
        }
        if let Some((key, value)) = trimmed.split_once(':') {
            let key = key.trim();
            let value = value.trim();
            match key {
                "label" => display.label = Some(unquote(value)),
                "icon" => display.icon = Some(unquote(value)),
                "color" => display.color = Some(unquote(value)),
                _ => {}
            }
        }
        *i += 1;
    }
    display
}

/// Parse a `guards:` block's indented sub-keys into `SkillGuards`.
fn parse_guards_block(lines: &[&str], i: &mut usize) -> SkillGuards {
    let mut guards = SkillGuards::default();

    while *i < lines.len() {
        let raw = lines[*i];
        // Stop at non-indented lines (back to top level).
        if !raw.starts_with(' ') && !raw.starts_with('\t') {
            break;
        }
        let trimmed = raw.trim();
        if trimmed.is_empty() || trimmed.starts_with('#') {
            *i += 1;
            continue;
        }
        // Skip array items that belong to a sub-field (e.g., secrets items).
        if trimmed.starts_with('-') {
            *i += 1;
            continue;
        }

        if let Some((key, value)) = trimmed.split_once(':') {
            let key = key.trim();
            let value = value.trim();
            *i += 1;

            match key {
                "maxOutputLines" | "max_output_lines" => {
                    guards.max_output_lines = value.parse().ok();
                }
                "maxOutputBytes" | "max_output_bytes" => {
                    guards.max_output_bytes = value.parse().ok();
                }
                "truncation" => {
                    guards.truncation = parse_truncation_mode(value);
                }
                "rateLimitMs" | "rate_limit_ms" => {
                    guards.rate_limit_ms = value.parse().ok();
                }
                "secrets" if value.is_empty() => {
                    guards.secrets = Some(parse_secrets_array(lines, i));
                }
                "cache" if value.is_empty() => {
                    guards.cache = parse_cache_block(lines, i);
                }
                _ => {}
            }
        } else {
            *i += 1;
        }
    }

    guards
}

/// Parse a `secrets:` array of `{env, setting}` objects.
fn parse_secrets_array(lines: &[&str], i: &mut usize) -> Vec<SecretBinding> {
    let mut secrets = Vec::new();
    let mut current_env: Option<String> = None;
    let mut current_setting: Option<String> = None;

    let item_indent = if *i < lines.len() {
        indent_of(lines[*i])
    } else {
        return secrets;
    };

    while *i < lines.len() {
        let raw = lines[*i];
        let trimmed = raw.trim();

        if trimmed.is_empty() {
            *i += 1;
            continue;
        }

        let current = indent_of(raw);
        if current < item_indent {
            break;
        }

        if trimmed.starts_with("- ") {
            // Flush previous secret.
            if let (Some(env), Some(setting)) = (current_env.take(), current_setting.take()) {
                secrets.push(SecretBinding { env, setting });
            }
            let after_dash = trimmed.strip_prefix("- ").unwrap().trim();
            if let Some((key, value)) = after_dash.split_once(':') {
                match key.trim() {
                    "env" => current_env = Some(unquote(value.trim())),
                    "setting" => current_setting = Some(unquote(value.trim())),
                    _ => {}
                }
            }
        } else if let Some((key, value)) = trimmed.split_once(':') {
            match key.trim() {
                "env" => current_env = Some(unquote(value.trim())),
                "setting" => current_setting = Some(unquote(value.trim())),
                _ => break,
            }
        }

        *i += 1;
    }

    // Flush last secret.
    if let (Some(env), Some(setting)) = (current_env, current_setting) {
        secrets.push(SecretBinding { env, setting });
    }

    secrets
}

/// Parse a `cache:` sub-block into `CacheConfig`.
fn parse_cache_block(lines: &[&str], i: &mut usize) -> Option<CacheConfig> {
    let mut ttl = None;
    let mut key_extractor = "auto".to_string();

    let item_indent = if *i < lines.len() {
        indent_of(lines[*i])
    } else {
        return None;
    };

    while *i < lines.len() {
        let raw = lines[*i];
        let trimmed = raw.trim();

        if trimmed.is_empty() {
            *i += 1;
            continue;
        }

        let current = indent_of(raw);
        if current < item_indent {
            break;
        }

        if let Some((key, value)) = trimmed.split_once(':') {
            match key.trim() {
                "ttl" => ttl = value.trim().parse().ok(),
                "keyExtractor" | "key_extractor" => key_extractor = unquote(value.trim()),
                _ => break,
            }
        }

        *i += 1;
    }

    ttl.map(|ttl| CacheConfig { ttl, key_extractor })
}

/// Parse a truncation mode string.
fn parse_truncation_mode(value: &str) -> Option<TruncationMode> {
    match unquote(value).as_str() {
        "head_tail" | "headTail" => Some(TruncationMode::HeadTail),
        "smart_context" | "smartContext" => Some(TruncationMode::SmartContext),
        "head_only" | "headOnly" => Some(TruncationMode::HeadOnly),
        "none" => Some(TruncationMode::None),
        _ => None,
    }
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
    fn test_description_truncation_multibyte_utf8() {
        // Each emoji is 4 bytes. 51 emojis = 204 bytes, so byte 200 is mid-char.
        let emojis = "\u{1F600}".repeat(51);
        let content = format!("# Header\n\n{emojis}");
        let result = parse_skill_md(&content);
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
        assert_eq!(result.frontmatter.subagent_model.as_deref(), Some("haiku"));
    }

    // ── Phase 1: Display metadata tests ────────────────────────────

    #[test]
    fn test_parse_display_all_fields() {
        let content = "---\nname: Test\ndisplay:\n  label: \"Code Search\"\n  icon: magnifyingglass\n  color: \"#4A90D9\"\n---\nBody";
        let result = parse_skill_md(content);
        let display = result.frontmatter.display.expect("display should be Some");
        assert_eq!(display.label.as_deref(), Some("Code Search"));
        assert_eq!(display.icon.as_deref(), Some("magnifyingglass"));
        assert_eq!(display.color.as_deref(), Some("#4A90D9"));
    }

    #[test]
    fn test_parse_display_partial_fields() {
        let content = "---\ndisplay:\n  label: Search\n---\nBody";
        let result = parse_skill_md(content);
        let display = result.frontmatter.display.expect("display should be Some");
        assert_eq!(display.label.as_deref(), Some("Search"));
        assert_eq!(display.icon, None);
        assert_eq!(display.color, None);
    }

    #[test]
    fn test_parse_display_missing_block() {
        let content = "---\nname: No Display\n---\nBody";
        let result = parse_skill_md(content);
        assert!(result.frontmatter.display.is_none());
    }

    #[test]
    fn test_parse_empty_display_block() {
        // display: with no sub-fields should produce empty SkillDisplay
        let content = "---\ndisplay:\nname: After\n---\nBody";
        let result = parse_skill_md(content);
        let display = result.frontmatter.display.expect("display should be Some");
        assert_eq!(display, SkillDisplay::default());
        // And the name field after display should still parse
        assert_eq!(result.frontmatter.name.as_deref(), Some("After"));
    }

    // ── Phase 1: Guards tests ────────────────────────────────────

    #[test]
    fn test_parse_guards_all_fields() {
        let content = "\
---
guards:
  maxOutputLines: 500
  maxOutputBytes: 100000
  truncation: head_tail
  rateLimitMs: 1000
  secrets:
    - env: BRAVE_API_KEY
      setting: web.brave_api_key
    - env: OTHER_KEY
      setting: other.path
  cache:
    ttl: 900
    keyExtractor: url
---
Body";
        let result = parse_skill_md(content);
        let guards = result.frontmatter.guards.expect("guards should be Some");
        assert_eq!(guards.max_output_lines, Some(500));
        assert_eq!(guards.max_output_bytes, Some(100_000));
        assert_eq!(guards.truncation, Some(TruncationMode::HeadTail));
        assert_eq!(guards.rate_limit_ms, Some(1000));

        let secrets = guards.secrets.expect("secrets should be Some");
        assert_eq!(secrets.len(), 2);
        assert_eq!(secrets[0].env, "BRAVE_API_KEY");
        assert_eq!(secrets[0].setting, "web.brave_api_key");
        assert_eq!(secrets[1].env, "OTHER_KEY");
        assert_eq!(secrets[1].setting, "other.path");

        let cache = guards.cache.expect("cache should be Some");
        assert_eq!(cache.ttl, 900);
        assert_eq!(cache.key_extractor, "url");
    }

    #[test]
    fn test_parse_guards_partial_fields() {
        let content = "---\nguards:\n  maxOutputLines: 200\n---\nBody";
        let result = parse_skill_md(content);
        let guards = result.frontmatter.guards.expect("guards should be Some");
        assert_eq!(guards.max_output_lines, Some(200));
        assert_eq!(guards.max_output_bytes, None);
        assert_eq!(guards.truncation, None);
        assert_eq!(guards.rate_limit_ms, None);
        assert_eq!(guards.secrets, None);
        assert_eq!(guards.cache, None);
    }

    #[test]
    fn test_parse_guards_missing_block() {
        let content = "---\nname: No Guards\n---\nBody";
        let result = parse_skill_md(content);
        assert!(result.frontmatter.guards.is_none());
    }

    #[test]
    fn test_parse_guards_empty_block() {
        let content = "---\nguards:\nname: After\n---\nBody";
        let result = parse_skill_md(content);
        let guards = result.frontmatter.guards.expect("guards should be Some");
        assert_eq!(guards, SkillGuards::default());
        assert_eq!(result.frontmatter.name.as_deref(), Some("After"));
    }

    #[test]
    fn test_parse_guards_truncation_modes() {
        for (mode_str, expected) in [
            ("head_tail", TruncationMode::HeadTail),
            ("smart_context", TruncationMode::SmartContext),
            ("head_only", TruncationMode::HeadOnly),
            ("none", TruncationMode::None),
        ] {
            let content = format!("---\nguards:\n  truncation: {mode_str}\n---\nBody");
            let result = parse_skill_md(&content);
            let guards = result.frontmatter.guards.expect("guards should be Some");
            assert_eq!(guards.truncation, Some(expected), "failed for {mode_str}");
        }
    }

    #[test]
    fn test_parse_guards_invalid_truncation() {
        let content = "---\nguards:\n  truncation: invalid_mode\n---\nBody";
        let result = parse_skill_md(content);
        let guards = result.frontmatter.guards.expect("guards should be Some");
        // Invalid truncation mode should be None (silently ignored)
        assert_eq!(guards.truncation, None);
    }

    #[test]
    fn test_parse_guards_secrets_single() {
        let content =
            "---\nguards:\n  secrets:\n    - env: MY_KEY\n      setting: my.path\n---\nBody";
        let result = parse_skill_md(content);
        let guards = result.frontmatter.guards.expect("guards should be Some");
        let secrets = guards.secrets.expect("secrets should be Some");
        assert_eq!(secrets.len(), 1);
        assert_eq!(secrets[0].env, "MY_KEY");
        assert_eq!(secrets[0].setting, "my.path");
    }

    #[test]
    fn test_parse_guards_cache_defaults() {
        let content = "---\nguards:\n  cache:\n    ttl: 300\n---\nBody";
        let result = parse_skill_md(content);
        let guards = result.frontmatter.guards.expect("guards should be Some");
        let cache = guards.cache.expect("cache should be Some");
        assert_eq!(cache.ttl, 300);
        assert_eq!(cache.key_extractor, "auto"); // default
    }

    // ── Phase 1: Combined tests ────────────────────────────────

    #[test]
    fn test_parse_combined_display_and_guards() {
        let content = "\
---
name: \"Web Search\"
display:
  label: Web Search
  icon: magnifyingglass.circle
  color: \"#50C878\"
guards:
  rateLimitMs: 1000
  secrets:
    - env: BRAVE_API_KEY
      setting: web.brave_api_key
tags: [search, web]
---
Body";
        let result = parse_skill_md(content);
        assert_eq!(result.frontmatter.name.as_deref(), Some("Web Search"));
        assert_eq!(
            result.frontmatter.tags,
            Some(vec!["search".to_string(), "web".to_string()])
        );

        let display = result.frontmatter.display.expect("display should be Some");
        assert_eq!(display.label.as_deref(), Some("Web Search"));
        assert_eq!(display.icon.as_deref(), Some("magnifyingglass.circle"));

        let guards = result.frontmatter.guards.expect("guards should be Some");
        assert_eq!(guards.rate_limit_ms, Some(1000));
        let secrets = guards.secrets.expect("secrets should be Some");
        assert_eq!(secrets[0].env, "BRAVE_API_KEY");
    }

    #[test]
    fn test_parse_existing_frontmatter_unchanged() {
        // Regression: existing skills without display/guards must parse identically
        let content = r"---
name: Tron DB
description: Query patterns for debugging
version: 2.0.0
tags: [debugging, tron]
allowedTools: [Bash]
subagent: no
subagentModel: claude-haiku
---
Body content here.";
        let result = parse_skill_md(content);
        assert_eq!(result.frontmatter.name.as_deref(), Some("Tron DB"));
        assert_eq!(
            result.frontmatter.description.as_deref(),
            Some("Query patterns for debugging")
        );
        assert_eq!(result.frontmatter.version.as_deref(), Some("2.0.0"));
        assert_eq!(
            result.frontmatter.tags,
            Some(vec!["debugging".to_string(), "tron".to_string()])
        );
        assert_eq!(
            result.frontmatter.allowed_tools,
            Some(vec!["Bash".to_string()])
        );
        assert_eq!(result.frontmatter.subagent, Some(SkillSubagentMode::No));
        assert_eq!(
            result.frontmatter.subagent_model.as_deref(),
            Some("claude-haiku")
        );
        assert!(result.frontmatter.display.is_none());
        assert!(result.frontmatter.guards.is_none());
        assert!(result.content.contains("Body content here."));
    }

    #[test]
    fn test_parse_display_and_guards_serde_roundtrip() {
        let display = SkillDisplay {
            label: Some("Test".to_string()),
            icon: Some("star".to_string()),
            color: Some("#FF0000".to_string()),
        };
        let json = serde_json::to_string(&display).unwrap();
        let deserialized: SkillDisplay = serde_json::from_str(&json).unwrap();
        assert_eq!(display, deserialized);

        let guards = SkillGuards {
            max_output_lines: Some(100),
            truncation: Some(TruncationMode::HeadTail),
            secrets: Some(vec![SecretBinding {
                env: "KEY".to_string(),
                setting: "path".to_string(),
            }]),
            cache: Some(CacheConfig {
                ttl: 60,
                key_extractor: "url".to_string(),
            }),
            ..Default::default()
        };
        let json = serde_json::to_string(&guards).unwrap();
        let deserialized: SkillGuards = serde_json::from_str(&json).unwrap();
        assert_eq!(guards, deserialized);
    }
}
