//! Core types for the skills system.
//!
//! All types use `camelCase` serde renaming for wire compatibility with the
//! TypeScript server and iOS client.

use serde::{Deserialize, Serialize};

/// Where a skill was loaded from.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum SkillSource {
    /// Loaded from any global skills directory under `$HOME`
    /// (e.g. `~/.tron/skills/`, `~/.claude/skills/`).
    Global,
    /// Loaded from a project-local `.tron/skills/` or `.claude/skills/` at any depth.
    Project,
}

impl std::fmt::Display for SkillSource {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Global => write!(f, "global"),
            Self::Project => write!(f, "project"),
        }
    }
}

/// How a skill executes in subagent context.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum SkillSubagentMode {
    /// Do not use subagent (default).
    #[default]
    No,
    /// Ask user before spawning subagent.
    Ask,
    /// Always use subagent.
    Yes,
}

/// How a skill was added to a session.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum SkillAddMethod {
    /// Added via `@skill-name` mention in user prompt.
    Mention,
    /// Added explicitly (e.g., via engine invocation).
    Explicit,
}

/// Why a skill was removed from a session.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum SkillRemoveReason {
    /// Removed manually by user.
    Manual,
    /// Removed by context clear.
    Clear,
    /// Removed by compaction.
    Compact,
}

/// YAML frontmatter parsed from a SKILL.md file.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SkillFrontmatter {
    /// Human-readable name.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    /// Short description.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    /// Semantic version.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub version: Option<String>,
    /// Categorization tags.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tags: Option<Vec<String>>,
    /// Allow-list of tools (mutually exclusive with `denied_tools`).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub allowed_tools: Option<Vec<String>>,
    /// Deny-list of tools (mutually exclusive with `allowed_tools`).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub denied_tools: Option<Vec<String>>,
    /// Subagent execution mode.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub subagent: Option<SkillSubagentMode>,
    /// Model override for subagent execution.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub subagent_model: Option<String>,
}

/// Full metadata for a loaded skill.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SkillMetadata {
    /// Folder name (used as `@reference`).
    pub name: String,
    /// Human-readable display name (from frontmatter or folder name).
    pub display_name: String,
    /// Short description.
    pub description: String,
    /// Full SKILL.md content after frontmatter stripped.
    pub content: String,
    /// Parsed frontmatter.
    pub frontmatter: SkillFrontmatter,
    /// Where this skill was loaded from.
    pub source: SkillSource,
    /// Which service folder hosted this skill — one of
    /// [`crate::skills::constants::SKILL_SERVICE_DIRS`] (`"tron"`, `"claude"`, …).
    /// Used by the iOS UI to badge e.g. Claude-Code skills distinctly from Tron-native ones.
    pub service: String,
    /// Relative path from project root to the package containing this skill.
    /// Empty string for root-level skills. E.g. "packages/ios-app".
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub scope_dir: String,
    /// Absolute path to skill folder.
    pub path: String,
    /// Absolute path to SKILL.md file.
    pub skill_md_path: String,
    /// Additional files in the skill folder.
    pub additional_files: Vec<String>,
    /// Last modification time (milliseconds since epoch).
    pub last_modified: u64,
}

/// Lightweight skill info (excludes full content).
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SkillInfo {
    /// Folder name.
    pub name: String,
    /// Human-readable display name.
    pub display_name: String,
    /// Short description.
    pub description: String,
    /// Source location.
    pub source: SkillSource,
    /// Which service folder hosted this skill — one of
    /// [`crate::skills::constants::SKILL_SERVICE_DIRS`] (`"tron"`, `"claude"`, …).
    pub service: String,
    /// Relative path from project root to the package containing this skill.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub scope_dir: String,
    /// Tags from frontmatter.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tags: Option<Vec<String>>,
}

impl From<&SkillMetadata> for SkillInfo {
    fn from(meta: &SkillMetadata) -> Self {
        Self {
            name: meta.name.clone(),
            display_name: meta.display_name.clone(),
            description: meta.description.clone(),
            source: meta.source,
            service: meta.service.clone(),
            scope_dir: meta.scope_dir.clone(),
            tags: meta.frontmatter.tags.clone(),
        }
    }
}

/// A `@skill-name` reference found in user input.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SkillReference {
    /// Original text as typed (e.g., `@browser`).
    pub original: String,
    /// Extracted skill name (e.g., `browser`).
    pub name: String,
    /// Start position in original string.
    pub start: usize,
    /// End position in original string (exclusive).
    pub end: usize,
}

/// Result of processing a prompt for skill injection.
#[derive(Debug, Clone)]
pub struct SkillInjectionResult {
    /// Original user prompt.
    pub original_prompt: String,
    /// Prompt with `@references` removed.
    pub cleaned_prompt: String,
    /// Successfully injected skills (lightweight — no full content).
    pub injected_skills: Vec<SkillInfo>,
    /// Skills referenced but not found.
    pub not_found_skills: Vec<String>,
    /// Generated `<skills>` XML context block.
    pub skill_context: String,
}

/// Result of scanning a skills directory.
#[derive(Debug, Clone, Default)]
pub struct SkillScanResult {
    /// Skills found.
    pub skills: Vec<SkillMetadata>,
    /// Errors encountered during scanning.
    pub errors: Vec<SkillScanError>,
}

/// Error encountered while scanning/loading a skill.
#[derive(Debug, Clone)]
pub struct SkillScanError {
    /// Path to the problematic skill folder.
    pub path: String,
    /// Error message.
    pub message: String,
    /// Whether loading can continue past this error.
    pub recoverable: bool,
}

/// Information about a skill added to a session.
#[derive(Debug, Clone)]
pub struct AddedSkillInfo {
    /// Skill name.
    pub name: String,
    /// Source location.
    pub source: SkillSource,
    /// How it was added.
    pub added_via: SkillAddMethod,
    /// Event ID (for removal tracking).
    pub event_id: Option<String>,
    /// Estimated token count (from content length).
    pub tokens: Option<u64>,
}

/// Tool denial configuration derived from skill frontmatter.
#[derive(Debug, Clone)]
pub struct ToolDenialConfig {
    /// Tools that are denied.
    pub denied_tools: Vec<String>,
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_metadata(scope: &str) -> SkillMetadata {
        SkillMetadata {
            name: "test".to_string(),
            display_name: "Test".to_string(),
            description: "A test skill".to_string(),
            content: "content".to_string(),
            frontmatter: SkillFrontmatter::default(),
            source: SkillSource::Project,
            service: "tron".to_string(),
            scope_dir: scope.to_string(),
            path: "/tmp/test".to_string(),
            skill_md_path: "/tmp/test/SKILL.md".to_string(),
            additional_files: Vec::new(),
            last_modified: 0,
        }
    }

    #[test]
    fn scope_dir_default_empty() {
        let json = r#"{"name":"x","displayName":"x","description":"","content":"","frontmatter":{},"source":"global","service":"tron","path":"","skillMdPath":"","additionalFiles":[],"lastModified":0}"#;
        let meta: SkillMetadata = serde_json::from_str(json).unwrap();
        assert_eq!(meta.scope_dir, "");
    }

    #[test]
    fn service_field_roundtrips() {
        let meta = make_metadata("");
        let json = serde_json::to_string(&meta).unwrap();
        assert!(json.contains(r#""service":"tron""#));
        let round: SkillMetadata = serde_json::from_str(&json).unwrap();
        assert_eq!(round.service, "tron");
    }

    #[test]
    fn skill_info_from_metadata_carries_service() {
        let mut meta = make_metadata("");
        meta.service = "claude".to_string();
        let info = SkillInfo::from(&meta);
        assert_eq!(info.service, "claude");
        let json = serde_json::to_string(&info).unwrap();
        assert!(json.contains(r#""service":"claude""#));
    }

    #[test]
    fn scope_dir_serializes_when_set() {
        let meta = make_metadata("packages/foo");
        let json = serde_json::to_string(&meta).unwrap();
        assert!(json.contains(r#""scopeDir":"packages/foo""#));
    }

    #[test]
    fn scope_dir_skipped_when_empty() {
        let meta = make_metadata("");
        let json = serde_json::to_string(&meta).unwrap();
        assert!(!json.contains("scopeDir"));
    }

    #[test]
    fn skill_info_from_metadata_copies_scope() {
        let meta = make_metadata("packages/ios-app");
        let info = SkillInfo::from(&meta);
        assert_eq!(info.scope_dir, "packages/ios-app");
    }

    #[test]
    fn skill_info_scope_dir_skipped_when_empty() {
        let meta = make_metadata("");
        let info = SkillInfo::from(&meta);
        let json = serde_json::to_string(&info).unwrap();
        assert!(!json.contains("scopeDir"));
    }
}
