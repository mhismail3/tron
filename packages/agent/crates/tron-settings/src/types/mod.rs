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
    /// Default model selection.
    pub models: ModelSettings,
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
            models: ModelSettings::default(),
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

/// Default model selection.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ModelSettings {
    /// Default model for main conversations.
    #[serde(rename = "default")]
    pub default_model: String,
    /// Default model for skill sub-agents.
    pub subagent: String,
}

impl Default for ModelSettings {
    fn default() -> Self {
        Self {
            default_model: "claude-opus-4-6".to_string(),
            subagent: "claude-haiku-4-5-20251001".to_string(),
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
        assert!(json.get("models").is_some());

        // Nested fields are camelCase
        let server = json.get("server").unwrap();
        assert!(server.get("wsPort").is_some());
        assert!(server.get("healthPort").is_some());

        // Optional sections omitted when None
        assert!(json.get("guardrails").is_none());
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
    fn model_settings_default_field_name() {
        let m = ModelSettings::default();
        let json = serde_json::to_value(&m).unwrap();
        // The field should serialize as "default" (not "defaultModel")
        assert_eq!(json["default"], "claude-opus-4-6");
        assert_eq!(json["subagent"], "claude-haiku-4-5-20251001");
    }

    #[test]
    fn model_settings_deserialize_default_field() {
        let json = serde_json::json!({
            "default": "claude-sonnet-4-5-20250929",
            "subagent": "claude-haiku-4-5-20251001"
        });
        let m: ModelSettings = serde_json::from_value(json).unwrap();
        assert_eq!(m.default_model, "claude-sonnet-4-5-20250929");
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
