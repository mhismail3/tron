//! Server, agent, logging, session, and tmux settings.
//!
//! These are grouped here because they are all relatively small and
//! server-oriented.

use serde::{Deserialize, Serialize};
use std::collections::HashMap;

/// Server network and runtime settings.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default, deny_unknown_fields)]
pub struct ServerSettings {
    /// WebSocket heartbeat interval in milliseconds.
    ///
    /// Must be non-zero before it reaches the runtime because
    /// `tokio::time::interval(Duration::ZERO)` panics.
    pub heartbeat_interval_ms: u64,
    /// Default LLM model identifier.
    pub default_model: String,
    /// Default LLM provider.
    pub default_provider: String,
    /// Default workspace path.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub default_workspace: Option<String>,
    /// Cached Tailscale IP address. Populated by the Mac wrapper / install
    /// scripts (or manually) so iOS clients can display "your Mac is at
    /// 100.x.y.z" without shelling out to the `tailscale` binary.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tailscale_ip: Option<String>,
}

impl Default for ServerSettings {
    fn default() -> Self {
        Self {
            heartbeat_interval_ms: 30_000,
            default_model: "claude-sonnet-4-6".to_string(),
            default_provider: "anthropic".to_string(),
            default_workspace: None,
            tailscale_ip: None,
        }
    }
}

impl ServerSettings {
    /// Minimum allowed WebSocket heartbeat interval in milliseconds.
    pub const MIN_HEARTBEAT_INTERVAL_MS: u64 = 1_000;
    /// Maximum allowed WebSocket heartbeat interval in milliseconds.
    pub const MAX_HEARTBEAT_INTERVAL_MS: u64 = 600_000;

    /// Validate invariants that cannot be safely corrected at runtime.
    pub fn validate_strict(&self) -> crate::domains::settings::Result<()> {
        if !(Self::MIN_HEARTBEAT_INTERVAL_MS..=Self::MAX_HEARTBEAT_INTERVAL_MS)
            .contains(&self.heartbeat_interval_ms)
        {
            return Err(crate::domains::settings::SettingsError::InvalidValue(
                format!(
                    "server.heartbeatIntervalMs must be between {} and {} milliseconds",
                    Self::MIN_HEARTBEAT_INTERVAL_MS,
                    Self::MAX_HEARTBEAT_INTERVAL_MS
                ),
            ));
        }
        Ok(())
    }
}

/// Agent runtime settings.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct AgentRuntimeSettings {
    /// Maximum number of agentic turns per prompt.
    pub max_turns: u32,
}

impl Default for AgentRuntimeSettings {
    fn default() -> Self {
        Self { max_turns: 250 }
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
    /// Per-module log level overrides. Keys are Rust module/crate names.
    /// Example: `{"ort": "warn"}` suppresses ONNX Runtime info spam.
    pub module_overrides: HashMap<String, LogLevel>,
}

impl Default for LoggingSettings {
    fn default() -> Self {
        Self {
            module_overrides: HashMap::from([("ort".to_string(), LogLevel::Error)]),
        }
    }
}

/// How much structured payload detail observability stores.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum PayloadCaptureLevel {
    /// Store compact summaries and error details only.
    #[default]
    Normal,
    /// Store previews and selected request/response details.
    Debug,
    /// Store full payloads through blob refs with short retention.
    Trace,
}

/// Engine observability configuration.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default, deny_unknown_fields)]
pub struct ObservabilitySettings {
    /// Minimum observability verbosity for structured engine diagnostics.
    pub log_level: LogLevel,
    /// Payload capture policy. Full capture must use blob-backed storage.
    pub payload_capture: PayloadCaptureLevel,
    /// Retention window for verbose diagnostics.
    pub verbose_retention_days: u64,
    /// Maximum inline payload bytes before blob-backed storage is required.
    pub max_inline_payload_bytes: usize,
}

impl Default for ObservabilitySettings {
    fn default() -> Self {
        Self {
            log_level: LogLevel::Info,
            payload_capture: PayloadCaptureLevel::Normal,
            verbose_retention_days: 7,
            max_inline_payload_bytes: crate::shared::storage::DEFAULT_MAX_INLINE_PAYLOAD_BYTES,
        }
    }
}

/// Unified SQLite storage policy.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default, deny_unknown_fields)]
pub struct StorageSettings {
    /// Whether automatic retention may prune low-signal diagnostics.
    pub retention_enabled: bool,
    /// Soft cap used by retention reports and future background compaction.
    pub max_database_mb: u64,
}

impl Default for StorageSettings {
    fn default() -> Self {
        Self {
            retention_enabled: true,
            max_database_mb: 512,
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
    /// How queued messages are drained when the agent finishes.
    pub queue_drain_mode: QueueDrainMode,
}

impl Default for SessionSettings {
    fn default() -> Self {
        Self {
            queue_drain_mode: QueueDrainMode::default(),
        }
    }
}

/// How queued messages are drained after the agent finishes a turn.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum QueueDrainMode {
    /// Each queued message is sent as its own turn (agent responds to each individually).
    #[default]
    Sequential,
    /// All pending queued messages are combined into a single prompt for one turn.
    Batched,
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
        assert_eq!(s.default_provider, "anthropic");
        assert_eq!(s.default_model, "claude-sonnet-4-6");
        assert!(s.default_workspace.is_none());
        // tailscaleIp defaults absent (populated by installer scripts).
        assert!(s.tailscale_ip.is_none());
    }

    #[test]
    fn tailscale_ip_roundtrip_when_present() {
        let json = serde_json::json!({
            "tailscaleIp": "100.64.213.113"
        });
        let s: ServerSettings = serde_json::from_value(json).unwrap();
        assert_eq!(s.tailscale_ip.as_deref(), Some("100.64.213.113"));
        let back = serde_json::to_value(&s).unwrap();
        assert_eq!(back["tailscaleIp"], "100.64.213.113");
    }

    #[test]
    fn tailscale_ip_omitted_when_absent() {
        let s = ServerSettings::default();
        let json = serde_json::to_value(&s).unwrap();
        // skip_serializing_if = "Option::is_none" — the key shouldn't appear.
        assert!(json.get("tailscaleIp").is_none());
    }

    #[test]
    fn server_serde_camel_case() {
        let s = ServerSettings::default();
        let json = serde_json::to_value(&s).unwrap();
        assert!(json.get("heartbeatIntervalMs").is_some());
        assert!(json.get("defaultModel").is_some());
    }

    #[test]
    fn server_omits_none_fields() {
        let s = ServerSettings::default();
        let json = serde_json::to_value(&s).unwrap();
        assert!(json.get("defaultWorkspace").is_none());
    }

    #[test]
    fn stale_server_fields_are_rejected() {
        let json = serde_json::json!({
            "wsPort": 8082,
            "defaultModel": "claude-sonnet-4-6"
        });
        let err = serde_json::from_value::<ServerSettings>(json).unwrap_err();
        assert!(err.to_string().contains("unknown field"));
    }

    #[test]
    fn removed_auth_setting_is_rejected() {
        let json = serde_json::json!({
            "auth": { "enforced": true }
        });
        let err = serde_json::from_value::<ServerSettings>(json).unwrap_err();
        assert!(err.to_string().contains("unknown field"));
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
    }

    #[test]
    fn agent_partial_json_uses_defaults() {
        let json = serde_json::json!({});
        let a: AgentRuntimeSettings = serde_json::from_value(json).unwrap();
        assert_eq!(a.max_turns, 250);

        let roundtrip = serde_json::to_value(&a).unwrap();
        assert_eq!(roundtrip["maxTurns"], 250);
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
    fn tmux_defaults() {
        let t = TmuxSettings::default();
        assert_eq!(t.command_timeout_ms, 30_000);
        assert_eq!(t.polling_interval_ms, 500);
    }

    #[test]
    fn session_defaults() {
        let s = SessionSettings::default();
        assert_eq!(s.queue_drain_mode, QueueDrainMode::Sequential);
    }

    #[test]
    fn session_with_queue_override() {
        let json = serde_json::json!({
            "queueDrainMode": "batched"
        });
        let s: SessionSettings = serde_json::from_value(json).unwrap();
        assert_eq!(s.queue_drain_mode, QueueDrainMode::Batched);
    }

    #[test]
    fn empty_session_json_uses_defaults() {
        let s: SessionSettings = serde_json::from_str("{}").unwrap();
        assert_eq!(s.queue_drain_mode, QueueDrainMode::Sequential);
    }

    #[test]
    fn server_partial_json() {
        let json = serde_json::json!({
            "defaultModel": "claude-sonnet-4-5-20250929"
        });
        let s: ServerSettings = serde_json::from_value(json).unwrap();
        assert_eq!(s.default_model, "claude-sonnet-4-5-20250929");
    }
}
