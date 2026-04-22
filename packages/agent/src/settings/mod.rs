//! # settings
//!
//! Configuration management with layered sources for the Tron agent.
//!
//! Settings are loaded from three layers (in priority order):
//! 1. **Compiled defaults** — [`TronSettings::default()`]
//! 2. **User file** — `~/.tron/system/settings.json` (deep-merged over defaults)
//! 3. **Environment variables** — `TRON_*` overrides (highest priority)
//!
//! Settings are server-authoritative: `~/.tron/system/settings.json` is the source
//! of truth. iOS reads/writes via `settings.get`/`settings.update` RPC methods.
//!
//! The global singleton is reloadable: when `settings.update` writes new
//! values to disk, [`reload_settings_from_path`] swaps the cached value
//! so all subsequent [`get_settings`] calls return fresh data.
//!
//! # Usage
//!
//! ```no_run
//! use crate::settings::{get_settings, TronSettings};
//!
//! let settings = get_settings();
//! println!("Default model: {}", settings.server.default_model);
//! ```
//!
//! ## Module Position
//!
//! Depends on: (none — standalone schema + loader).
//! Depended on by: events, runtime, server.

#![deny(unsafe_code)]

pub mod db_path_policy;
pub mod errors;
#[path = "storage/loader.rs"]
pub mod loader;
pub mod types;

pub use errors::{Result, SettingsError};
pub use loader::{
    deep_merge, deploy_dir, load_settings, load_settings_from_path, settings_path,
    tron_home_dir,
};
pub use types::*;

use std::path::Path;
use std::sync::{Arc, OnceLock};

use arc_swap::ArcSwapOption;

/// Global settings singleton (M31).
///
/// `ArcSwapOption<TronSettings>` is lock-free for readers: `get_settings()`
/// is a few atomic ops with no blocking, even while a reload is in flight.
/// Writers (reload / init) swap the new `Arc` atomically; readers with an
/// older `Arc` keep a consistent snapshot until they drop it. Exactly the
/// pattern `arc-swap` was designed for — a rarely-updated singleton read by
/// many hot paths (every RPC, every turn, every tool).
///
/// `OnceLock` defers allocation until first access; inside that slot we keep
/// the `ArcSwapOption` that carries the current value (or `None` until the
/// first load lands).
static SETTINGS: OnceLock<ArcSwapOption<TronSettings>> = OnceLock::new();

fn settings_slot() -> &'static ArcSwapOption<TronSettings> {
    SETTINGS.get_or_init(ArcSwapOption::empty)
}

/// Get the global settings instance.
///
/// On first call, loads settings from `~/.tron/system/settings.json` with env var
/// overrides. On subsequent calls, returns the cached value. If loading
/// fails, returns compiled defaults.
///
/// Returns an `Arc` so callers hold a consistent snapshot even if another
/// thread reloads settings concurrently. The underlying read is lock-free
/// (arc-swap) — hot-path callers (every RPC, every turn) pay only an atomic
/// load + `Arc` clone.
pub fn get_settings() -> Arc<TronSettings> {
    let slot = settings_slot();
    // Fast path: already initialized.
    if let Some(existing) = slot.load_full() {
        return existing;
    }

    // Slow path: compute defaults-or-file and install them. If two threads
    // race here, both will produce a valid Arc from the same deterministic
    // source (file or defaults) and one's store overwrites the other; both
    // return a valid snapshot. The loser's Arc is dropped. No lock involved.
    let fresh = Arc::new(match load_settings() {
        Ok(s) => s,
        Err(e) => {
            tracing::warn!(error = %e, "failed to load settings, using defaults");
            TronSettings::default()
        }
    });
    slot.store(Some(Arc::clone(&fresh)));
    fresh
}

/// Initialize the global settings with a specific value.
///
/// Replaces any previously cached settings. Useful for tests and
/// server startup where the settings path is known.
pub fn init_settings(settings: TronSettings) {
    settings_slot().store(Some(Arc::new(settings)));
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
    settings_slot().store(Some(new));
    tracing::debug!(?path, "settings reloaded from disk");
}

/// Reset the global settings cache (test-only).
///
/// Clears the cached value so the next [`get_settings`] call re-loads
/// from disk. This is needed because tests share a process and the
/// global is `static`.
#[cfg(test)]
pub(crate) fn reset_settings() {
    settings_slot().store(None);
}

/// Shared test-time lock for the global settings singleton.
///
/// Any test that mutates the global must hold this mutex for its whole
/// body to prevent races with other parallel tests. Since settings live
/// in a process-global, any parallel test that writes to it (directly
/// via `init_settings` or indirectly via RPC handlers like
/// `update_settings`) can corrupt a concurrent test's state unless they
/// all synchronize through a single lock.
///
/// Returns a `std::sync::Mutex` so it can be acquired from both sync
/// (`#[test]`) and async (`#[tokio::test]`) tests; tokio tests may hold
/// the lock briefly across `.await` points since contention is tiny.
#[cfg(test)]
pub(crate) fn test_settings_lock() -> &'static std::sync::Mutex<()> {
    use std::sync::OnceLock;
    static LOCK: OnceLock<std::sync::Mutex<()>> = OnceLock::new();
    LOCK.get_or_init(|| std::sync::Mutex::new(()))
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    /// Acquire the shared test-time settings lock. Poison-tolerant:
    /// if a prior test panicked while holding the lock, recover the
    /// inner guard rather than cascading panics to every sibling test.
    fn lock_settings() -> std::sync::MutexGuard<'static, ()> {
        test_settings_lock()
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

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
        assert_eq!(settings.version, "0.1.0");
        assert_eq!(settings.name, "tron");
        assert_eq!(settings.server.heartbeat_interval_ms, 30_000);
        assert_eq!(settings.server.default_provider, "anthropic");
        assert_eq!(settings.server.default_model, "claude-sonnet-4-6");
        assert_eq!(settings.retry.max_retries, 3);
        assert_eq!(settings.agent.max_turns, 250);
        assert_eq!(settings.tools.bash.default_timeout_ms, 120_000);
        assert_eq!(settings.context.compactor.max_tokens, 25_000);
        assert!(settings.guardrails.is_none());
    }

    #[test]
    fn init_settings_sets_custom_value() {
        let _lock = lock_settings();
        reset_settings();
        let mut custom = TronSettings::default();
        custom.server.heartbeat_interval_ms = 99_000;
        init_settings(custom);
        let s = get_settings();
        assert_eq!(s.server.heartbeat_interval_ms, 99_000);
        reset_settings();
    }

    #[test]
    fn init_settings_replaces_previous() {
        let _lock = lock_settings();
        reset_settings();
        let mut first = TronSettings::default();
        first.server.heartbeat_interval_ms = 11_000;
        init_settings(first);
        assert_eq!(get_settings().server.heartbeat_interval_ms, 11_000);

        let mut second = TronSettings::default();
        second.server.heartbeat_interval_ms = 22_000;
        init_settings(second);
        assert_eq!(get_settings().server.heartbeat_interval_ms, 22_000);
        reset_settings();
    }

    #[test]
    fn reload_settings_from_path_updates_cached_value() {
        let _lock = lock_settings();
        reset_settings();

        // Start with defaults
        init_settings(TronSettings::default());
        assert!(get_settings().context.rules.discover_standalone_files);

        // Write a settings file that disables standalone files discovery
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("settings.json");
        std::fs::write(
            &path,
            r#"{"context": {"rules": {"discoverStandaloneFiles": false}}}"#,
        )
        .unwrap();

        // Reload — should pick up the change
        reload_settings_from_path(&path);

        let updated = get_settings();
        assert!(
            !updated.context.rules.discover_standalone_files,
            "discover_standalone_files should be disabled after reload"
        );
        // Other defaults should be preserved (deep merge)
        assert_eq!(updated.server.heartbeat_interval_ms, 30_000);

        reset_settings();
    }

    #[test]
    fn reload_from_nonexistent_path_falls_back_to_defaults() {
        let _lock = lock_settings();
        reset_settings();

        let mut custom = TronSettings::default();
        custom.server.heartbeat_interval_ms = 77_000;
        init_settings(custom);
        assert_eq!(get_settings().server.heartbeat_interval_ms, 77_000);

        // Reload from a path that doesn't exist — should get defaults (not keep 77_000)
        reload_settings_from_path(Path::new("/nonexistent/settings.json"));

        let s = get_settings();
        assert_eq!(
            s.server.heartbeat_interval_ms, 30_000,
            "should fall back to defaults when file missing"
        );

        reset_settings();
    }

    #[test]
    fn reload_settings_simulates_settings_update_rpc_flow() {
        let _lock = lock_settings();
        reset_settings();

        // Simulate server startup: standalone files enabled by default
        init_settings(TronSettings::default());
        assert!(get_settings().context.rules.discover_standalone_files);

        // Simulate iOS settings.update: write merged settings to disk
        let dir = tempfile::tempdir().unwrap();
        let settings_path = dir.path().join("settings.json");

        // First: read current file (empty — new install)
        let current = serde_json::json!({});
        // Apply the update (standalone files disabled)
        let update = serde_json::json!({"context": {"rules": {"discoverStandaloneFiles": false}}});
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
            !get_settings().context.rules.discover_standalone_files,
            "after reload, discover_standalone_files should be disabled"
        );

        reset_settings();
    }

    #[test]
    fn get_settings_returns_arc_for_snapshot_isolation() {
        let _lock = lock_settings();
        reset_settings();
        init_settings(TronSettings::default());

        // Take a snapshot
        let snapshot = get_settings();
        assert_eq!(snapshot.server.heartbeat_interval_ms, 30_000);

        // Reload with different value
        let mut new = TronSettings::default();
        new.server.heartbeat_interval_ms = 55_000;
        init_settings(new);

        // Snapshot should still see old value (Arc isolation)
        assert_eq!(snapshot.server.heartbeat_interval_ms, 30_000);
        // New get should see new value
        assert_eq!(get_settings().server.heartbeat_interval_ms, 55_000);

        reset_settings();
    }

    // ── M31: ArcSwap lock-free semantics ────────────────────────────

    /// Readers concurrent with a reload must never observe a partially
    /// swapped value. Each `get_settings()` call returns either the old
    /// snapshot or the new one, never a torn mix. This is the core
    /// guarantee of `ArcSwapOption` vs the previous `RwLock` wrapping.
    #[test]
    fn in_flight_read_sees_consistent_snapshot_under_reload() {
        use std::thread;
        use std::time::{Duration, Instant};

        let _lock = lock_settings();
        reset_settings();

        let mut base = TronSettings::default();
        base.server.heartbeat_interval_ms = 10_000;
        init_settings(base);

        // Writer thread swaps between two distinct configurations for a
        // short window; reader threads pull snapshots on a tight loop and
        // assert every single one is one of the two known configurations.
        let done = Arc::new(std::sync::atomic::AtomicBool::new(false));
        let done_writer = Arc::clone(&done);
        let writer = thread::spawn(move || {
            let start = Instant::now();
            let mut flip = 0u8;
            while start.elapsed() < Duration::from_millis(80) {
                let mut s = TronSettings::default();
                s.server.heartbeat_interval_ms = if flip.is_multiple_of(2) { 10_000 } else { 20_000 };
                init_settings(s);
                flip = flip.wrapping_add(1);
            }
            done_writer.store(true, std::sync::atomic::Ordering::SeqCst);
        });

        let mut reader_handles = Vec::new();
        for _ in 0..4 {
            let done_reader = Arc::clone(&done);
            reader_handles.push(thread::spawn(move || {
                let mut observed_values = std::collections::BTreeSet::new();
                while !done_reader.load(std::sync::atomic::Ordering::SeqCst) {
                    let snap = get_settings();
                    let hb = snap.server.heartbeat_interval_ms;
                    assert!(
                        hb == 10_000 || hb == 20_000,
                        "reader observed torn value: {hb}"
                    );
                    observed_values.insert(hb);
                }
                // Each reader should have seen at least one value; both
                // are fine but tearing is the failure we guard against.
                assert!(!observed_values.is_empty());
            }));
        }

        writer.join().unwrap();
        for h in reader_handles {
            h.join().unwrap();
        }

        reset_settings();
    }

    /// A snapshot taken before a reload stays internally consistent even
    /// after many subsequent reloads — `ArcSwapOption` holds the old Arc
    /// alive as long as any reader holds it. Regression guard against a
    /// future refactor replacing `ArcSwap` with a `Mutex<TronSettings>`
    /// (which would require .lock() on every access and defeat the point).
    #[test]
    fn snapshot_remains_valid_across_many_reloads() {
        let _lock = lock_settings();
        reset_settings();

        let mut first = TronSettings::default();
        first.server.heartbeat_interval_ms = 33_333;
        init_settings(first);

        let held_snapshot = get_settings();
        assert_eq!(held_snapshot.server.heartbeat_interval_ms, 33_333);

        // Thrash the cache.
        for n in 0u64..32 {
            let mut s = TronSettings::default();
            s.server.heartbeat_interval_ms = 40_000 + n * 100;
            init_settings(s);
        }

        // Our originally-held snapshot is untouched.
        assert_eq!(held_snapshot.server.heartbeat_interval_ms, 33_333);
        reset_settings();
    }
}
