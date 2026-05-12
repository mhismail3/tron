//! Capability-specific settings.
//!
//! Configuration for process, filesystem, search, web, browser, and computer-use capabilities.

use serde::{Deserialize, Serialize};

/// Container for all capability settings.
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct CapabilitySettings {
    /// Process execution settings.
    pub process: ProcessCapabilitySettings,
    /// File reading settings.
    pub filesystem_read: FilesystemReadCapabilitySettings,
    /// File finding/glob settings.
    pub find: FindCapabilitySettings,
    /// Content search settings.
    pub search: SearchCapabilitySettings,
    /// Web request and cache settings.
    pub web: WebCapabilitySettings,
    /// Browser automation settings.
    pub browser: BrowserSettings,
    /// Computer use (screenshot, click, type) settings.
    pub computer_use: ComputerUseSettings,
}

/// Computer-use capability settings.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ComputerUseSettings {
    /// Whether mutating actions (click, type, keypress, scroll) require confirmation.
    pub confirm_before_action: bool,
    /// Minimum interval between screenshots in milliseconds.
    pub screenshot_throttle_ms: u64,
}

impl Default for ComputerUseSettings {
    fn default() -> Self {
        Self {
            confirm_before_action: true,
            screenshot_throttle_ms: 500,
        }
    }
}

/// Process capability settings.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ProcessCapabilitySettings {
    /// Default command timeout in milliseconds.
    pub default_timeout_ms: u64,
    /// Maximum allowed timeout in milliseconds.
    pub max_timeout_ms: u64,
    /// Maximum output length in characters.
    pub max_output_length: usize,
    /// Regex patterns for detecting dangerous commands.
    pub dangerous_patterns: Vec<String>,
    /// Sandbox settings.
    pub sandbox: ProcessSandboxSettings,
}

/// Sandbox settings for the Process capability.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ProcessSandboxSettings {
    /// Default Docker image for `sandbox: "docker"` mode.
    pub default_image: String,
    /// Whether to enable network access in Docker sandbox by default.
    pub network_enabled: bool,
}

impl Default for ProcessSandboxSettings {
    fn default() -> Self {
        Self {
            default_image: "ubuntu:latest".to_string(),
            network_enabled: true,
        }
    }
}

impl Default for ProcessCapabilitySettings {
    fn default() -> Self {
        Self {
            default_timeout_ms: 120_000,
            max_timeout_ms: 600_000,
            max_output_length: 40_000,
            sandbox: ProcessSandboxSettings::default(),
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

/// Filesystem read capability settings.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct FilesystemReadCapabilitySettings {
    /// Default maximum lines to read per file.
    pub default_limit_lines: usize,
    /// Maximum characters per line before truncation.
    pub max_line_length: usize,
    /// Maximum output in tokens.
    pub max_output_tokens: usize,
}

impl Default for FilesystemReadCapabilitySettings {
    fn default() -> Self {
        Self {
            default_limit_lines: 2000,
            max_line_length: 2000,
            max_output_tokens: 20_000,
        }
    }
}

/// Find capability settings.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct FindCapabilitySettings {
    /// Default maximum number of results.
    pub default_max_results: usize,
    /// Default maximum directory depth.
    pub default_max_depth: usize,
}

impl Default for FindCapabilitySettings {
    fn default() -> Self {
        Self {
            default_max_results: 100,
            default_max_depth: 10,
        }
    }
}

/// Search/grep capability settings.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct SearchCapabilitySettings {
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

impl Default for SearchCapabilitySettings {
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

/// Web request and cache settings container.
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct WebCapabilitySettings {
    /// HTTP fetch settings.
    pub fetch: WebRequestSettings,
    /// Response cache settings.
    pub cache: WebCacheSettings,
}

/// Web request settings.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct WebRequestSettings {
    /// HTTP request timeout in milliseconds.
    pub timeout_ms: u64,
}

impl Default for WebRequestSettings {
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

/// Browser automation settings.
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct BrowserSettings {
    /// Browser provider name. Auto-detects agent-browser if not set.
    pub provider: Option<String>,
    /// Path to browser provider executable. Auto-detected from PATH if not set.
    pub executable_path: Option<String>,
    /// Run browser in headed mode (visible window). Default: false (headless).
    pub headed: bool,
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn process_defaults() {
        let b = ProcessCapabilitySettings::default();
        assert_eq!(b.default_timeout_ms, 120_000);
        assert_eq!(b.max_timeout_ms, 600_000);
        assert_eq!(b.max_output_length, 40_000);
        assert!(!b.dangerous_patterns.is_empty());
    }

    #[test]
    fn process_serde_roundtrip() {
        let b = ProcessCapabilitySettings::default();
        let json = serde_json::to_value(&b).unwrap();
        assert_eq!(json["defaultTimeoutMs"], 120_000);
        assert_eq!(json["maxTimeoutMs"], 600_000);
        let back: ProcessCapabilitySettings = serde_json::from_value(json).unwrap();
        assert_eq!(back.default_timeout_ms, b.default_timeout_ms);
        assert_eq!(back.dangerous_patterns.len(), b.dangerous_patterns.len());
    }

    #[test]
    fn filesystem_read_defaults() {
        let r = FilesystemReadCapabilitySettings::default();
        assert_eq!(r.default_limit_lines, 2000);
        assert_eq!(r.max_line_length, 2000);
        assert_eq!(r.max_output_tokens, 20_000);
    }

    #[test]
    fn search_defaults() {
        let s = SearchCapabilitySettings::default();
        assert_eq!(s.default_max_results, 100);
        assert_eq!(s.max_file_size_bytes, 10_485_760);
        assert!(!s.binary_extensions.is_empty());
        assert!(!s.skip_directories.is_empty());
        assert!(s.skip_directories.contains(&"node_modules".to_string()));
    }

    #[test]
    fn web_defaults() {
        let w = WebCapabilitySettings::default();
        assert_eq!(w.fetch.timeout_ms, 30_000);
        assert_eq!(w.cache.ttl_ms, 900_000);
        assert_eq!(w.cache.max_entries, 100);
    }

    #[test]
    fn capability_settings_partial_json() {
        let json = serde_json::json!({
            "process": {
                "defaultTimeoutMs": 60000
            }
        });
        let tools: CapabilitySettings = serde_json::from_value(json).unwrap();
        assert_eq!(tools.process.default_timeout_ms, 60_000);
        // Other process fields should be defaults.
        assert_eq!(tools.process.max_timeout_ms, 600_000);
        // Other capability sections should be defaults.
        assert_eq!(tools.filesystem_read.default_limit_lines, 2000);
    }

    #[test]
    fn browser_settings_defaults() {
        let b = BrowserSettings::default();
        assert!(b.provider.is_none());
        assert!(b.executable_path.is_none());
        assert!(!b.headed);
    }

    #[test]
    fn browser_settings_serde_roundtrip() {
        let b = BrowserSettings {
            provider: Some("agent-browser".into()),
            executable_path: Some("/usr/local/bin/agent-browser".into()),
            headed: true,
        };
        let json = serde_json::to_value(&b).unwrap();
        assert_eq!(json["provider"], "agent-browser");
        assert_eq!(json["executablePath"], "/usr/local/bin/agent-browser");
        assert_eq!(json["headed"], true);
        let back: BrowserSettings = serde_json::from_value(json).unwrap();
        assert_eq!(back.provider.as_deref(), Some("agent-browser"));
        assert_eq!(
            back.executable_path.as_deref(),
            Some("/usr/local/bin/agent-browser")
        );
        assert!(back.headed);
    }

    #[test]
    fn browser_settings_partial_json() {
        let json = serde_json::json!({"headed": true});
        let b: BrowserSettings = serde_json::from_value(json).unwrap();
        assert!(b.headed);
        assert!(b.provider.is_none());
        assert!(b.executable_path.is_none());
    }

    #[test]
    fn browser_settings_provider_serde_roundtrip() {
        let json = serde_json::json!({"provider": "agent-browser"});
        let b: BrowserSettings = serde_json::from_value(json).unwrap();
        assert_eq!(b.provider.as_deref(), Some("agent-browser"));
    }

    #[test]
    fn browser_settings_without_provider_defaults_to_none() {
        let json = serde_json::json!({});
        let b: BrowserSettings = serde_json::from_value(json).unwrap();
        assert!(b.provider.is_none());
    }

    #[test]
    fn capability_settings_with_browser_partial_json() {
        let json = serde_json::json!({
            "browser": {
                "headed": true
            }
        });
        let tools: CapabilitySettings = serde_json::from_value(json).unwrap();
        assert!(tools.browser.headed);
        // Other capability sections should still be defaults.
        assert_eq!(tools.process.default_timeout_ms, 120_000);
    }

    #[test]
    fn computer_use_defaults() {
        let cu = ComputerUseSettings::default();
        assert!(cu.confirm_before_action);
        assert_eq!(cu.screenshot_throttle_ms, 500);
    }

    #[test]
    fn computer_use_serde_roundtrip() {
        let cu = ComputerUseSettings {
            confirm_before_action: false,
            screenshot_throttle_ms: 1000,
        };
        let json = serde_json::to_value(&cu).unwrap();
        assert_eq!(json["confirmBeforeAction"], false);
        assert_eq!(json["screenshotThrottleMs"], 1000);
        let back: ComputerUseSettings = serde_json::from_value(json).unwrap();
        assert!(!back.confirm_before_action);
        assert_eq!(back.screenshot_throttle_ms, 1000);
    }

    #[test]
    fn computer_use_partial_json() {
        let json = serde_json::json!({"confirmBeforeAction": false});
        let cu: ComputerUseSettings = serde_json::from_value(json).unwrap();
        assert!(!cu.confirm_before_action);
        // Default for screenshot_throttle_ms
        assert_eq!(cu.screenshot_throttle_ms, 500);
    }

    #[test]
    fn capability_settings_with_computer_use_partial_json() {
        let json = serde_json::json!({
            "computerUse": {
                "confirmBeforeAction": false,
                "screenshotThrottleMs": 250
            }
        });
        let tools: CapabilitySettings = serde_json::from_value(json).unwrap();
        assert!(!tools.computer_use.confirm_before_action);
        assert_eq!(tools.computer_use.screenshot_throttle_ms, 250);
        // Other capability sections should still be defaults.
        assert_eq!(tools.process.default_timeout_ms, 120_000);
    }
}
