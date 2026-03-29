//! Core types for the skills system.
//!
//! All types use `camelCase` serde renaming for wire compatibility with the
//! TypeScript server and iOS client.

use serde::{Deserialize, Serialize};

/// Where a skill was loaded from.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum SkillSource {
    /// Loaded from `~/.tron/skills/`.
    Global,
    /// Loaded from project-local `.claude/skills/` or `.tron/skills/`.
    Project,
    /// Loaded from `~/.tron/skills/_builtin/` (code-defined, resettable).
    Builtin,
}

impl std::fmt::Display for SkillSource {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Global => write!(f, "global"),
            Self::Project => write!(f, "project"),
            Self::Builtin => write!(f, "builtin"),
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
    /// Added explicitly (e.g., via RPC call).
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

/// Granular tool denial pattern for a specific tool.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SkillDeniedPatternRule {
    /// Tool name this rule applies to.
    pub tool: String,
    /// Parameter patterns to deny.
    pub deny_patterns: Vec<DenyPattern>,
    /// Optional custom denial message.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub message: Option<String>,
}

/// A single parameter pattern to deny.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DenyPattern {
    /// Parameter name to check.
    pub parameter: String,
    /// Regex patterns that trigger denial.
    pub patterns: Vec<String>,
}

/// Display metadata for a skill, flowing to iOS app via event details.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SkillDisplay {
    /// Label text shown on chip/header in the iOS app.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub label: Option<String>,
    /// SF Symbol name for icon.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub icon: Option<String>,
    /// Hex color for accent (e.g., "#4A90D9").
    #[serde(skip_serializing_if = "Option::is_none")]
    pub color: Option<String>,
}

/// Truncation mode for output limiting.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TruncationMode {
    /// Keep head and tail, truncate middle.
    HeadTail,
    /// Smart context-preserving truncation (for search results).
    SmartContext,
    /// Keep only the head.
    HeadOnly,
    /// No truncation applied by guard (existing Bash limits still apply).
    None,
}

/// Secret binding: inject a setting value as an environment variable.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SecretBinding {
    /// Environment variable name (model uses `$ENV` in commands).
    pub env: String,
    /// Settings.json path to read the secret from.
    pub setting: String,
}

/// Cache configuration for skill-guided Bash calls.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CacheConfig {
    /// Time-to-live in seconds.
    pub ttl: u64,
    /// How to extract cache key: "url", "command", or "auto".
    #[serde(default = "default_key_extractor")]
    pub key_extractor: String,
}

fn default_key_extractor() -> String {
    "auto".to_string()
}

/// Harness-level guards applied by Bash when skill context is active.
///
/// Each guard is independent and composable. A skill can define any combination.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SkillGuards {
    /// Maximum output lines (overrides Bash default inline limit).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub max_output_lines: Option<usize>,
    /// Maximum output bytes (alternative to lines).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub max_output_bytes: Option<usize>,
    /// Truncation mode when output exceeds limits.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub truncation: Option<TruncationMode>,
    /// Minimum milliseconds between calls with this skill context.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub rate_limit_ms: Option<u64>,
    /// Secrets to inject as environment variables before execution.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub secrets: Option<Vec<SecretBinding>>,
    /// Cache configuration for response caching.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cache: Option<CacheConfig>,
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
    /// Granular pattern-based deny rules.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub denied_patterns: Option<Vec<SkillDeniedPatternRule>>,
    /// Subagent execution mode.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub subagent: Option<SkillSubagentMode>,
    /// Model override for subagent execution.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub subagent_model: Option<String>,
    /// Display metadata (flows to iOS app via event details).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub display: Option<SkillDisplay>,
    /// Harness-level guards for Bash skill context.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub guards: Option<SkillGuards>,
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
    /// Granular pattern-based deny rules.
    pub denied_patterns: Vec<SkillDeniedPatternRule>,
}
