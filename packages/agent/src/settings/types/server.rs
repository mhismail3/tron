//! Server, agent, logging, hook, session, and tmux settings.
//!
//! These are grouped here because they are all relatively small and
//! server-oriented.

use std::collections::HashMap;

use serde::{Deserialize, Serialize};

/// Server network and runtime settings.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ServerSettings {
    /// WebSocket heartbeat interval in milliseconds.
    pub heartbeat_interval_ms: u64,
    /// Maximum number of concurrent sessions.
    pub max_concurrent_sessions: usize,
    /// Directory for session data (relative to `~/.tron`).
    pub sessions_dir: String,
    /// Path to the memory database (relative to `~/.tron`).
    pub memory_db_path: String,
    /// Default LLM model identifier.
    pub default_model: String,
    /// Default LLM provider.
    pub default_provider: String,
    /// Default workspace path.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub default_workspace: Option<String>,
    /// Audio transcription settings.
    pub transcription: TranscriptionSettings,
    /// Quick-connect connection presets for iOS clients.
    #[serde(default)]
    pub connection_presets: Vec<ConnectionPreset>,
}

impl Default for ServerSettings {
    fn default() -> Self {
        Self {
            heartbeat_interval_ms: 30_000,
            max_concurrent_sessions: 10,
            sessions_dir: "sessions".to_string(),
            memory_db_path: "memory.db".to_string(),
            default_model: "claude-sonnet-4-6".to_string(),
            default_provider: "anthropic".to_string(),
            default_workspace: None,
            transcription: TranscriptionSettings::default(),
            connection_presets: Vec::new(),
        }
    }
}

/// A connection preset for quick-connect from iOS clients.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ConnectionPreset {
    /// Unique identifier.
    pub id: String,
    /// Display label.
    pub label: String,
    /// Hostname or IP address.
    pub host: String,
    /// Port number.
    pub port: u16,
}

/// Audio transcription settings.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct TranscriptionSettings {
    /// Whether transcription is enabled.
    pub enabled: bool,
}

impl Default for TranscriptionSettings {
    fn default() -> Self {
        Self { enabled: true }
    }
}

/// Agent runtime settings.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct AgentRuntimeSettings {
    /// Maximum number of agentic turns per prompt.
    pub max_turns: u32,
    /// Maximum subagent nesting depth.
    pub subagent_max_depth: u32,
    /// Default model for skill sub-agents.
    pub subagent_model: String,
}

impl Default for AgentRuntimeSettings {
    fn default() -> Self {
        Self {
            max_turns: 250,
            subagent_max_depth: 3,
            subagent_model: "claude-haiku-4-5-20251001".to_string(),
        }
    }
}

/// Log level for database logging.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum LogLevel {
    /// Trace-level (most verbose).
    Trace,
    /// Debug-level.
    Debug,
    /// Info-level (default).
    #[default]
    Info,
    /// Warning-level.
    Warn,
    /// Error-level.
    Error,
    /// Fatal-level (least verbose).
    Fatal,
}

impl LogLevel {
    /// Convert to a tracing filter string.
    pub fn as_filter_str(&self) -> &'static str {
        match self {
            Self::Trace => "trace",
            Self::Debug => "debug",
            Self::Info => "info",
            Self::Warn => "warn",
            Self::Error | Self::Fatal => "error",
        }
    }
}

/// Logging configuration.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct LoggingSettings {
    /// Minimum log level written to the database.
    pub db_log_level: LogLevel,
    /// Per-module log level overrides. Keys are Rust module/crate names.
    /// Example: `{"ort": "warn"}` suppresses ONNX Runtime info spam.
    pub module_overrides: HashMap<String, LogLevel>,
}

impl Default for LoggingSettings {
    fn default() -> Self {
        Self {
            db_log_level: LogLevel::Info,
            module_overrides: HashMap::from([("ort".to_string(), LogLevel::Error)]),
        }
    }
}

/// Hook system configuration.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct HookSettings {
    /// Default timeout for hook execution in milliseconds.
    pub default_timeout_ms: u64,
    /// Timeout for hook discovery in milliseconds.
    pub discovery_timeout_ms: u64,
    /// Project-relative directory for hook scripts.
    pub project_dir: String,
    /// User-level directory for hook scripts.
    pub user_dir: String,
    /// Allowed hook script file extensions.
    pub extensions: Vec<String>,
}

impl Default for HookSettings {
    fn default() -> Self {
        Self {
            default_timeout_ms: 5000,
            discovery_timeout_ms: 10_000,
            project_dir: ".agent/hooks".to_string(),
            user_dir: ".config/tron/hooks".to_string(),
            extensions: vec![
                ".ts".to_string(),
                ".js".to_string(),
                ".mjs".to_string(),
                ".sh".to_string(),
            ],
        }
    }
}

/// Tmux integration settings.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct TmuxSettings {
    /// Timeout for tmux commands in milliseconds.
    pub command_timeout_ms: u64,
    /// Polling interval for tmux state in milliseconds.
    pub polling_interval_ms: u64,
}

impl Default for TmuxSettings {
    fn default() -> Self {
        Self {
            command_timeout_ms: 30_000,
            polling_interval_ms: 500,
        }
    }
}

/// Session behavior settings.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct SessionSettings {
    /// Timeout for git worktree commands in milliseconds.
    pub worktree_timeout_ms: u64,
    /// Git worktree isolation settings.
    pub isolation: IsolationSettings,
    /// Default chat session settings.
    pub chat: ChatSettings,
}

impl Default for SessionSettings {
    fn default() -> Self {
        Self {
            worktree_timeout_ms: 30_000,
            isolation: IsolationSettings::default(),
            chat: ChatSettings::default(),
        }
    }
}

/// Default chat session settings.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ChatSettings {
    /// Whether the default chat session is enabled.
    pub enabled: bool,
    /// Working directory for the chat session.
    pub working_directory: String,
}

impl Default for ChatSettings {
    fn default() -> Self {
        let home = crate::core::paths::home_dir();
        Self {
            enabled: true,
            working_directory: format!("{home}/Workspace"),
        }
    }
}

/// When to create isolated git worktrees for sessions.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum IsolationMode {
    /// Every session in a git repo gets its own worktree.
    #[default]
    Always,
    /// Only create worktrees when multiple sessions target the same repo.
    Lazy,
    /// Never create worktrees.
    Never,
}

/// Git worktree isolation configuration.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct IsolationSettings {
    /// When to create worktrees.
    pub mode: IsolationMode,
    /// Directory name under repo root for worktrees.
    pub base_dir: String,
    /// Branch name prefix for session branches.
    pub branch_prefix: String,
    /// Auto-commit uncommitted changes when releasing a worktree.
    pub auto_commit_on_release: bool,
    /// Keep the branch after deleting the worktree directory.
    pub preserve_branches: bool,
    /// Delete the worktree directory on release.
    pub delete_worktree_on_release: bool,
}

impl Default for IsolationSettings {
    fn default() -> Self {
        Self {
            mode: IsolationMode::Always,
            base_dir: ".worktrees".to_string(),
            branch_prefix: "session/".to_string(),
            auto_commit_on_release: true,
            preserve_branches: true,
            delete_worktree_on_release: true,
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
    fn server_defaults() {
        let s = ServerSettings::default();
        assert_eq!(s.heartbeat_interval_ms, 30_000);
        assert_eq!(s.max_concurrent_sessions, 10);
        assert_eq!(s.default_provider, "anthropic");
        assert_eq!(s.default_model, "claude-sonnet-4-6");
        assert!(s.default_workspace.is_none());
        assert!(s.connection_presets.is_empty());
    }

    #[test]
    fn server_serde_camel_case() {
        let s = ServerSettings::default();
        let json = serde_json::to_value(&s).unwrap();
        assert!(json.get("heartbeatIntervalMs").is_some());
        assert!(json.get("defaultModel").is_some());
        assert!(json.get("connectionPresets").is_some());
    }

    #[test]
    fn server_omits_none_fields() {
        let s = ServerSettings::default();
        let json = serde_json::to_value(&s).unwrap();
        assert!(json.get("defaultWorkspace").is_none());
    }

    #[test]
    fn connection_presets_serde_roundtrip() {
        let json = serde_json::json!({
            "connectionPresets": [
                {"id": "main", "label": "Main", "host": "100.64.213.113", "port": 9847},
                {"id": "secondary", "label": "Secondary", "host": "100.95.255.62", "port": 9847}
            ]
        });
        let s: ServerSettings = serde_json::from_value(json).unwrap();
        assert_eq!(s.connection_presets.len(), 2);
        assert_eq!(s.connection_presets[0].id, "main");
        assert_eq!(s.connection_presets[0].label, "Main");
        assert_eq!(s.connection_presets[0].host, "100.64.213.113");
        assert_eq!(s.connection_presets[0].port, 9847);
        assert_eq!(s.connection_presets[1].id, "secondary");
    }

    #[test]
    fn connection_presets_empty_by_default() {
        let s: ServerSettings = serde_json::from_str("{}").unwrap();
        assert!(s.connection_presets.is_empty());
    }

    #[test]
    fn stale_fields_ignored_during_deserialization() {
        let json = serde_json::json!({
            "wsPort": 8082,
            "healthPort": 8083,
            "host": "0.0.0.0",
            "tailscaleIp": "100.64.213.113",
            "sessionTimeoutMs": 3600000,
            "anthropicAccount": "mhismail3",
            "defaultModel": "claude-sonnet-4-6"
        });
        let s: ServerSettings = serde_json::from_value(json).unwrap();
        assert_eq!(s.default_model, "claude-sonnet-4-6");
        assert_eq!(s.max_concurrent_sessions, 10);
    }

    #[test]
    fn transcription_defaults() {
        let t = TranscriptionSettings::default();
        assert!(t.enabled);
    }

    #[test]
    fn log_level_serde() {
        for (level, expected) in [
            (LogLevel::Trace, "\"trace\""),
            (LogLevel::Debug, "\"debug\""),
            (LogLevel::Info, "\"info\""),
            (LogLevel::Warn, "\"warn\""),
            (LogLevel::Error, "\"error\""),
            (LogLevel::Fatal, "\"fatal\""),
        ] {
            let json = serde_json::to_string(&level).unwrap();
            assert_eq!(json, expected);
            let back: LogLevel = serde_json::from_str(&json).unwrap();
            assert_eq!(back, level);
        }
    }

    #[test]
    fn log_level_as_filter_str() {
        assert_eq!(LogLevel::Trace.as_filter_str(), "trace");
        assert_eq!(LogLevel::Debug.as_filter_str(), "debug");
        assert_eq!(LogLevel::Info.as_filter_str(), "info");
        assert_eq!(LogLevel::Warn.as_filter_str(), "warn");
        assert_eq!(LogLevel::Error.as_filter_str(), "error");
        assert_eq!(LogLevel::Fatal.as_filter_str(), "error");
    }

    #[test]
    fn agent_defaults() {
        let a = AgentRuntimeSettings::default();
        assert_eq!(a.max_turns, 250);
        assert_eq!(a.subagent_max_depth, 3);
        assert_eq!(a.subagent_model, "claude-haiku-4-5-20251001");
    }

    #[test]
    fn agent_serde_subagent_max_depth() {
        let json = serde_json::json!({ "subagentMaxDepth": 5 });
        let a: AgentRuntimeSettings = serde_json::from_value(json).unwrap();
        assert_eq!(a.subagent_max_depth, 5);
        assert_eq!(a.max_turns, 250); // other fields default

        let roundtrip = serde_json::to_value(&a).unwrap();
        assert_eq!(roundtrip.get("subagentMaxDepth").unwrap(), 5);
    }

    #[test]
    fn default_logging_suppresses_ort() {
        let settings = LoggingSettings::default();
        assert_eq!(
            settings.module_overrides.get("ort"),
            Some(&LogLevel::Error),
            "ort default should be Error to suppress ONNX Runtime log spam"
        );
    }

    #[test]
    fn hook_defaults() {
        let h = HookSettings::default();
        assert_eq!(h.default_timeout_ms, 5000);
        assert_eq!(h.extensions.len(), 4);
        assert!(h.extensions.contains(&".ts".to_string()));
    }

    #[test]
    fn tmux_defaults() {
        let t = TmuxSettings::default();
        assert_eq!(t.command_timeout_ms, 30_000);
        assert_eq!(t.polling_interval_ms, 500);
    }

    #[test]
    fn session_defaults() {
        let s = SessionSettings::default();
        assert_eq!(s.worktree_timeout_ms, 30_000);
        assert_eq!(s.isolation.mode, IsolationMode::Always);
        assert_eq!(s.isolation.base_dir, ".worktrees");
        assert_eq!(s.isolation.branch_prefix, "session/");
        assert!(s.isolation.auto_commit_on_release);
        assert!(s.isolation.preserve_branches);
        assert!(s.isolation.delete_worktree_on_release);
        assert!(s.chat.enabled);
        assert!(s.chat.working_directory.contains("Workspace"));
    }

    #[test]
    fn isolation_mode_serde() {
        for (mode, expected) in [
            (IsolationMode::Always, "\"always\""),
            (IsolationMode::Lazy, "\"lazy\""),
            (IsolationMode::Never, "\"never\""),
        ] {
            let json = serde_json::to_string(&mode).unwrap();
            assert_eq!(json, expected);
            let back: IsolationMode = serde_json::from_str(&json).unwrap();
            assert_eq!(back, mode);
        }
    }

    #[test]
    fn isolation_partial_json() {
        let json = serde_json::json!({ "mode": "never" });
        let s: IsolationSettings = serde_json::from_value(json).unwrap();
        assert_eq!(s.mode, IsolationMode::Never);
        assert_eq!(s.base_dir, ".worktrees");
        assert_eq!(s.branch_prefix, "session/");
        assert!(s.auto_commit_on_release);
    }

    #[test]
    fn session_with_isolation_override() {
        let json = serde_json::json!({
            "isolation": { "mode": "lazy", "branchPrefix": "wt/" }
        });
        let s: SessionSettings = serde_json::from_value(json).unwrap();
        assert_eq!(s.isolation.mode, IsolationMode::Lazy);
        assert_eq!(s.isolation.branch_prefix, "wt/");
        assert_eq!(s.worktree_timeout_ms, 30_000);
    }

    #[test]
    fn empty_session_json_uses_defaults() {
        let s: SessionSettings = serde_json::from_str("{}").unwrap();
        assert_eq!(s.isolation.mode, IsolationMode::Always);
        assert_eq!(s.worktree_timeout_ms, 30_000);
    }

    #[test]
    fn server_partial_json() {
        let json = serde_json::json!({
            "defaultModel": "claude-sonnet-4-5-20250929"
        });
        let s: ServerSettings = serde_json::from_value(json).unwrap();
        assert_eq!(s.default_model, "claude-sonnet-4-5-20250929");
        assert_eq!(s.max_concurrent_sessions, 10);
    }
}
