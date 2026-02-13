//! Tool-specific settings.
//!
//! Configuration for each tool category: Bash, Read, Find, Search, and Web.

use serde::{Deserialize, Serialize};

/// Container for all tool settings.
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ToolSettings {
    /// Bash/shell execution settings.
    pub bash: BashToolSettings,
    /// File reading settings.
    pub read: ReadToolSettings,
    /// File finding/glob settings.
    pub find: FindToolSettings,
    /// Content search settings.
    pub search: SearchToolSettings,
    /// Web fetch and cache settings.
    pub web: WebToolSettings,
}

/// Bash tool settings.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct BashToolSettings {
    /// Default command timeout in milliseconds.
    pub default_timeout_ms: u64,
    /// Maximum allowed timeout in milliseconds.
    pub max_timeout_ms: u64,
    /// Maximum output length in characters.
    pub max_output_length: usize,
    /// Regex patterns for detecting dangerous commands.
    pub dangerous_patterns: Vec<String>,
}

impl Default for BashToolSettings {
    fn default() -> Self {
        Self {
            default_timeout_ms: 120_000,
            max_timeout_ms: 600_000,
            max_output_length: 40_000,
            dangerous_patterns: vec![
                r"^rm\s+(-rf?|--force)\s+/\s*$".to_string(),
                r"rm\s+-rf?\s+/".to_string(),
                r"^sudo\s+".to_string(),
                r"^chmod\s+777\s+/\s*$".to_string(),
                r"^mkfs\.".to_string(),
                r"^dd\s+if=.*of=/dev/".to_string(),
                r">\s*/dev/sd[a-z]".to_string(),
            ],
        }
    }
}

/// Read tool settings.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ReadToolSettings {
    /// Default maximum lines to read per file.
    pub default_limit_lines: usize,
    /// Maximum characters per line before truncation.
    pub max_line_length: usize,
    /// Maximum output in tokens.
    pub max_output_tokens: usize,
}

impl Default for ReadToolSettings {
    fn default() -> Self {
        Self {
            default_limit_lines: 2000,
            max_line_length: 2000,
            max_output_tokens: 20_000,
        }
    }
}

/// Find tool settings.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct FindToolSettings {
    /// Default maximum number of results.
    pub default_max_results: usize,
    /// Default maximum directory depth.
    pub default_max_depth: usize,
}

impl Default for FindToolSettings {
    fn default() -> Self {
        Self {
            default_max_results: 100,
            default_max_depth: 10,
        }
    }
}

/// Search/grep tool settings.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct SearchToolSettings {
    /// Default maximum number of results.
    pub default_max_results: usize,
    /// Maximum file size to search in bytes.
    pub max_file_size_bytes: u64,
    /// File extensions treated as binary (skipped during search).
    pub binary_extensions: Vec<String>,
    /// Directory names to skip during recursive search.
    pub skip_directories: Vec<String>,
    /// Maximum output in tokens.
    pub max_output_tokens: usize,
    /// Default AST search result limit.
    pub ast_default_limit: usize,
    /// Maximum AST search result limit.
    pub ast_max_limit: usize,
    /// Default number of context lines around matches.
    pub default_context: usize,
    /// Path to the AST grep binary.
    pub ast_binary_path: String,
    /// Whether to require confirmation for search-and-replace.
    pub require_confirmation_for_replace: bool,
    /// Timeout for search operations in milliseconds.
    pub default_timeout_ms: u64,
}

impl Default for SearchToolSettings {
    fn default() -> Self {
        Self {
            default_max_results: 100,
            max_file_size_bytes: 10_485_760,
            binary_extensions: vec![
                "png", "jpg", "jpeg", "gif", "bmp", "ico", "webp", "svg", "mp3", "mp4", "wav",
                "avi", "mov", "mkv", "flac", "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx",
                "zip", "tar", "gz", "bz2", "7z", "rar", "exe", "dll", "so", "dylib", "o", "a",
                "woff", "woff2", "ttf", "eot", "otf", "db", "sqlite", "bin",
            ]
            .into_iter()
            .map(String::from)
            .collect(),
            skip_directories: vec![
                "node_modules",
                "__pycache__",
                "dist",
                "build",
                ".git",
                ".svn",
                ".hg",
                "vendor",
                "target",
            ]
            .into_iter()
            .map(String::from)
            .collect(),
            max_output_tokens: 15_000,
            ast_default_limit: 50,
            ast_max_limit: 200,
            default_context: 0,
            ast_binary_path: "sg".to_string(),
            require_confirmation_for_replace: false,
            default_timeout_ms: 60_000,
        }
    }
}

/// Web fetch and cache settings container.
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct WebToolSettings {
    /// HTTP fetch settings.
    pub fetch: WebFetchSettings,
    /// Response cache settings.
    pub cache: WebCacheSettings,
}

/// Web fetch settings.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct WebFetchSettings {
    /// HTTP request timeout in milliseconds.
    pub timeout_ms: u64,
}

impl Default for WebFetchSettings {
    fn default() -> Self {
        Self { timeout_ms: 30_000 }
    }
}

/// Web response cache settings.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct WebCacheSettings {
    /// Cache entry time-to-live in milliseconds.
    pub ttl_ms: u64,
    /// Maximum number of cached entries.
    pub max_entries: usize,
}

impl Default for WebCacheSettings {
    fn default() -> Self {
        Self {
            ttl_ms: 900_000,
            max_entries: 100,
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bash_defaults() {
        let b = BashToolSettings::default();
        assert_eq!(b.default_timeout_ms, 120_000);
        assert_eq!(b.max_timeout_ms, 600_000);
        assert_eq!(b.max_output_length, 40_000);
        assert!(!b.dangerous_patterns.is_empty());
    }

    #[test]
    fn bash_serde_roundtrip() {
        let b = BashToolSettings::default();
        let json = serde_json::to_value(&b).unwrap();
        assert_eq!(json["defaultTimeoutMs"], 120_000);
        assert_eq!(json["maxTimeoutMs"], 600_000);
        let back: BashToolSettings = serde_json::from_value(json).unwrap();
        assert_eq!(back.default_timeout_ms, b.default_timeout_ms);
        assert_eq!(back.dangerous_patterns.len(), b.dangerous_patterns.len());
    }

    #[test]
    fn read_defaults() {
        let r = ReadToolSettings::default();
        assert_eq!(r.default_limit_lines, 2000);
        assert_eq!(r.max_line_length, 2000);
        assert_eq!(r.max_output_tokens, 20_000);
    }

    #[test]
    fn search_defaults() {
        let s = SearchToolSettings::default();
        assert_eq!(s.default_max_results, 100);
        assert_eq!(s.max_file_size_bytes, 10_485_760);
        assert!(!s.binary_extensions.is_empty());
        assert!(!s.skip_directories.is_empty());
        assert!(s.skip_directories.contains(&"node_modules".to_string()));
    }

    #[test]
    fn web_defaults() {
        let w = WebToolSettings::default();
        assert_eq!(w.fetch.timeout_ms, 30_000);
        assert_eq!(w.cache.ttl_ms, 900_000);
        assert_eq!(w.cache.max_entries, 100);
    }

    #[test]
    fn tool_settings_partial_json() {
        let json = serde_json::json!({
            "bash": {
                "defaultTimeoutMs": 60000
            }
        });
        let tools: ToolSettings = serde_json::from_value(json).unwrap();
        assert_eq!(tools.bash.default_timeout_ms, 60_000);
        // Other bash fields should be defaults
        assert_eq!(tools.bash.max_timeout_ms, 600_000);
        // Other tool sections should be defaults
        assert_eq!(tools.read.default_limit_lines, 2000);
    }
}
