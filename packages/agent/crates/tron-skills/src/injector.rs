//! Skill reference extraction and context injection.
//!
//! Extracts `@skill-name` references from user prompts, builds XML context
//! blocks for skill injection, and processes prompts for the LLM.

use std::sync::LazyLock;

use regex::Regex;

use crate::registry::SkillRegistry;
use crate::types::{SkillInjectionResult, SkillInfo, SkillMetadata, SkillReference};

static SKILL_REF_PATTERN: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"@([a-zA-Z][a-zA-Z0-9_-]*)").unwrap());

static MULTI_SPACE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r" {2,}").unwrap());

/// Extract `@skill-name` references from a user prompt.
///
/// Respects code blocks (triple backticks) and inline code (single backticks).
/// Email addresses like `user@example.com` are not matched (word char before `@`
/// disqualifies it).
pub fn extract_skill_references(prompt: &str) -> Vec<SkillReference> {
    let pattern = &*SKILL_REF_PATTERN;
    let mut references = Vec::new();
    let mut in_code_block = false;
    let mut global_offset = 0;

    for line in prompt.split('\n') {
        let trimmed = line.trim();

        // Track code blocks
        if trimmed.starts_with("```") {
            in_code_block = !in_code_block;
            global_offset += line.len() + 1; // +1 for newline
            continue;
        }

        if !in_code_block {
            for cap in pattern.captures_iter(line) {
                let full_match = cap.get(0).unwrap();
                let name = cap.get(1).unwrap().as_str();

                // Reject if preceded by a word character (catches email: user@example)
                if full_match.start() > 0 {
                    let prev_char = line.as_bytes()[full_match.start() - 1];
                    if prev_char.is_ascii_alphanumeric() || prev_char == b'_' {
                        continue;
                    }
                    // Reject if preceded by backtick
                    if prev_char == b'`' {
                        continue;
                    }
                }

                // Check if inside inline code (count backticks before match)
                let prefix = &line[..full_match.start()];
                let backtick_count = prefix.chars().filter(|&c| c == '`').count();
                if backtick_count % 2 != 0 {
                    continue; // Inside inline code
                }

                let abs_start = global_offset + full_match.start();
                let abs_end = global_offset + full_match.end();

                references.push(SkillReference {
                    original: full_match.as_str().to_string(),
                    name: name.to_string(),
                    start: abs_start,
                    end: abs_end,
                });
            }
        }

        global_offset += line.len() + 1; // +1 for newline
    }

    references
}

/// Remove `@skill-name` references from a prompt.
///
/// Collects the kept ranges between references in a single forward pass.
/// Resulting multiple spaces are collapsed.
pub fn remove_skill_references(prompt: &str, references: &[SkillReference]) -> String {
    if references.is_empty() {
        return prompt.to_string();
    }

    // Sort by position ascending to collect kept ranges in one pass
    let mut sorted_refs: Vec<&SkillReference> = references.iter().collect();
    sorted_refs.sort_by_key(|r| r.start);

    let mut result = String::with_capacity(prompt.len());
    let mut cursor = 0;

    for reference in &sorted_refs {
        if reference.start > cursor && reference.end <= prompt.len() {
            result.push_str(&prompt[cursor..reference.start]);
        }
        cursor = reference.end;
    }
    if cursor < prompt.len() {
        result.push_str(&prompt[cursor..]);
    }

    MULTI_SPACE.replace_all(&result, " ").trim().to_string()
}

/// Build a `<skills>` XML context block from skill metadata.
///
/// Returns an empty string if no skills are provided.
pub fn build_skill_context(skills: &[&SkillMetadata]) -> String {
    use std::fmt::Write;

    if skills.is_empty() {
        return String::new();
    }

    let mut xml = String::from("<skills>\n");

    for skill in skills {
        let escaped_name = escape_xml(&skill.name);
        let _ = writeln!(xml, "<skill name=\"{escaped_name}\">");

        // Add tool preferences if present
        let prefs = build_tool_preferences(skill);
        if !prefs.is_empty() {
            xml.push_str(&prefs);
            xml.push('\n');
        }

        xml.push_str(&skill.content);
        xml.push_str("\n</skill>\n\n");
    }

    xml.push_str("</skills>");
    xml
}

/// Process a user prompt for skill references.
///
/// Extracts `@skill-name` references, looks them up in the registry,
/// removes references from the prompt, and builds a `<skills>` XML block.
pub fn process_prompt_for_skills(prompt: &str, registry: &SkillRegistry) -> SkillInjectionResult {
    let references = extract_skill_references(prompt);

    if references.is_empty() {
        return SkillInjectionResult {
            original_prompt: prompt.to_string(),
            cleaned_prompt: prompt.to_string(),
            injected_skills: Vec::new(),
            not_found_skills: Vec::new(),
            skill_context: String::new(),
        };
    }

    // Deduplicate names
    let mut seen = std::collections::HashSet::new();
    let unique_names: Vec<&str> = references
        .iter()
        .filter_map(|r| {
            if seen.insert(r.name.as_str()) {
                Some(r.name.as_str())
            } else {
                None
            }
        })
        .collect();

    let (found, not_found) = registry.get_many(&unique_names);

    let cleaned = remove_skill_references(prompt, &references);
    let context = build_skill_context(&found);

    SkillInjectionResult {
        original_prompt: prompt.to_string(),
        cleaned_prompt: cleaned,
        injected_skills: found.iter().map(|s| SkillInfo::from(*s)).collect(),
        not_found_skills: not_found,
        skill_context: context,
    }
}

/// Build a message with skill context prepended.
///
/// Returns the original prompt unchanged if no skill context is present.
pub fn build_message_with_skill_context(prompt: &str, skill_context: &str) -> String {
    if skill_context.is_empty() {
        return prompt.to_string();
    }
    format!("{skill_context}\n\n{prompt}")
}

/// Build tool preference/restriction XML blocks for a skill.
fn build_tool_preferences(skill: &SkillMetadata) -> String {
    let fm = &skill.frontmatter;

    if let Some(allowed) = &fm.allowed_tools {
        if !allowed.is_empty() {
            let tools = allowed.join(", ");
            return format!(
                "<skill-tool-preferences>This skill works best with: {tools}. Prefer these tools.</skill-tool-preferences>"
            );
        }
    }

    if let Some(denied) = &fm.denied_tools {
        if !denied.is_empty() {
            let tools = denied.join(", ");
            return format!(
                "<skill-tool-restrictions>This skill must NOT use: {tools}. These tools are restricted.</skill-tool-restrictions>"
            );
        }
    }

    String::new()
}

/// Escape XML special characters.
fn escape_xml(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        match c {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            '\'' => out.push_str("&apos;"),
            _ => out.push(c),
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::{SkillFrontmatter, SkillSource};

    fn make_skill(name: &str, content: &str) -> SkillMetadata {
        SkillMetadata {
            name: name.to_string(),
            display_name: name.to_string(),
            description: String::new(),
            content: content.to_string(),
            frontmatter: SkillFrontmatter::default(),
            source: SkillSource::Global,
            path: String::new(),
            skill_md_path: String::new(),
            additional_files: Vec::new(),
            last_modified: 0,
        }
    }

    fn make_skill_with_tools(
        name: &str,
        content: &str,
        allowed: Option<Vec<String>>,
        denied: Option<Vec<String>>,
    ) -> SkillMetadata {
        SkillMetadata {
            name: name.to_string(),
            display_name: name.to_string(),
            description: String::new(),
            content: content.to_string(),
            frontmatter: SkillFrontmatter {
                allowed_tools: allowed,
                denied_tools: denied,
                ..Default::default()
            },
            source: SkillSource::Global,
            path: String::new(),
            skill_md_path: String::new(),
            additional_files: Vec::new(),
            last_modified: 0,
        }
    }

    // --- extract_skill_references ---

    #[test]
    fn test_extract_simple_reference() {
        let refs = extract_skill_references("Use @browser tool");
        assert_eq!(refs.len(), 1);
        assert_eq!(refs[0].name, "browser");
        assert_eq!(refs[0].original, "@browser");
    }

    #[test]
    fn test_extract_multiple_references() {
        let refs = extract_skill_references("Use @browser and @git tools");
        assert_eq!(refs.len(), 2);
        assert_eq!(refs[0].name, "browser");
        assert_eq!(refs[1].name, "git");
    }

    #[test]
    fn test_extract_no_references() {
        let refs = extract_skill_references("No references here");
        assert!(refs.is_empty());
    }

    #[test]
    fn test_extract_email_not_matched() {
        let refs = extract_skill_references("Send to user@example.com");
        assert!(refs.is_empty());
    }

    #[test]
    fn test_extract_inside_code_block_skipped() {
        let prompt = "Before\n```\n@browser\n```\nAfter";
        let refs = extract_skill_references(prompt);
        assert!(refs.is_empty());
    }

    #[test]
    fn test_extract_inside_inline_code_skipped() {
        let refs = extract_skill_references("Use `@browser` in code");
        assert!(refs.is_empty());
    }

    #[test]
    fn test_extract_reference_at_start() {
        let refs = extract_skill_references("@browser is great");
        assert_eq!(refs.len(), 1);
        assert_eq!(refs[0].name, "browser");
    }

    #[test]
    fn test_extract_reference_at_end() {
        let refs = extract_skill_references("Use @browser");
        assert_eq!(refs.len(), 1);
    }

    #[test]
    fn test_extract_hyphenated_name() {
        let refs = extract_skill_references("Use @my-skill here");
        assert_eq!(refs.len(), 1);
        assert_eq!(refs[0].name, "my-skill");
    }

    #[test]
    fn test_extract_underscored_name() {
        let refs = extract_skill_references("Use @my_skill here");
        assert_eq!(refs.len(), 1);
        assert_eq!(refs[0].name, "my_skill");
    }

    // --- remove_skill_references ---

    #[test]
    fn test_remove_references() {
        let refs = extract_skill_references("Use @browser for browsing");
        let cleaned = remove_skill_references("Use @browser for browsing", &refs);
        assert_eq!(cleaned, "Use for browsing");
    }

    #[test]
    fn test_remove_multiple_references() {
        let refs = extract_skill_references("Use @browser and @git");
        let cleaned = remove_skill_references("Use @browser and @git", &refs);
        assert_eq!(cleaned, "Use and");
    }

    #[test]
    fn test_remove_no_references() {
        let cleaned = remove_skill_references("No changes", &[]);
        assert_eq!(cleaned, "No changes");
    }

    #[test]
    fn test_remove_adjacent_references() {
        let prompt = "Run @browser @git now";
        let refs = extract_skill_references(prompt);
        assert_eq!(refs.len(), 2);
        let cleaned = remove_skill_references(prompt, &refs);
        assert_eq!(cleaned, "Run now");
    }

    // --- build_skill_context ---

    #[test]
    fn test_build_empty_context() {
        assert!(build_skill_context(&[]).is_empty());
    }

    #[test]
    fn test_build_single_skill_context() {
        let skill = make_skill("browser", "Browse the web.");
        let context = build_skill_context(&[&skill]);
        assert!(context.contains("<skills>"));
        assert!(context.contains("</skills>"));
        assert!(context.contains("<skill name=\"browser\">"));
        assert!(context.contains("Browse the web."));
    }

    #[test]
    fn test_build_multiple_skill_context() {
        let s1 = make_skill("browser", "Browse.");
        let s2 = make_skill("git", "Git ops.");
        let context = build_skill_context(&[&s1, &s2]);
        assert!(context.contains("<skill name=\"browser\">"));
        assert!(context.contains("<skill name=\"git\">"));
    }

    #[test]
    fn test_build_context_with_allowed_tools() {
        let skill = make_skill_with_tools(
            "reader",
            "Read things.",
            Some(vec!["Read".to_string(), "Grep".to_string()]),
            None,
        );
        let context = build_skill_context(&[&skill]);
        assert!(context.contains("<skill-tool-preferences>"));
        assert!(context.contains("Read, Grep"));
    }

    #[test]
    fn test_build_context_with_denied_tools() {
        let skill =
            make_skill_with_tools("safe", "Safe skill.", None, Some(vec!["Bash".to_string()]));
        let context = build_skill_context(&[&skill]);
        assert!(context.contains("<skill-tool-restrictions>"));
        assert!(context.contains("Bash"));
    }

    #[test]
    fn test_build_context_escapes_xml() {
        let skill = make_skill("test&<>", "Content");
        let context = build_skill_context(&[&skill]);
        assert!(context.contains("test&amp;&lt;&gt;"));
    }

    // --- build_message_with_skill_context ---

    #[test]
    fn test_build_message_no_context() {
        let result = build_message_with_skill_context("Hello", "");
        assert_eq!(result, "Hello");
    }

    #[test]
    fn test_build_message_with_context() {
        let result = build_message_with_skill_context("Hello", "<skills>data</skills>");
        assert!(result.starts_with("<skills>"));
        assert!(result.ends_with("Hello"));
    }

    // --- escape_xml ---

    #[test]
    fn test_escape_xml() {
        assert_eq!(escape_xml("a&b"), "a&amp;b");
        assert_eq!(escape_xml("<tag>"), "&lt;tag&gt;");
        assert_eq!(escape_xml("\"quoted\""), "&quot;quoted&quot;");
        assert_eq!(escape_xml("it's"), "it&apos;s");
    }
}
