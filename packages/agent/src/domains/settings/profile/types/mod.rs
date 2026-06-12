//! Settings type definitions.
//!
//! All types use `#[serde(rename_all = "camelCase")]` to match the TypeScript
//! JSON wire format. Each type implements [`Default`] with the emergency
//! default values that must stay in parity with the bundled default profile's
//! `[settings]` table. Types marked with `#[serde(default)]` allow partial JSON:
//! missing fields get their default value during deserialization. Root and
//! nested settings structs deny unknown fields so stale profile keys cannot
//! drift silently.

mod api;
mod context;
mod server;
mod ui;

pub use api::*;
pub use context::*;
pub use server::*;
pub use ui::*;

use serde::{Deserialize, Serialize};

/// Root settings type for the Tron agent.
///
/// Loaded from the active profile's `[settings]`, then sparse
/// `~/.tron/profiles/user/profile.toml` `[settings]`, with defaults applied for missing fields.
/// Only the explicit settings environment variables in the loader can override
/// specific values.
///
/// # JSON Format
///
/// All field names are camelCase. Example:
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
    /// Context management settings for compacting the primitive prompt loop.
    pub context: ContextSettings,
    /// Agent runtime settings (max turns, timeouts).
    pub agent: AgentRuntimeSettings,
    /// Logging configuration.
    pub logging: LoggingSettings,
    /// Engine observability and payload-capture settings.
    pub observability: ObservabilitySettings,
    /// Unified storage retention and size settings.
    pub storage: StorageSettings,
    /// Server network settings.
    pub server: ServerSettings,
    /// Tmux integration settings.
    pub tmux: TmuxSettings,
    /// Session behavior settings.
    pub session: SessionSettings,
    /// UI/TUI appearance settings.
    pub ui: UiSettings,
}

impl Default for TronSettings {
    fn default() -> Self {
        Self {
            version: "0.1.0".to_string(),
            name: "tron".to_string(),
            api: ApiSettings::default(),
            retry: RetrySettings::default(),
            context: ContextSettings::default(),
            agent: AgentRuntimeSettings::default(),
            logging: LoggingSettings::default(),
            observability: ObservabilitySettings::default(),
            storage: StorageSettings::default(),
            server: ServerSettings::default(),
            tmux: TmuxSettings::default(),
            session: SessionSettings::default(),
            ui: UiSettings::default(),
        }
    }
}

impl TronSettings {
    /// Validate invariants that cannot be repaired safely.
    pub fn validate_strict(&self) -> crate::domains::settings::Result<()> {
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
    }
}

/// Retry configuration for API calls.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default, deny_unknown_fields)]
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
            max_retries: crate::shared::foundation::retry::DEFAULT_MAX_RETRIES,
            base_delay_ms: crate::shared::foundation::retry::DEFAULT_BASE_DELAY_MS,
            max_delay_ms: crate::shared::foundation::retry::DEFAULT_MAX_DELAY_MS,
            jitter_factor: crate::shared::foundation::retry::DEFAULT_JITTER_FACTOR,
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

        // Removed fields no longer present
        assert!(server.get("wsPort").is_none());
        assert!(server.get("healthPort").is_none());
        assert!(server.get("host").is_none());
        assert!(server.get("sessionTimeoutMs").is_none());
        assert!(server.get("tailscaleIp").is_none());
        assert!(server.get("anthropicAccount").is_none());

        let removed_policy_key = ["guard", "rails"].concat();
        assert!(json.get(&removed_policy_key).is_none());
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
        assert_eq!(
            r.max_retries,
            crate::shared::foundation::retry::DEFAULT_MAX_RETRIES
        );
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
        let runtime_r = crate::shared::foundation::retry::RetryConfig::default();
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
    fn settings_reject_removed_policy_section() {
        let removed_policy_key = ["guard", "rails"].concat();
        let json = serde_json::json!({
            removed_policy_key.clone(): {
                "audit": {
                    "enabled": true,
                    "maxEntries": 200
                }
            }
        });
        let err = serde_json::from_value::<TronSettings>(json).unwrap_err();

        assert!(err.to_string().contains(&removed_policy_key));
    }

    // ── validate ───────────────────────────────────────────────────

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
    fn validate_preserves_valid_values() {
        let mut s = TronSettings::default();
        let before_threshold = s.context.compactor.compaction_threshold;
        let before_jitter = s.retry.jitter_factor;
        s.validate();
        assert!((s.context.compactor.compaction_threshold - before_threshold).abs() < f64::EPSILON);
        assert!((s.retry.jitter_factor - before_jitter).abs() < f64::EPSILON);
    }

    #[test]
    fn settings_reject_removed_prompt_store_section() {
        let removed_prompt_key = ["prompt", "Library"].concat();
        let json = serde_json::json!({
            removed_prompt_key.clone(): { "historyEnabled": false }
        });
        let err = serde_json::from_value::<TronSettings>(json).unwrap_err();

        assert!(err.to_string().contains(&removed_prompt_key));
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
    }

    #[test]
    fn retry_unknown_field_rejected() {
        let json = serde_json::json!({
            "maxRetries": 3,
            "legacyBackoffMode": "linear"
        });
        let err = serde_json::from_value::<RetrySettings>(json).unwrap_err();
        assert!(err.to_string().contains("legacyBackoffMode"));
    }
}
