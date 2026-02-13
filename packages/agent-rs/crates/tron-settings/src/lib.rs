//! # tron-settings
//!
//! Configuration management with layered sources for the Tron agent.
//!
//! Settings are loaded from three layers (in priority order):
//! 1. **Compiled defaults** — [`TronSettings::default()`]
//! 2. **User file** — `~/.tron/settings.json` (deep-merged over defaults)
//! 3. **Environment variables** — `TRON_*` overrides (highest priority)
//!
//! Settings are server-authoritative: `~/.tron/settings.json` is the source
//! of truth. iOS reads/writes via `settings.get`/`settings.update` RPC methods.
//!
//! # Usage
//!
//! ```no_run
//! use tron_settings::{get_settings, TronSettings};
//!
//! let settings = get_settings();
//! println!("WebSocket port: {}", settings.server.ws_port);
//! ```

#![deny(unsafe_code)]

pub mod errors;
pub mod loader;
pub mod types;

pub use errors::{Result, SettingsError};
pub use loader::{deep_merge, load_settings, load_settings_from_path, settings_path};
pub use types::*;

use std::sync::OnceLock;

/// Global settings singleton.
///
/// Initialized on first access via [`get_settings`]. The settings are loaded
/// from `~/.tron/settings.json` with env var overrides, or fall back to
/// compiled defaults if loading fails.
static SETTINGS: OnceLock<TronSettings> = OnceLock::new();

/// Get the global settings instance.
///
/// On first call, loads settings from `~/.tron/settings.json` with env var
/// overrides. On subsequent calls, returns the cached value. If loading
/// fails, returns compiled defaults.
pub fn get_settings() -> &'static TronSettings {
    SETTINGS.get_or_init(|| load_settings().unwrap_or_default())
}

/// Initialize the global settings with a specific value.
///
/// Returns `Ok(())` if the settings were set, or `Err(settings)` if
/// they were already initialized.
///
/// # Errors
///
/// Returns the provided settings back if the global was already initialized.
#[allow(clippy::result_large_err)]
pub fn init_settings(settings: TronSettings) -> std::result::Result<(), TronSettings> {
    SETTINGS.set(settings)
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn re_exports_work() {
        // Verify that key types are accessible through the crate root
        let _settings = TronSettings::default();
        let _path = settings_path();
    }

    #[test]
    fn deep_merge_re_exported() {
        let a = serde_json::json!({"x": 1});
        let b = serde_json::json!({"y": 2});
        let merged = deep_merge(a, b);
        assert_eq!(merged["x"], 1);
        assert_eq!(merged["y"], 2);
    }

    #[test]
    fn default_settings_are_valid() {
        let settings = TronSettings::default();
        // Verify key defaults match TypeScript
        assert_eq!(settings.version, "0.1.0");
        assert_eq!(settings.name, "tron");
        assert_eq!(settings.server.ws_port, 8080);
        assert_eq!(settings.server.health_port, 8081);
        assert_eq!(settings.server.default_provider, "anthropic");
        assert_eq!(settings.server.default_model, "claude-opus-4-6");
        assert_eq!(settings.retry.max_retries, 1);
        assert_eq!(settings.agent.max_turns, 100);
        assert_eq!(settings.tools.bash.default_timeout_ms, 120_000);
        assert_eq!(settings.context.compactor.max_tokens, 25_000);
        assert!(settings.context.memory.embedding.enabled);
        assert!(settings.guardrails.is_none());
    }
}
