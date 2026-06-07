//! Server, agent, logging, hook, session, and tmux settings.
//!
//! These are grouped here because they are all relatively small and
//! server-oriented.

use std::collections::HashMap;

use serde::{Deserialize, Serialize};

use super::{UpdateAction, UpdateChannel, UpdateFrequency};

/// Server network and runtime settings.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default, deny_unknown_fields)]
pub struct ServerSettings {
    /// WebSocket heartbeat interval in milliseconds.
    ///
    /// Must be non-zero before it reaches the runtime because
    /// `tokio::time::interval(Duration::ZERO)` panics.
    pub heartbeat_interval_ms: u64,
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
    /// User-mode update-check configuration.
    #[serde(default)]
    pub update: UpdateSettings,
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
            memory_db_path: "memory.db".to_string(),
            default_model: "claude-sonnet-4-6".to_string(),
            default_provider: "anthropic".to_string(),
            default_workspace: None,
            transcription: TranscriptionSettings::default(),
            update: UpdateSettings::default(),
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

/// User-mode update-check configuration.
///
/// Drives the updater module's behavior. Default is the safest possible
/// combination — `enabled = false` means the
/// updater is entirely dormant. Flipping `enabled = true` with the
/// other fields at their defaults gives the gentlest behavior:
/// daily checks on the `stable` channel, `notify`-only when a
/// newer release is found (no automatic downloads).
///
/// All fields have 1:1 iOS UI counterparts per the project's
/// Settings-parity rule.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct UpdateSettings {
    /// Master switch. When `false`, no scheduler runs, no HTTP
    /// requests hit GitHub, and `system.checkForUpdates` returns
    /// `{ available: false, disabled: true }`. The safe default.
    pub enabled: bool,
    /// Release channel. `stable` ignores pre-release tags; `beta`
    /// includes them.
    pub channel: UpdateChannel,
    /// How often the in-process scheduler fires an automatic check.
    /// `manual` disables the scheduler entirely; checks only fire
    /// on explicit engine invocation.
    pub frequency: UpdateFrequency,
    /// What to do when a newer release is found. `notify` reports
    /// availability; `download` also stages and verifies the DMG.
    /// Installing still means replacing `/Applications/Tron.app`
    /// from the notarized DMG.
    pub action: UpdateAction,
}

impl Default for UpdateSettings {
    fn default() -> Self {
        Self {
            enabled: false,
            channel: UpdateChannel::default(),
            frequency: UpdateFrequency::default(),
            action: UpdateAction::default(),
        }
    }
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
        Self { enabled: false }
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
    /// Timeout for git worktree commands in milliseconds.
    pub worktree_timeout_ms: u64,
    /// Git worktree isolation settings.
    pub isolation: IsolationSettings,
    /// How queued messages are drained when the agent finishes.
    pub queue_drain_mode: QueueDrainMode,
}

impl Default for SessionSettings {
    fn default() -> Self {
        Self {
            worktree_timeout_ms: 30_000,
            isolation: IsolationSettings::default(),
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
        assert_eq!(s.default_provider, "anthropic");
        assert_eq!(s.default_model, "claude-sonnet-4-6");
        assert!(s.default_workspace.is_none());
        // tailscaleIp defaults absent (populated by installer scripts).
        assert!(s.tailscale_ip.is_none());
    }

    #[test]
    fn update_settings_defaults_are_safe() {
        // The safe default is the full "dormant" state: no HTTP
        // requests to GitHub and no downloads. Flipping just
        // `enabled = true` gives the gentlest behavior: daily stable
        // notify-only checks.
        let s = UpdateSettings::default();
        assert!(!s.enabled);
        assert_eq!(
            s.channel,
            UpdateChannel::Stable,
            "default channel must be stable"
        );
        assert_eq!(
            s.frequency,
            UpdateFrequency::Daily,
            "default frequency must be daily"
        );
        assert_eq!(
            s.action,
            UpdateAction::Notify,
            "default action must be notify"
        );
    }

    #[test]
    fn update_settings_default_when_section_missing() {
        // Missing `update` blocks deserialize to the dormant default.
        let s: ServerSettings = serde_json::from_str("{}").unwrap();
        assert!(!s.update.enabled);
    }

    #[test]
    fn update_settings_roundtrip() {
        let json = serde_json::json!({
            "update": {
                "enabled": true,
                "channel": "beta",
                "frequency": "hourly",
                "action": "notify"
            }
        });
        let s: ServerSettings = serde_json::from_value(json).unwrap();
        assert!(s.update.enabled);
        assert_eq!(s.update.channel, UpdateChannel::Beta);
        assert_eq!(s.update.frequency, UpdateFrequency::Hourly);
        assert_eq!(s.update.action, UpdateAction::Notify);

        // Roundtrip.
        let back = serde_json::to_value(&s).unwrap();
        assert_eq!(back["update"]["enabled"], true);
        assert_eq!(back["update"]["channel"], "beta");
        assert_eq!(back["update"]["frequency"], "hourly");
        assert_eq!(back["update"]["action"], "notify");
    }

    #[test]
    fn update_settings_partial_fills_from_defaults() {
        // Only `enabled` specified — everything else must land on the
        // safe defaults rather than fail to parse.
        let json = serde_json::json!({
            "update": { "enabled": true }
        });
        let s: ServerSettings = serde_json::from_value(json).unwrap();
        assert!(s.update.enabled);
        assert_eq!(s.update.channel, UpdateChannel::Stable);
        assert_eq!(s.update.action, UpdateAction::Notify);
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
    fn transcription_defaults() {
        let t = TranscriptionSettings::default();
        assert!(!t.enabled);
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
    }
}
