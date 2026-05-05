//! Settings type definitions.
//!
//! All types use `#[serde(rename_all = "camelCase")]` to match the TypeScript
//! JSON wire format. Each type implements [`Default`] with the emergency
//! fallback values that must stay in parity with the bundled
//! `profiles/default/settings/defaults.json`. Types marked with `#[serde(default)]`
//! allow partial JSON — missing fields get their default value during
//! deserialization.

mod api;
mod context;
mod git;
mod guardrails;
mod memory;
mod prompt_library;
mod server;
mod skills;
mod tools;
mod ui;
mod update;

pub use api::*;
pub use context::*;
pub use git::*;
pub use guardrails::*;
pub use memory::*;
pub use prompt_library::*;
pub use server::*;
pub use skills::*;
pub use tools::*;
pub use ui::*;
pub use update::*;

use serde::{Deserialize, Serialize};

/// Root settings type for the Tron agent.
///
/// Loaded from `~/.tron/profiles/default/settings/defaults.json`, then sparse
/// `~/.tron/profiles/user/settings.json`, with defaults applied for missing fields.
/// Environment variables can override specific values.
///
/// # JSON Format
///
/// All field names are camelCase. Optional sections (`guardrails`) are
/// omitted when `None`. Example:
///
/// ```json
/// {
///   "version": "0.1.0",
///   "name": "tron",
///   "server": { "heartbeatIntervalMs": 30000 }
/// }
/// ```
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default, deny_unknown_fields)]
pub struct TronSettings {
    /// Settings schema version.
    pub version: String,
    /// Application name.
    pub name: String,
    /// API provider settings (Anthropic, `OpenAI`, Google).
    pub api: ApiSettings,
    /// Retry configuration for API calls.
    pub retry: RetrySettings,
    /// Tool-specific settings.
    pub tools: ToolSettings,
    /// Context management settings (compaction, memory, rules, tasks).
    pub context: ContextSettings,
    /// Agent runtime settings (max turns, timeouts).
    pub agent: AgentRuntimeSettings,
    /// Logging configuration.
    pub logging: LoggingSettings,
    /// Hook system configuration.
    pub hooks: HookSettings,
    /// Server network settings.
    pub server: ServerSettings,
    /// Tmux integration settings.
    pub tmux: TmuxSettings,
    /// Session behavior settings.
    pub session: SessionSettings,
    /// UI/TUI appearance settings.
    pub ui: UiSettings,
    /// Skill system settings (compaction policy, index visibility).
    pub skills: SkillsSettings,
    /// Memory retention settings (auto-retain interval, model).
    pub memory: MemorySettings,
    /// Git workflow settings (sync, push, switch, finalize, conflict resolution).
    pub git: GitWorkflowSettings,
    /// Prompt Library settings (history capture + retention).
    pub prompt_library: PromptLibrarySettings,
    /// Optional guardrail safety rules.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub guardrails: Option<GuardrailSettings>,
    /// MCP (Model Context Protocol) server configuration.
    #[serde(default)]
    pub mcp: crate::mcp::types::McpSettings,
}

impl Default for TronSettings {
    fn default() -> Self {
        Self {
            version: "0.1.0".to_string(),
            name: "tron".to_string(),
            api: ApiSettings::default(),
            retry: RetrySettings::default(),
            tools: ToolSettings::default(),
            context: ContextSettings::default(),
            agent: AgentRuntimeSettings::default(),
            logging: LoggingSettings::default(),
            hooks: HookSettings::default(),
            server: ServerSettings::default(),
            tmux: TmuxSettings::default(),
            session: SessionSettings::default(),
            ui: UiSettings::default(),
            skills: SkillsSettings::default(),
            memory: MemorySettings::default(),
            git: GitWorkflowSettings::default(),
            prompt_library: PromptLibrarySettings::default(),
            guardrails: None,
            mcp: crate::mcp::types::McpSettings::default(),
        }
    }
}

impl TronSettings {
    /// Validate invariants that cannot be repaired safely.
    pub fn validate_strict(&self) -> crate::settings::Result<()> {
        self.server.validate_strict()
    }

    /// Clamp ratio fields to [0.0, 1.0] and correct invalid invariants.
    ///
    /// Called automatically during loading. Out-of-range values are clamped
    /// with a warning rather than rejected, so users get corrected behavior
    /// instead of a confusing error.
    pub fn validate(&mut self) {
        fn clamp_ratio(val: &mut f64, name: &str) {
            if *val < 0.0 || *val > 1.0 {
                let clamped = val.clamp(0.0, 1.0);
                tracing::warn!("{name} out of range ({val}), clamped to {clamped}");
                *val = clamped;
            }
        }

        fn clamp_option_ratio(val: &mut Option<f64>, name: &str) {
            if let Some(v) = val.as_mut() {
                clamp_ratio(v, name);
            }
        }

        let cs = &mut self.context.compactor;
        clamp_ratio(&mut cs.compaction_threshold, "compaction_threshold");
        clamp_option_ratio(&mut cs.trigger_token_threshold, "trigger_token_threshold");

        clamp_ratio(&mut self.retry.jitter_factor, "jitter_factor");

        let bash = &mut self.tools.bash;
        if bash.max_timeout_ms < bash.default_timeout_ms {
            tracing::warn!(
                "bash max_timeout_ms ({}) < default_timeout_ms ({}), correcting",
                bash.max_timeout_ms,
                bash.default_timeout_ms
            );
            bash.max_timeout_ms = bash.default_timeout_ms;
        }
    }
}

/// Retry configuration for API calls.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct RetrySettings {
    /// Maximum number of retry attempts.
    pub max_retries: u32,
    /// Base delay between retries in milliseconds.
    pub base_delay_ms: u64,
    /// Maximum delay between retries in milliseconds.
    pub max_delay_ms: u64,
    /// Jitter factor (0.0–1.0) applied to retry delays.
    pub jitter_factor: f64,
}

impl Default for RetrySettings {
    fn default() -> Self {
        // INVARIANT: retry defaults flow from a single source of truth in
        // `core::foundation::retry`, which is the module both settings and
        // the runtime retry executor consume. Changing a default here without
        // changing the constant (or vice versa) is a bug.
        Self {
            max_retries: crate::core::retry::DEFAULT_MAX_RETRIES,
            base_delay_ms: crate::core::retry::DEFAULT_BASE_DELAY_MS,
            max_delay_ms: crate::core::retry::DEFAULT_MAX_DELAY_MS,
            jitter_factor: crate::core::retry::DEFAULT_JITTER_FACTOR,
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
    fn default_settings_version() {
        let s = TronSettings::default();
        assert_eq!(s.version, "0.1.0");
        assert_eq!(s.name, "tron");
    }

    #[test]
    fn default_settings_serde_roundtrip() {
        let defaults = TronSettings::default();
        let json = serde_json::to_string(&defaults).unwrap();
        let back: TronSettings = serde_json::from_str(&json).unwrap();
        assert_eq!(back.version, defaults.version);
        assert_eq!(back.name, defaults.name);
        assert_eq!(
            back.server.heartbeat_interval_ms,
            defaults.server.heartbeat_interval_ms
        );
        assert_eq!(
            back.context.compactor.max_tokens,
            defaults.context.compactor.max_tokens
        );
    }

    #[test]
    fn default_settings_json_field_names() {
        let defaults = TronSettings::default();
        let json = serde_json::to_value(&defaults).unwrap();

        // Root fields are camelCase
        assert!(json.get("version").is_some());
        assert!(json.get("api").is_some());

        // Dead "models" key removed
        assert!(json.get("models").is_none());

        // Nested fields are camelCase
        let server = json.get("server").unwrap();
        assert!(server.get("heartbeatIntervalMs").is_some());
        assert!(server.get("defaultModel").is_some());
        assert!(server.get("codexAppServer").is_some());

        // Removed fields no longer present
        assert!(server.get("wsPort").is_none());
        assert!(server.get("healthPort").is_none());
        assert!(server.get("host").is_none());
        assert!(server.get("sessionTimeoutMs").is_none());
        assert!(server.get("tailscaleIp").is_none());
        assert!(server.get("anthropicAccount").is_none());

        // Optional sections omitted when None
        assert!(json.get("guardrails").is_none());
    }

    #[test]
    fn codex_app_server_defaults_are_server_owned() {
        let settings = TronSettings::default();
        let codex = settings.server.codex_app_server;
        assert!(codex.enabled);
        assert_eq!(codex.port, 4500);
        assert_eq!(codex.listen_url(), "ws://0.0.0.0:4500");
        assert_eq!(codex.approval_policy, CodexAppApprovalPolicy::OnRequest);
        assert_eq!(codex.sandbox_mode, CodexAppSandboxMode::WorkspaceWrite);
    }

    #[test]
    fn empty_json_produces_defaults() {
        let settings: TronSettings = serde_json::from_str("{}").unwrap();
        let defaults = TronSettings::default();
        assert_eq!(settings.version, defaults.version);
        assert_eq!(
            settings.server.heartbeat_interval_ms,
            defaults.server.heartbeat_interval_ms
        );
        assert_eq!(settings.retry.max_retries, defaults.retry.max_retries);
    }

    #[test]
    fn partial_json_overrides() {
        let json = serde_json::json!({
            "server": {
                "heartbeatIntervalMs": 20_000
            },
            "retry": {
                "maxRetries": 3
            }
        });
        let settings: TronSettings = serde_json::from_value(json).unwrap();
        assert_eq!(settings.server.heartbeat_interval_ms, 20_000);
        assert_eq!(settings.retry.max_retries, 3);
        assert_eq!(settings.retry.base_delay_ms, 1000);
        assert_eq!(settings.version, "0.1.0");
    }

    #[test]
    fn retry_defaults() {
        let r = RetrySettings::default();
        assert_eq!(r.max_retries, crate::core::retry::DEFAULT_MAX_RETRIES);
        assert_eq!(r.max_retries, 3);
        assert_eq!(r.base_delay_ms, 1000);
        assert_eq!(r.max_delay_ms, 60_000);
        assert!((r.jitter_factor - 0.2).abs() < f64::EPSILON);
    }

    #[test]
    fn retry_default_matches_retry_module_constant() {
        // The settings default MUST be the same value the runtime retry
        // executor uses. A divergence would mean the documented default
        // differs from the actual runtime default — users would see retries
        // happen N times when the settings file said M, and vice versa.
        let settings_r = RetrySettings::default();
        let runtime_r = crate::core::retry::RetryConfig::default();
        assert_eq!(settings_r.max_retries, runtime_r.max_retries);
        assert_eq!(settings_r.base_delay_ms, runtime_r.base_delay_ms);
        assert_eq!(settings_r.max_delay_ms, runtime_r.max_delay_ms);
        assert!((settings_r.jitter_factor - runtime_r.jitter_factor).abs() < f64::EPSILON);
    }

    #[test]
    fn retry_serde_camel_case() {
        let r = RetrySettings::default();
        let json = serde_json::to_value(&r).unwrap();
        assert!(json.get("maxRetries").is_some());
        assert!(json.get("baseDelayMs").is_some());
        assert!(json.get("maxDelayMs").is_some());
        assert!(json.get("jitterFactor").is_some());
    }

    #[test]
    fn settings_with_guardrails() {
        let json = serde_json::json!({
            "guardrails": {
                "audit": {
                    "enabled": true,
                    "maxEntries": 200
                }
            }
        });
        let settings: TronSettings = serde_json::from_value(json).unwrap();
        assert!(settings.guardrails.is_some());
        let g = settings.guardrails.unwrap();
        assert!(g.audit.is_some());
        assert_eq!(g.audit.unwrap().max_entries, 200);
    }

    // ── validate ───────────────────────────────────────────────────

    // ── QueueDrainMode ──────────────────────────────────────────

    #[test]
    fn queue_drain_mode_defaults_to_sequential() {
        let s = TronSettings::default();
        assert_eq!(s.session.queue_drain_mode, QueueDrainMode::Sequential);
    }

    #[test]
    fn queue_drain_mode_serde_roundtrip() {
        let json = serde_json::json!({
            "session": {
                "queueDrainMode": "batched"
            }
        });
        let settings: TronSettings = serde_json::from_value(json).unwrap();
        assert_eq!(settings.session.queue_drain_mode, QueueDrainMode::Batched);

        let serialized = serde_json::to_value(&settings).unwrap();
        assert_eq!(serialized["session"]["queueDrainMode"], "batched");
    }

    #[test]
    fn queue_drain_mode_sequential_from_json() {
        let json = serde_json::json!({
            "session": {
                "queueDrainMode": "sequential"
            }
        });
        let settings: TronSettings = serde_json::from_value(json).unwrap();
        assert_eq!(
            settings.session.queue_drain_mode,
            QueueDrainMode::Sequential
        );
    }

    #[test]
    fn queue_drain_mode_missing_uses_default() {
        let json = serde_json::json!({
            "session": {}
        });
        let settings: TronSettings = serde_json::from_value(json).unwrap();
        assert_eq!(
            settings.session.queue_drain_mode,
            QueueDrainMode::Sequential
        );
    }

    #[test]
    fn queue_drain_mode_camel_case_field_name() {
        let settings = TronSettings::default();
        let json = serde_json::to_value(&settings).unwrap();
        assert!(json["session"].get("queueDrainMode").is_some());
        // Verify it's NOT snake_case
        assert!(json["session"].get("queue_drain_mode").is_none());
    }

    // ── validate ───────────────────────────────────────────────

    #[test]
    fn validate_clamps_compaction_threshold() {
        let mut s = TronSettings::default();
        s.context.compactor.compaction_threshold = 5.0;
        s.validate();
        assert!((s.context.compactor.compaction_threshold - 1.0).abs() < f64::EPSILON);
    }

    #[test]
    fn validate_clamps_jitter_factor() {
        let mut s = TronSettings::default();
        s.retry.jitter_factor = 2.0;
        s.validate();
        assert!((s.retry.jitter_factor - 1.0).abs() < f64::EPSILON);
    }

    #[test]
    fn validate_clamps_trigger_token_threshold() {
        let mut s = TronSettings::default();
        s.context.compactor.trigger_token_threshold = Some(1.5);
        s.validate();
        assert_eq!(s.context.compactor.trigger_token_threshold, Some(1.0));
    }

    #[test]
    fn validate_corrects_bash_timeout_inversion() {
        let mut s = TronSettings::default();
        s.tools.bash.default_timeout_ms = 300_000;
        s.tools.bash.max_timeout_ms = 100_000;
        s.validate();
        assert_eq!(s.tools.bash.max_timeout_ms, 300_000);
    }

    #[test]
    fn validate_preserves_valid_values() {
        let mut s = TronSettings::default();
        let before_threshold = s.context.compactor.compaction_threshold;
        let before_jitter = s.retry.jitter_factor;
        let before_max = s.tools.bash.max_timeout_ms;
        s.validate();
        assert!((s.context.compactor.compaction_threshold - before_threshold).abs() < f64::EPSILON);
        assert!((s.retry.jitter_factor - before_jitter).abs() < f64::EPSILON);
        assert_eq!(s.tools.bash.max_timeout_ms, before_max);
    }

    #[test]
    fn prompt_library_defaults_are_applied() {
        let s = TronSettings::default();
        assert!(s.prompt_library.history_enabled);
        assert_eq!(s.prompt_library.history_max_entries, 10_000);
    }

    #[test]
    fn prompt_library_partial_override() {
        let json = serde_json::json!({
            "promptLibrary": { "historyEnabled": false }
        });
        let s: TronSettings = serde_json::from_value(json).unwrap();
        assert!(!s.prompt_library.history_enabled);
        assert_eq!(s.prompt_library.history_max_entries, 10_000);
    }

    #[test]
    fn prompt_library_camel_case_field_in_root() {
        let s = TronSettings::default();
        let json = serde_json::to_value(&s).unwrap();
        assert!(json.get("promptLibrary").is_some());
        assert!(json.get("prompt_library").is_none());
    }

    #[test]
    fn deeply_nested_partial_override() {
        let json = serde_json::json!({
            "context": {
                "compactor": {
                    "maxTokens": 50000
                }
            }
        });
        let settings: TronSettings = serde_json::from_value(json).unwrap();
        assert_eq!(settings.context.compactor.max_tokens, 50_000);
        // All other context fields should be defaults
        assert!(settings.context.rules.discover_standalone_files);
    }
}
