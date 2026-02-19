//! Settings type definitions.
//!
//! All types use `#[serde(rename_all = "camelCase")]` to match the TypeScript
//! JSON wire format. Each type implements [`Default`] with production default
//! values. Types marked with `#[serde(default)]` allow partial JSON — missing
//! fields get their default value during deserialization.

mod api;
mod context;
mod guardrails;
mod server;
mod tools;
mod ui;

pub use api::*;
pub use context::*;
pub use guardrails::*;
pub use server::*;
pub use tools::*;
pub use ui::*;

use serde::{Deserialize, Serialize};

/// Root settings type for the Tron agent.
///
/// Loaded from `~/.tron/settings.json` with defaults applied for
/// missing fields. Environment variables can override specific values.
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
///   "server": { "wsPort": 9090 }
/// }
/// ```
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
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
    /// Optional guardrail safety rules.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub guardrails: Option<GuardrailSettings>,
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
            guardrails: None,
        }
    }
}

impl TronSettings {
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
        clamp_ratio(&mut cs.preserve_ratio, "preserve_ratio");
        clamp_option_ratio(&mut cs.trigger_token_threshold, "trigger_token_threshold");
        clamp_option_ratio(&mut cs.alert_zone_threshold, "alert_zone_threshold");

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
        Self {
            max_retries: 1,
            base_delay_ms: 1000,
            max_delay_ms: 60_000,
            jitter_factor: 0.2,
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
        assert_eq!(back.server.ws_port, defaults.server.ws_port);
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
        assert!(server.get("wsPort").is_some());
        assert!(server.get("healthPort").is_some());

        // Optional sections omitted when None
        assert!(json.get("guardrails").is_none());
    }

    #[test]
    fn legacy_models_key_silently_ignored() {
        let json = serde_json::json!({
            "models": {
                "default": "claude-opus-4-6",
                "subagent": "claude-haiku-4-5-20251001"
            }
        });
        let settings: TronSettings = serde_json::from_value(json).unwrap();
        // Should deserialize without error, models key ignored
        assert_eq!(settings.version, "0.1.0");
    }

    #[test]
    fn empty_json_produces_defaults() {
        let settings: TronSettings = serde_json::from_str("{}").unwrap();
        let defaults = TronSettings::default();
        assert_eq!(settings.version, defaults.version);
        assert_eq!(settings.server.ws_port, defaults.server.ws_port);
        assert_eq!(settings.retry.max_retries, defaults.retry.max_retries);
    }

    #[test]
    fn partial_json_overrides() {
        let json = serde_json::json!({
            "server": {
                "wsPort": 9090
            },
            "retry": {
                "maxRetries": 3
            }
        });
        let settings: TronSettings = serde_json::from_value(json).unwrap();
        assert_eq!(settings.server.ws_port, 9090);
        assert_eq!(settings.retry.max_retries, 3);
        // Unset fields should be defaults
        assert_eq!(settings.server.health_port, 8081);
        assert_eq!(settings.retry.base_delay_ms, 1000);
        assert_eq!(settings.version, "0.1.0");
    }

    #[test]
    fn retry_defaults() {
        let r = RetrySettings::default();
        assert_eq!(r.max_retries, 1);
        assert_eq!(r.base_delay_ms, 1000);
        assert_eq!(r.max_delay_ms, 60_000);
        assert!((r.jitter_factor - 0.2).abs() < f64::EPSILON);
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

    #[test]
    fn validate_clamps_compaction_threshold() {
        let mut s = TronSettings::default();
        s.context.compactor.compaction_threshold = 5.0;
        s.validate();
        assert!((s.context.compactor.compaction_threshold - 1.0).abs() < f64::EPSILON);
    }

    #[test]
    fn validate_clamps_preserve_ratio() {
        let mut s = TronSettings::default();
        s.context.compactor.preserve_ratio = -0.5;
        s.validate();
        assert!((s.context.compactor.preserve_ratio - 0.0).abs() < f64::EPSILON);
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
    fn validate_clamps_alert_zone_threshold() {
        let mut s = TronSettings::default();
        s.context.compactor.alert_zone_threshold = Some(-0.1);
        s.validate();
        assert_eq!(s.context.compactor.alert_zone_threshold, Some(0.0));
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
    fn deeply_nested_partial_override() {
        let json = serde_json::json!({
            "context": {
                "memory": {
                    "embedding": {
                        "dimensions": 1024
                    }
                }
            }
        });
        let settings: TronSettings = serde_json::from_value(json).unwrap();
        assert_eq!(settings.context.memory.embedding.dimensions, 1024);
        // All other embedding fields should be defaults
        assert!(settings.context.memory.embedding.enabled);
        assert_eq!(settings.context.memory.embedding.dtype, "q4");
        // All other context fields should be defaults
        assert_eq!(settings.context.compactor.max_tokens, 25_000);
    }
}
