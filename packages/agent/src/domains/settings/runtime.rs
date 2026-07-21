//! Atomic runtime ownership for flat engine settings.
//!
//! [`SettingsRuntime`] loads one sparse `settings.toml` over compiled defaults,
//! applies explicit environment overrides, and publishes an immutable snapshot.
//! Reloads are all-or-previous: invalid edits never replace the last known-good
//! value held by running sessions.

use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use arc_swap::ArcSwap;
use sha2::{Digest, Sha256};
use tokio_util::sync::CancellationToken;

use super::TronSettings;

const SETTINGS_WATCH_INTERVAL: Duration = Duration::from_secs(2);

/// One immutable effective-settings snapshot.
#[derive(Clone, Debug)]
pub struct SettingsSnapshot {
    /// Effective validated settings.
    pub settings: TronSettings,
    /// Hash of the complete effective settings, including environment overrides.
    pub source_hash: String,
}

/// Sole live owner for effective engine settings.
pub struct SettingsRuntime {
    home: PathBuf,
    path: PathBuf,
    current: ArcSwap<SettingsSnapshot>,
}

impl SettingsRuntime {
    /// Load and validate settings for one Tron home.
    pub fn load(home: impl AsRef<Path>) -> std::io::Result<Self> {
        let home = home.as_ref().to_path_buf();
        let path = crate::shared::foundation::paths::settings_path_for_home(&home);
        let current = Arc::new(load_snapshot(&path)?);
        Ok(Self {
            home,
            path,
            current: ArcSwap::from(current),
        })
    }

    /// Tron home backing this runtime.
    #[must_use]
    pub fn home(&self) -> &Path {
        &self.home
    }

    /// Current valid immutable settings snapshot.
    #[must_use]
    pub fn current(&self) -> Arc<SettingsSnapshot> {
        self.current.load_full()
    }

    /// Reload and atomically swap only after complete validation succeeds.
    pub fn reload_now(&self, reason: &str) -> std::io::Result<Arc<SettingsSnapshot>> {
        match load_snapshot(&self.path) {
            Ok(next) => {
                let next = Arc::new(next);
                self.current.store(next.clone());
                tracing::info!(
                    reason,
                    settings_hash = next.source_hash,
                    "engine settings reloaded"
                );
                Ok(next)
            }
            Err(error) => {
                tracing::warn!(
                    reason,
                    error = %error,
                    "engine settings reload rejected; keeping previous valid snapshot"
                );
                Err(error)
            }
        }
    }

    /// Watch only the canonical settings file and reload changed content.
    #[must_use]
    pub fn spawn_watcher(
        self: Arc<Self>,
        cancel: CancellationToken,
    ) -> tokio::task::JoinHandle<()> {
        self.spawn_watcher_with_interval(cancel, SETTINGS_WATCH_INTERVAL)
    }

    #[must_use]
    fn spawn_watcher_with_interval(
        self: Arc<Self>,
        cancel: CancellationToken,
        interval: Duration,
    ) -> tokio::task::JoinHandle<()> {
        let initial_hash = file_hash(&self.path).ok();
        tokio::spawn(async move {
            self.watch_settings(cancel, interval, initial_hash).await;
        })
    }

    async fn watch_settings(
        self: Arc<Self>,
        cancel: CancellationToken,
        interval: Duration,
        mut last_hash: Option<String>,
    ) {
        let mut ticker = tokio::time::interval(interval);
        ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);

        loop {
            tokio::select! {
                () = cancel.cancelled() => break,
                _ = ticker.tick() => {
                    let next_hash = match file_hash(&self.path) {
                        Ok(hash) => hash,
                        Err(error) => {
                            tracing::warn!(error = %error, "engine settings watcher scan failed");
                            continue;
                        }
                    };
                    if last_hash.as_deref() == Some(next_hash.as_str()) {
                        continue;
                    }
                    last_hash = Some(next_hash);
                    if let Err(error) = self.reload_now("settings watcher") {
                        tracing::warn!(
                            error = %error,
                            "settings watcher observed an invalid edit; previous snapshot remains active"
                        );
                    }
                }
            }
        }
    }
}

fn load_snapshot(path: &Path) -> std::io::Result<SettingsSnapshot> {
    let settings = super::load_settings_from_path(path).map_err(std::io::Error::other)?;
    let encoded = serde_json::to_vec(&settings).map_err(std::io::Error::other)?;
    Ok(SettingsSnapshot {
        settings,
        source_hash: hex::encode(Sha256::digest(encoded)),
    })
}

fn file_hash(path: &Path) -> std::io::Result<String> {
    match std::fs::read(path) {
        Ok(bytes) => Ok(hex::encode(Sha256::digest(bytes))),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(String::new()),
        Err(error) => Err(error),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn seeded_runtime() -> (tempfile::TempDir, SettingsRuntime) {
        let dir = tempfile::tempdir().unwrap();
        let home = dir.path().join(".tron");
        crate::shared::foundation::constitution::ensure_tron_home_at(&home).unwrap();
        let runtime = SettingsRuntime::load(&home).unwrap();
        (dir, runtime)
    }

    #[test]
    fn missing_file_uses_compiled_defaults() {
        let (_dir, runtime) = seeded_runtime();
        let current = runtime.current();

        assert_eq!(current.settings.server.default_model, "claude-sonnet-4-6");
        assert!(!current.source_hash.is_empty());
        assert!(!runtime.path.exists());
    }

    #[test]
    fn invalid_reload_keeps_previous_snapshot() {
        let (_dir, runtime) = seeded_runtime();
        let before = runtime.current();
        std::fs::write(&runtime.path, "{broken").unwrap();

        let error = runtime.reload_now("test").unwrap_err();
        let after = runtime.current();

        assert!(error.to_string().contains("parse settings TOML"));
        assert!(Arc::ptr_eq(&before, &after));
    }

    #[test]
    fn reload_swaps_current_snapshot_and_preserves_held_value() {
        let (_dir, runtime) = seeded_runtime();
        let before = runtime.current();
        std::fs::write(
            &runtime.path,
            "[server]\ndefaultModel = \"reload-test-model\"\n",
        )
        .unwrap();

        let reloaded = runtime.reload_now("test").unwrap();

        assert_eq!(reloaded.settings.server.default_model, "reload-test-model");
        assert_eq!(
            runtime.current().settings.server.default_model,
            "reload-test-model"
        );
        assert_eq!(before.settings.server.default_model, "claude-sonnet-4-6");
        assert!(!Arc::ptr_eq(&before, &reloaded));
    }

    #[tokio::test]
    async fn watcher_reloads_valid_settings_edits() {
        let dir = tempfile::tempdir().unwrap();
        let home = dir.path().join(".tron");
        crate::shared::foundation::constitution::ensure_tron_home_at(&home).unwrap();
        let runtime = Arc::new(SettingsRuntime::load(&home).unwrap());
        let cancel = CancellationToken::new();
        let handle = runtime
            .clone()
            .spawn_watcher_with_interval(cancel.clone(), Duration::from_millis(20));

        std::fs::write(
            &runtime.path,
            "[server]\ndefaultModel = \"watcher-test-model\"\n",
        )
        .unwrap();

        tokio::time::timeout(Duration::from_secs(2), async {
            loop {
                if runtime.current().settings.server.default_model == "watcher-test-model" {
                    break;
                }
                tokio::time::sleep(Duration::from_millis(20)).await;
            }
        })
        .await
        .expect("watcher should reload a valid settings edit");

        cancel.cancel();
        handle.await.unwrap();
    }
}
