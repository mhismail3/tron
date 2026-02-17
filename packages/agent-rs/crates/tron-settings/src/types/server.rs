//! Server, agent, logging, hook, session, and tmux settings.
//!
//! These are grouped here because they are all relatively small and
//! server-oriented.

use serde::{Deserialize, Serialize};

/// Server network and runtime settings.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ServerSettings {
    /// WebSocket server port.
    pub ws_port: u16,
    /// Health check HTTP port.
    pub health_port: u16,
    /// Bind address.
    pub host: String,
    /// Optional Tailscale IP for network access.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tailscale_ip: Option<String>,
    /// WebSocket heartbeat interval in milliseconds.
    pub heartbeat_interval_ms: u64,
    /// Session inactivity timeout in milliseconds.
    pub session_timeout_ms: u64,
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
    /// Anthropic account label for multi-account selection.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub anthropic_account: Option<String>,
    /// Audio transcription settings.
    pub transcription: TranscriptionSettings,
}

impl Default for ServerSettings {
    fn default() -> Self {
        Self {
            ws_port: 8080,
            health_port: 8081,
            host: "0.0.0.0".to_string(),
            tailscale_ip: None,
            heartbeat_interval_ms: 30_000,
            session_timeout_ms: 1_800_000,
            max_concurrent_sessions: 10,
            sessions_dir: "sessions".to_string(),
            memory_db_path: "memory.db".to_string(),
            default_model: "claude-sonnet-4-20250514".to_string(),
            default_provider: "anthropic".to_string(),
            default_workspace: None,
            anthropic_account: None,
            transcription: TranscriptionSettings::default(),
        }
    }
}

/// Transcription cleanup mode.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum CleanupMode {
    /// No cleanup.
    None,
    /// Basic text normalization.
    #[default]
    Basic,
    /// LLM-powered cleanup.
    Llm,
}

/// Audio transcription settings.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct TranscriptionSettings {
    /// Whether transcription is enabled.
    pub enabled: bool,
    /// Whether to auto-manage the transcription sidecar process.
    pub manage_sidecar: bool,
    /// Base URL of the transcription service.
    pub base_url: String,
    /// Request timeout in milliseconds.
    pub timeout_ms: u64,
    /// Post-transcription cleanup mode.
    pub cleanup_mode: CleanupMode,
    /// Maximum audio file size in bytes.
    pub max_bytes: u64,
}

impl Default for TranscriptionSettings {
    fn default() -> Self {
        Self {
            enabled: true,
            manage_sidecar: true,
            base_url: "http://127.0.0.1:8787".to_string(),
            timeout_ms: 180_000,
            cleanup_mode: CleanupMode::Basic,
            max_bytes: 26_214_400,
        }
    }
}

/// Agent runtime settings.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct AgentRuntimeSettings {
    /// Maximum number of agentic turns per prompt.
    pub max_turns: u32,
    /// Timeout for inactive sessions in milliseconds.
    pub inactive_session_timeout_ms: u64,
}

impl Default for AgentRuntimeSettings {
    fn default() -> Self {
        Self {
            max_turns: 100,
            inactive_session_timeout_ms: 1_800_000,
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
}

impl Default for LoggingSettings {
    fn default() -> Self {
        Self {
            db_log_level: LogLevel::Info,
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
}

impl Default for SessionSettings {
    fn default() -> Self {
        Self {
            worktree_timeout_ms: 30_000,
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
        assert_eq!(s.ws_port, 8080);
        assert_eq!(s.health_port, 8081);
        assert_eq!(s.host, "0.0.0.0");
        assert!(s.tailscale_ip.is_none());
        assert_eq!(s.max_concurrent_sessions, 10);
        assert_eq!(s.default_provider, "anthropic");
    }

    #[test]
    fn server_serde_camel_case() {
        let s = ServerSettings::default();
        let json = serde_json::to_value(&s).unwrap();
        assert!(json.get("wsPort").is_some());
        assert!(json.get("healthPort").is_some());
        assert!(json.get("heartbeatIntervalMs").is_some());
        assert!(json.get("defaultModel").is_some());
    }

    #[test]
    fn server_omits_none_fields() {
        let s = ServerSettings::default();
        let json = serde_json::to_value(&s).unwrap();
        assert!(json.get("tailscaleIp").is_none());
        assert!(json.get("defaultWorkspace").is_none());
        assert!(json.get("anthropicAccount").is_none());
    }

    #[test]
    fn transcription_defaults() {
        let t = TranscriptionSettings::default();
        assert!(t.enabled);
        assert!(t.manage_sidecar);
        assert_eq!(t.cleanup_mode, CleanupMode::Basic);
        assert_eq!(t.max_bytes, 26_214_400);
    }

    #[test]
    fn cleanup_mode_serde() {
        for (mode, expected) in [
            (CleanupMode::None, "\"none\""),
            (CleanupMode::Basic, "\"basic\""),
            (CleanupMode::Llm, "\"llm\""),
        ] {
            let json = serde_json::to_string(&mode).unwrap();
            assert_eq!(json, expected);
            let back: CleanupMode = serde_json::from_str(&json).unwrap();
            assert_eq!(back, mode);
        }
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
        assert_eq!(a.max_turns, 100);
        assert_eq!(a.inactive_session_timeout_ms, 1_800_000);
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
    }

    #[test]
    fn server_partial_json() {
        let json = serde_json::json!({
            "wsPort": 9090,
            "defaultModel": "claude-sonnet-4-5-20250929"
        });
        let s: ServerSettings = serde_json::from_value(json).unwrap();
        assert_eq!(s.ws_port, 9090);
        assert_eq!(s.default_model, "claude-sonnet-4-5-20250929");
        // Other fields should be defaults
        assert_eq!(s.health_port, 8081);
        assert_eq!(s.host, "0.0.0.0");
    }
}
