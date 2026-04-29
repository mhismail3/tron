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
    /// Bearer-token authentication settings.
    #[serde(default)]
    pub auth: AuthSettings,
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
            auth: AuthSettings::default(),
            update: UpdateSettings::default(),
            tailscale_ip: None,
        }
    }
}

/// Bearer-token authentication settings.
///
/// When `enforced` is `false` (the default during the Phase 2 rollout),
/// the WebSocket gate ignores the `Authorization` header entirely; clients
/// may send a bearer or omit it freely. This is the safe default while iOS
/// clients catch up to the new model.
///
/// When `enforced` is `true`, every WS upgrade must present a matching
/// `Authorization: Bearer <token>` header or get a `401`. The token lives
/// in `~/.tron/system/auth.json` as `bearerToken` and is rotatable via
/// `tron auth rotate`.
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct AuthSettings {
    /// Whether the WebSocket bearer-token check is enforced.
    pub enforced: bool,
}

/// User-mode update-check configuration.
///
/// Drives the `server::updater` module's behavior. Default is the
/// safest possible combination — `enabled = false` means the
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
    pub channel: crate::server::updater::UpdateChannel,
    /// How often the in-process scheduler fires an automatic check.
    /// `manual` disables the scheduler entirely; checks only fire
    /// on explicit RPC.
    pub frequency: crate::server::updater::UpdateFrequency,
    /// What to do when a newer release is found. `notify` reports
    /// availability; `download` also stages and verifies the DMG.
    /// Installing still means replacing `/Applications/Tron.app`
    /// from the notarized DMG.
    pub action: crate::server::updater::UpdateAction,
}

impl Default for UpdateSettings {
    fn default() -> Self {
        Self {
            enabled: false,
            channel: crate::server::updater::UpdateChannel::default(),
            frequency: crate::server::updater::UpdateFrequency::default(),
            action: crate::server::updater::UpdateAction::default(),
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
    /// Default model for LLM-based hooks.
    pub llm_model: String,
    /// Enable/disable state for built-in hooks.
    pub builtin_hooks: Vec<BuiltinHookSetting>,
    /// What to do when a hook handler errors or times out.
    ///
    /// - `"continue"` (default) — treat the failure as `Continue` so the
    ///   agent proceeds. Fail-open: errors in a script-based hook are usually
    ///   developer bugs, not attacks, so the default is not to block.
    /// - `"block"` — synthesize a `Block` with a reason naming the
    ///   handler and the failure kind. Security / guard hooks that
    ///   should not silently fail open opt into this.
    pub error_policy: crate::runtime::hooks::types::HookErrorPolicy,
}

impl Default for HookSettings {
    fn default() -> Self {
        Self {
            default_timeout_ms: 5000,
            discovery_timeout_ms: 10_000,
            project_dir: ".agent/hooks".to_string(),
            user_dir: ".config/tron/hooks".to_string(),
            extensions: vec![
                ".prompt".to_string(),
                ".ts".to_string(),
                ".js".to_string(),
                ".mjs".to_string(),
                ".sh".to_string(),
            ],
            llm_model: "claude-haiku-4-5-20251001".to_string(),
            builtin_hooks: BuiltinHookSetting::defaults(),
            error_policy: crate::runtime::hooks::types::HookErrorPolicy::default(),
        }
    }
}

/// Enable/disable toggle for a built-in hook.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BuiltinHookSetting {
    /// Built-in hook identifier (e.g., `"builtin:title-gen"`).
    pub id: String,
    /// Whether this built-in hook is active.
    pub enabled: bool,
}

impl BuiltinHookSetting {
    /// Default built-in hook settings.
    pub fn defaults() -> Vec<Self> {
        vec![
            Self {
                id: "builtin:title-gen".to_string(),
                enabled: true,
            },
            Self {
                id: "builtin:branch-name-gen".to_string(),
                enabled: true,
            },
            Self {
                id: "builtin:suggest-prompts".to_string(),
                enabled: true,
            },
        ]
    }

    /// Look up whether a builtin hook is enabled in a settings list.
    /// Returns `true` if the hook is not found (default enabled).
    pub fn is_enabled(settings: &[Self], id: &str) -> bool {
        settings
            .iter()
            .find(|s| s.id == id)
            .map(|s| s.enabled)
            .unwrap_or(true)
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
        // Phase 2: bearer auth defaults OFF so existing clients keep working.
        assert!(!s.auth.enforced);
        // Phase 2: tailscaleIp defaults absent (populated by installer scripts).
        assert!(s.tailscale_ip.is_none());
    }

    #[test]
    fn auth_settings_serde_camel_case() {
        let s = ServerSettings::default();
        let json = serde_json::to_value(&s).unwrap();
        // `auth` key always present (camelCase, nested struct serialized).
        assert!(json.get("auth").is_some());
        assert_eq!(json["auth"]["enforced"], false);
    }

    #[test]
    fn auth_settings_roundtrip_when_enforced() {
        let json = serde_json::json!({
            "auth": { "enforced": true }
        });
        let s: ServerSettings = serde_json::from_value(json).unwrap();
        assert!(s.auth.enforced);
        let back = serde_json::to_value(&s).unwrap();
        assert_eq!(back["auth"]["enforced"], true);
    }

    #[test]
    fn auth_settings_default_when_section_missing() {
        // Existing settings.json files don't have an `auth` block; they
        // must continue to deserialize without error and end up with the
        // safe (off) default.
        let s: ServerSettings = serde_json::from_str("{}").unwrap();
        assert!(!s.auth.enforced);
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
            crate::server::updater::UpdateChannel::Stable,
            "default channel must be stable"
        );
        assert_eq!(
            s.frequency,
            crate::server::updater::UpdateFrequency::Daily,
            "default frequency must be daily"
        );
        assert_eq!(
            s.action,
            crate::server::updater::UpdateAction::Notify,
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
        assert_eq!(
            s.update.channel,
            crate::server::updater::UpdateChannel::Beta
        );
        assert_eq!(
            s.update.frequency,
            crate::server::updater::UpdateFrequency::Hourly
        );
        assert_eq!(
            s.update.action,
            crate::server::updater::UpdateAction::Notify
        );

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
        assert_eq!(
            s.update.channel,
            crate::server::updater::UpdateChannel::Stable
        );
        assert_eq!(
            s.update.action,
            crate::server::updater::UpdateAction::Notify
        );
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
    fn stale_fields_ignored_during_deserialization() {
        // Users upgrading from older releases may have these keys in their
        // settings.json. Deserialization must ignore them cleanly (serde's
        // default behavior) rather than fail the load.
        //   wsPort / healthPort / host / sessionTimeoutMs /
        //   anthropicAccount: never existed in ServerSettings as a real field.
        //   maxSessions / cacheTtl: removed in 754cbc6d (settings consolidation).
        //   maxConcurrentSessions: bogus default written by old tron-lib.sh
        //     (never decoded, purged from install template in this release).
        // `tailscaleIp` is now a real field (Phase 2); covered separately
        // in `tailscale_ip_roundtrip_when_present`.
        let json = serde_json::json!({
            "wsPort": 8082,
            "healthPort": 8083,
            "host": "0.0.0.0",
            "sessionTimeoutMs": 3_600_000,
            "anthropicAccount": "personal",
            "maxSessions": 20,
            "cacheTtl": 7200,
            "maxConcurrentSessions": 10,
            "defaultModel": "claude-sonnet-4-6"
        });
        let s: ServerSettings = serde_json::from_value(json).unwrap();
        assert_eq!(s.default_model, "claude-sonnet-4-6");
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
    fn hook_defaults() {
        let h = HookSettings::default();
        assert_eq!(h.default_timeout_ms, 5000);
        assert_eq!(h.extensions.len(), 5);
        assert!(h.extensions.contains(&".prompt".to_string()));
        assert!(h.extensions.contains(&".ts".to_string()));
        assert_eq!(h.llm_model, "claude-haiku-4-5-20251001");
        assert_eq!(h.builtin_hooks.len(), 3);
        assert_eq!(h.builtin_hooks[0].id, "builtin:title-gen");
        assert!(h.builtin_hooks[0].enabled);
        assert_eq!(h.builtin_hooks[1].id, "builtin:branch-name-gen");
        assert!(h.builtin_hooks[1].enabled);
        assert_eq!(h.builtin_hooks[2].id, "builtin:suggest-prompts");
        assert!(h.builtin_hooks[2].enabled);
        let json = serde_json::to_value(&h).unwrap();
        assert!(
            json.get("maxAddedContextChars").is_none(),
            "hook add-context budget is an internal engine fuse, not a user setting"
        );
    }

    #[test]
    fn hook_settings_deserialize_without_builtin_hooks() {
        let json = serde_json::json!({
            "defaultTimeoutMs": 3000,
            "projectDir": ".hooks"
        });
        let h: HookSettings = serde_json::from_value(json).unwrap();
        assert_eq!(h.default_timeout_ms, 3000);
        assert_eq!(h.llm_model, "claude-haiku-4-5-20251001");
        // Defaults populated
        assert_eq!(h.builtin_hooks.len(), 3);
        assert_eq!(h.builtin_hooks[0].id, "builtin:title-gen");
    }

    #[test]
    fn hook_settings_deserialize_with_builtin_hooks_disabled() {
        let json = serde_json::json!({
            "builtinHooks": [{"id": "builtin:title-gen", "enabled": false}]
        });
        let h: HookSettings = serde_json::from_value(json).unwrap();
        assert_eq!(h.builtin_hooks.len(), 1);
        assert!(!h.builtin_hooks[0].enabled);
    }

    #[test]
    fn hook_settings_serialize_roundtrip() {
        let h = HookSettings::default();
        let json = serde_json::to_value(&h).unwrap();
        let h2: HookSettings = serde_json::from_value(json).unwrap();
        assert_eq!(h.llm_model, h2.llm_model);
        assert_eq!(h.builtin_hooks.len(), h2.builtin_hooks.len());
        assert_eq!(h.builtin_hooks[0].id, h2.builtin_hooks[0].id);
        assert_eq!(h.builtin_hooks[0].enabled, h2.builtin_hooks[0].enabled);
    }

    #[test]
    fn builtin_hook_is_enabled_lookup() {
        let settings = vec![BuiltinHookSetting {
            id: "builtin:title-gen".into(),
            enabled: false,
        }];
        assert!(!BuiltinHookSetting::is_enabled(
            &settings,
            "builtin:title-gen"
        ));
        assert!(BuiltinHookSetting::is_enabled(&settings, "builtin:unknown")); // not found → default true
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
