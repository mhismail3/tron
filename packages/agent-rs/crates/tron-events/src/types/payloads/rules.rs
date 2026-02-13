//! Rules event payloads.

use serde::{Deserialize, Serialize};

/// Payload for `rules.loaded` events.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RulesLoadedPayload {
    /// Rules files loaded.
    pub files: Vec<RulesFileInfo>,
    /// Total files loaded.
    pub total_files: i64,
    /// Total merged token count.
    pub merged_tokens: i64,
    /// Number of dynamic rules.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub dynamic_rules_count: Option<i64>,
}

/// Info about a loaded rules file.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RulesFileInfo {
    /// Absolute path.
    pub path: String,
    /// Relative path.
    pub relative_path: String,
    /// Rules level: global, project, directory.
    pub level: String,
    /// Directory depth.
    pub depth: i64,
    /// File size in bytes.
    pub size_bytes: i64,
}

/// Payload for `rules.indexed` events.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RulesIndexedPayload {
    /// Total number of rules.
    pub total_rules: i64,
    /// Number of global rules.
    pub global_rules: i64,
    /// Number of scoped rules.
    pub scoped_rules: i64,
    /// Files indexed.
    pub files: Vec<RulesIndexedFile>,
}

/// Info about an indexed rules file.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RulesIndexedFile {
    /// Relative path.
    pub relative_path: String,
    /// Whether it's a global rules file.
    pub is_global: bool,
    /// Scope directory.
    pub scope_dir: String,
    /// File size in bytes.
    pub size_bytes: i64,
}
