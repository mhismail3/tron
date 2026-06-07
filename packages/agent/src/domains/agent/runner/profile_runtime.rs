//! Primitive profile runtime service.
//!
//! [`ProfileRuntime`] keeps the latest valid profile settings/auth snapshot in
//! an atomic value. Reloads are all-or-previous: invalid profile edits are
//! reported and the last known-good snapshot remains active.

use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use arc_swap::ArcSwap;
use sha2::{Digest, Sha256};
use tokio_util::sync::CancellationToken;
use walkdir::WalkDir;

use crate::domains::settings::types::TronSettings;
use crate::shared::profile::{AgentExecutionSpec, ResolvedProfile};

const PROFILE_WATCH_INTERVAL: Duration = Duration::from_secs(2);

/// Current compiled profile snapshot.
#[derive(Clone, Debug)]
pub struct ResolvedHarnessSpec {
    /// Tron home this spec was compiled from.
    pub home: PathBuf,
    /// Resolved active profile.
    pub profile: Arc<ResolvedProfile>,
    /// Effective settings from the compiled profile.
    pub settings: TronSettings,
}

impl ResolvedHarnessSpec {
    /// Active profile name.
    #[must_use]
    pub fn profile_name(&self) -> &str {
        &self.profile.name
    }

    /// Spec hash used by audit records.
    #[must_use]
    pub fn spec_hash(&self) -> &str {
        &self.profile.spec_hash
    }

    /// Compiled execution spec.
    #[must_use]
    pub fn execution_spec(&self) -> &AgentExecutionSpec {
        &self.profile.spec
    }
}

/// Atomic owner for the current compiled profile runtime.
pub struct ProfileRuntime {
    home: PathBuf,
    current: ArcSwap<ResolvedHarnessSpec>,
}

impl ProfileRuntime {
    /// Load and validate the active profile runtime from a Tron home.
    pub fn load(home: impl AsRef<Path>) -> std::io::Result<Self> {
        let home = home.as_ref().to_path_buf();
        let current = Arc::new(load_harness_spec(&home)?);
        Ok(Self {
            home,
            current: ArcSwap::from(current),
        })
    }

    /// Tron home backing this runtime.
    #[must_use]
    pub fn home(&self) -> &Path {
        &self.home
    }

    /// Current valid compiled spec. Running sessions should keep this Arc as
    /// their snapshot.
    #[must_use]
    pub fn current(&self) -> Arc<ResolvedHarnessSpec> {
        self.current.load_full()
    }

    /// Recompile the active profile and swap it in only if validation succeeds.
    pub fn reload_now(&self, reason: &str) -> std::io::Result<Arc<ResolvedHarnessSpec>> {
        match load_harness_spec(&self.home) {
            Ok(next) => {
                let next = Arc::new(next);
                self.current.store(next.clone());
                crate::domains::settings::init_settings(next.settings.clone());
                tracing::info!(
                    reason,
                    profile = next.profile_name(),
                    spec_hash = next.spec_hash(),
                    "profile runtime reloaded"
                );
                Ok(next)
            }
            Err(error) => {
                tracing::warn!(
                    reason,
                    error = %error,
                    "profile runtime reload rejected; keeping previous valid spec"
                );
                Err(error)
            }
        }
    }

    /// Spawn a lightweight profile watcher.
    ///
    /// The watcher hashes canonical profile TOML files and reloads through the
    /// same strict compiler used at startup. Invalid edits are rejected and the
    /// last valid snapshot remains active.
    #[must_use]
    pub fn spawn_watcher(
        self: Arc<Self>,
        cancel: CancellationToken,
    ) -> tokio::task::JoinHandle<()> {
        self.spawn_watcher_with_interval(cancel, PROFILE_WATCH_INTERVAL)
    }

    #[must_use]
    fn spawn_watcher_with_interval(
        self: Arc<Self>,
        cancel: CancellationToken,
        interval: Duration,
    ) -> tokio::task::JoinHandle<()> {
        let initial_hash = match profile_tree_hash(&self.home) {
            Ok(hash) => Some(hash),
            Err(error) => {
                tracing::warn!(error = %error, "profile watcher could not hash initial profile tree");
                None
            }
        };
        tokio::spawn(async move {
            self.watch_profiles(cancel, interval, initial_hash).await;
        })
    }

    async fn watch_profiles(
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
                    let next_hash = match profile_tree_hash(&self.home) {
                        Ok(hash) => hash,
                        Err(error) => {
                            tracing::warn!(error = %error, "profile watcher scan failed");
                            continue;
                        }
                    };
                    if last_hash.as_deref() == Some(next_hash.as_str()) {
                        continue;
                    }
                    last_hash = Some(next_hash);
                    if let Err(error) = self.reload_now("profile watcher") {
                        tracing::warn!(
                            error = %error,
                            "profile watcher observed an invalid edit; previous profile runtime remains active"
                        );
                    }
                }
            }
        }
    }
}

fn profile_tree_hash(home: &Path) -> std::io::Result<String> {
    let profiles_dir = home.join(crate::shared::paths::dirs::PROFILES);
    let mut files = Vec::new();
    if !profiles_dir.exists() {
        return Ok(String::new());
    }
    for entry in WalkDir::new(&profiles_dir).follow_links(false) {
        let entry = entry.map_err(std::io::Error::other)?;
        if !entry.file_type().is_file() {
            continue;
        }
        let path = entry.path();
        if path.file_name().and_then(|name| name.to_str())
            == Some(crate::shared::paths::files::AUTH_JSON)
        {
            continue;
        }
        let Some(extension) = path.extension().and_then(|extension| extension.to_str()) else {
            continue;
        };
        if !matches!(extension, "toml" | "md") {
            continue;
        }
        files.push(path.to_path_buf());
    }
    files.sort();

    let mut hasher = Sha256::new();
    for path in files {
        let relative = path.strip_prefix(&profiles_dir).unwrap_or(&path);
        hasher.update(relative.to_string_lossy().as_bytes());
        hasher.update([0]);
        hasher.update(std::fs::read(&path)?);
        hasher.update([0]);
    }
    let digest = hasher.finalize();
    Ok(digest.iter().map(|byte| format!("{byte:02x}")).collect())
}

fn load_harness_spec(home: &Path) -> std::io::Result<ResolvedHarnessSpec> {
    let profile = Arc::new(crate::shared::profile::resolve_active_profile_at(home)?);
    let settings = effective_settings(profile.spec.settings())?;
    Ok(ResolvedHarnessSpec {
        home: home.to_path_buf(),
        profile,
        settings,
    })
}

fn effective_settings(settings: &TronSettings) -> std::io::Result<TronSettings> {
    let mut settings = settings.clone();
    crate::domains::settings::loader::apply_env_overrides(&mut settings);
    settings.validate();
    settings.validate_strict().map_err(|error| {
        std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            format!("profile settings are invalid after environment overrides: {error}"),
        )
    })?;
    Ok(settings)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::shared::profile::NORMAL_PROFILE;

    fn seeded_runtime() -> (tempfile::TempDir, ProfileRuntime) {
        let dir = tempfile::tempdir().unwrap();
        let home = dir.path().join(".tron");
        crate::shared::constitution::ensure_tron_home_at(&home).unwrap();
        let runtime = ProfileRuntime::load(&home).unwrap();
        (dir, runtime)
    }

    #[test]
    fn current_returns_compiled_active_profile() {
        let (_dir, runtime) = seeded_runtime();
        let current = runtime.current();

        assert_eq!(current.profile_name(), NORMAL_PROFILE);
        assert_eq!(current.settings.server.default_provider, "anthropic");
        assert_eq!(current.execution_spec().auth_profile, "default");
        assert!(current.execution_spec().auth_registry.is_some());
    }

    #[test]
    fn invalid_reload_keeps_previous_spec() {
        let (_dir, runtime) = seeded_runtime();
        let before = runtime.current();
        let profile_path = runtime
            .home()
            .join(crate::shared::paths::dirs::PROFILES)
            .join(NORMAL_PROFILE)
            .join(crate::shared::paths::files::PROFILE_TOML);
        std::fs::write(&profile_path, "{broken").unwrap();

        let error = runtime.reload_now("test").unwrap_err();
        let after = runtime.current();

        assert!(error.to_string().contains("invalid TOML"));
        assert!(Arc::ptr_eq(&before, &after));
    }

    #[test]
    fn reload_updates_global_settings_snapshot() {
        let _settings_guard = crate::domains::settings::test_settings_lock()
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        crate::domains::settings::reset_settings();
        let (_dir, runtime) = seeded_runtime();
        crate::domains::settings::init_settings(runtime.current().settings.clone());
        let profile_path = runtime
            .home()
            .join(crate::shared::paths::dirs::PROFILES)
            .join(NORMAL_PROFILE)
            .join(crate::shared::paths::files::PROFILE_TOML);
        let mut profile = std::fs::read_to_string(&profile_path).unwrap();
        profile.push_str("\n[settings.server]\ndefaultModel = \"reload-test-model\"\n");
        std::fs::write(&profile_path, profile).unwrap();

        runtime.reload_now("test").unwrap();

        assert_eq!(
            crate::domains::settings::get_settings()
                .server
                .default_model,
            "reload-test-model"
        );
        crate::domains::settings::reset_settings();
    }

    #[tokio::test]
    async fn watcher_reloads_valid_profile_edits() {
        let _settings_guard = crate::domains::settings::test_settings_lock()
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        crate::domains::settings::reset_settings();
        let dir = tempfile::tempdir().unwrap();
        let home = dir.path().join(".tron");
        crate::shared::constitution::ensure_tron_home_at(&home).unwrap();
        let runtime = Arc::new(ProfileRuntime::load(&home).unwrap());
        crate::domains::settings::init_settings(runtime.current().settings.clone());
        let cancel = CancellationToken::new();
        let handle = runtime
            .clone()
            .spawn_watcher_with_interval(cancel.clone(), Duration::from_millis(20));

        let profile_path = home
            .join(crate::shared::paths::dirs::PROFILES)
            .join(NORMAL_PROFILE)
            .join(crate::shared::paths::files::PROFILE_TOML);
        let mut profile = std::fs::read_to_string(&profile_path).unwrap();
        profile.push_str("\n[settings.server]\ndefaultModel = \"watcher-test-model\"\n");
        std::fs::write(&profile_path, profile).unwrap();

        tokio::time::timeout(Duration::from_secs(2), async {
            loop {
                if runtime.current().settings.server.default_model == "watcher-test-model"
                    && crate::domains::settings::get_settings()
                        .server
                        .default_model
                        == "watcher-test-model"
                {
                    break;
                }
                tokio::time::sleep(Duration::from_millis(20)).await;
            }
        })
        .await
        .expect("watcher should reload a valid profile edit");

        cancel.cancel();
        handle.await.unwrap();
        crate::domains::settings::reset_settings();
    }

    #[test]
    fn product_control_plane_tables_are_not_profile_schema() {
        let (_dir, runtime) = seeded_runtime();
        let profile_path = runtime
            .home()
            .join(crate::shared::paths::dirs::PROFILES)
            .join(NORMAL_PROFILE)
            .join(crate::shared::paths::files::PROFILE_TOML);
        let mut profile = std::fs::read_to_string(&profile_path).unwrap();
        profile.push_str("\n[entrypoints.main]\nmodelPolicy = \"sessionDefault\"\n");
        std::fs::write(&profile_path, profile).unwrap();

        let error = runtime.reload_now("test").unwrap_err();

        assert!(error.to_string().contains("unknown field"));
    }
}
