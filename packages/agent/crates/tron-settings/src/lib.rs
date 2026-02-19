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
//! The global singleton is reloadable: when `settings.update` writes new
//! values to disk, [`reload_settings_from_path`] swaps the cached value
//! so all subsequent [`get_settings`] calls return fresh data.
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

use std::path::Path;
use std::sync::{Arc, RwLock};

/// Global settings singleton.
///
/// Uses `RwLock<Option<Arc<TronSettings>>>` instead of `OnceLock` so the
/// cached value can be swapped after `settings.update` RPC calls.
/// Reads are cheap (shared lock + `Arc::clone`), writes only happen on
/// reload which is rare (settings changes from iOS).
static SETTINGS: RwLock<Option<Arc<TronSettings>>> = RwLock::new(None);

/// Get the global settings instance.
///
/// On first call, loads settings from `~/.tron/settings.json` with env var
/// overrides. On subsequent calls, returns the cached value. If loading
/// fails, returns compiled defaults.
///
/// Returns an `Arc` so callers can hold a consistent snapshot even if
/// another thread reloads settings concurrently.
pub fn get_settings() -> Arc<TronSettings> {
    // Fast path: read lock
    {
        let guard = SETTINGS.read().expect("settings lock poisoned");
        if let Some(ref s) = *guard {
            return Arc::clone(s);
        }
    }

    // Slow path: first access, take write lock
    let mut guard = SETTINGS.write().expect("settings lock poisoned");
    // Double-check after acquiring write lock (another thread may have initialized)
    if let Some(ref s) = *guard {
        return Arc::clone(s);
    }

    let settings = Arc::new(match load_settings() {
        Ok(s) => s,
        Err(e) => {
            tracing::warn!(error = %e, "failed to load settings, using defaults");
            TronSettings::default()
        }
    });
    *guard = Some(Arc::clone(&settings));
    settings
}

/// Initialize the global settings with a specific value.
///
/// Replaces any previously cached settings. Useful for tests and
/// server startup where the settings path is known.
pub fn init_settings(settings: TronSettings) {
    let mut guard = SETTINGS.write().expect("settings lock poisoned");
    *guard = Some(Arc::new(settings));
}

/// Reload settings from a specific file path.
///
/// Reads the file, deep-merges over defaults, applies env overrides,
/// and atomically swaps the global cache. All subsequent [`get_settings`]
/// calls return the new values.
///
/// Called by `UpdateSettingsHandler` after writing to `settings.json`.
pub fn reload_settings_from_path(path: &Path) {
    let new = Arc::new(match load_settings_from_path(path) {
        Ok(s) => s,
        Err(e) => {
            tracing::warn!(error = %e, ?path, "failed to reload settings, falling back to defaults");
            TronSettings::default()
        }
    });
    let mut guard = SETTINGS.write().expect("settings lock poisoned");
    *guard = Some(new);
    tracing::info!(?path, "settings reloaded from disk");
}

/// Reset the global settings cache (test-only).
///
/// Clears the cached value so the next [`get_settings`] call re-loads
/// from disk. This is needed because tests share a process and the
/// global is `static`.
#[cfg(test)]
pub(crate) fn reset_settings() {
    let mut guard = SETTINGS.write().expect("settings lock poisoned");
    *guard = None;
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    /// Tests that mutate the global SETTINGS static must hold this lock
    /// to avoid racing with each other (Rust runs tests in parallel threads).
    static SETTINGS_MUTEX: std::sync::Mutex<()> = std::sync::Mutex::new(());

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
        assert_eq!(settings.server.default_model, "claude-sonnet-4-20250514");
        assert_eq!(settings.retry.max_retries, 1);
        assert_eq!(settings.agent.max_turns, 100);
        assert_eq!(settings.tools.bash.default_timeout_ms, 120_000);
        assert_eq!(settings.context.compactor.max_tokens, 25_000);
        assert!(settings.context.memory.embedding.enabled);
        assert!(settings.guardrails.is_none());
    }

    #[test]
    fn init_settings_sets_custom_value() {
        let _lock = SETTINGS_MUTEX.lock().unwrap();
        reset_settings();
        let mut custom = TronSettings::default();
        custom.server.ws_port = 9999;
        init_settings(custom);
        let s = get_settings();
        assert_eq!(s.server.ws_port, 9999);
        reset_settings();
    }

    #[test]
    fn init_settings_replaces_previous() {
        let _lock = SETTINGS_MUTEX.lock().unwrap();
        reset_settings();
        let mut first = TronSettings::default();
        first.server.ws_port = 1111;
        init_settings(first);
        assert_eq!(get_settings().server.ws_port, 1111);

        let mut second = TronSettings::default();
        second.server.ws_port = 2222;
        init_settings(second);
        assert_eq!(get_settings().server.ws_port, 2222);
        reset_settings();
    }

    #[test]
    fn reload_settings_from_path_updates_cached_value() {
        let _lock = SETTINGS_MUTEX.lock().unwrap();
        reset_settings();

        // Start with defaults
        init_settings(TronSettings::default());
        assert!(get_settings().context.memory.auto_inject.enabled);

        // Write a settings file that disables auto-inject
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("settings.json");
        std::fs::write(
            &path,
            r#"{"context": {"memory": {"autoInject": {"enabled": false}}}}"#,
        )
        .unwrap();

        // Reload — should pick up the change
        reload_settings_from_path(&path);

        let updated = get_settings();
        assert!(
            !updated.context.memory.auto_inject.enabled,
            "auto_inject should be disabled after reload"
        );
        // Other defaults should be preserved (deep merge)
        assert!(updated.context.memory.embedding.enabled);
        assert_eq!(updated.server.ws_port, 8080);

        reset_settings();
    }

    #[test]
    fn reload_from_nonexistent_path_falls_back_to_defaults() {
        let _lock = SETTINGS_MUTEX.lock().unwrap();
        reset_settings();

        let mut custom = TronSettings::default();
        custom.server.ws_port = 7777;
        init_settings(custom);
        assert_eq!(get_settings().server.ws_port, 7777);

        // Reload from a path that doesn't exist — should get defaults (not keep 7777)
        reload_settings_from_path(Path::new("/nonexistent/settings.json"));

        let s = get_settings();
        assert_eq!(
            s.server.ws_port, 8080,
            "should fall back to defaults when file missing"
        );

        reset_settings();
    }

    #[test]
    fn reload_settings_simulates_settings_update_rpc_flow() {
        let _lock = SETTINGS_MUTEX.lock().unwrap();
        reset_settings();

        // Simulate server startup: auto-inject enabled by default
        init_settings(TronSettings::default());
        assert!(get_settings().context.memory.auto_inject.enabled);

        // Simulate iOS settings.update: write merged settings to disk
        let dir = tempfile::tempdir().unwrap();
        let settings_path = dir.path().join("settings.json");

        // First: read current file (empty — new install)
        let current = serde_json::json!({});
        // Apply the update (auto-inject disabled)
        let update = serde_json::json!({"context": {"memory": {"autoInject": {"enabled": false}}}});
        let merged = deep_merge(current, update);
        std::fs::write(
            &settings_path,
            serde_json::to_string_pretty(&merged).unwrap(),
        )
        .unwrap();

        // Reload (what UpdateSettingsHandler should do)
        reload_settings_from_path(&settings_path);

        // Now get_settings should reflect the iOS toggle
        assert!(
            !get_settings().context.memory.auto_inject.enabled,
            "after reload, auto_inject should be disabled"
        );

        reset_settings();
    }

    #[test]
    fn get_settings_returns_arc_for_snapshot_isolation() {
        let _lock = SETTINGS_MUTEX.lock().unwrap();
        reset_settings();
        init_settings(TronSettings::default());

        // Take a snapshot
        let snapshot = get_settings();
        assert_eq!(snapshot.server.ws_port, 8080);

        // Reload with different value
        let mut new = TronSettings::default();
        new.server.ws_port = 5555;
        init_settings(new);

        // Snapshot should still see old value (Arc isolation)
        assert_eq!(snapshot.server.ws_port, 8080);
        // New get should see new value
        assert_eq!(get_settings().server.ws_port, 5555);

        reset_settings();
    }
}
