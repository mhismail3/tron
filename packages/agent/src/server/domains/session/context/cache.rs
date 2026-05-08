use super::rules::{
    RULES_AGENT_DIRS, discover_rules_state, load_rules, rules_index_from_discovery,
};
use super::types::{LoadedRules, ResolvedContextArtifacts, SessionContextArtifacts};
use super::{Condvar, HashMap, Path, RulesDiscoveryResult, SystemTime};
use crate::events::EventStore;
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::Mutex;

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
struct ContextArtifactsKey {
    working_dir: String,
    discover_standalone_files: bool,
}

#[derive(Default)]
struct ContextArtifactsState {
    entries: HashMap<ContextArtifactsKey, CacheSlot>,
}

enum CacheSlot {
    Ready(Box<CachedArtifacts>),
    Loading(Arc<LoadingSlot>),
}

struct LoadingSlot {
    complete: Mutex<bool>,
    ready: Condvar,
}

impl LoadingSlot {
    fn new() -> Self {
        Self {
            complete: Mutex::new(false),
            ready: Condvar::new(),
        }
    }

    fn wait(&self) {
        let mut complete = lock_unpoisoned(&self.complete);
        while !*complete {
            complete = match self.ready.wait(complete) {
                Ok(guard) => guard,
                Err(poisoned) => poisoned.into_inner(),
            };
        }
    }

    fn finish(&self) {
        let mut complete = lock_unpoisoned(&self.complete);
        *complete = true;
        self.ready.notify_all();
    }
}

#[derive(Clone)]
struct CachedArtifacts {
    artifacts: ResolvedContextArtifacts,
    rules_fingerprint: RulesFingerprint,
    rules_index_fingerprint: RulesIndexFingerprint,
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct RulesFingerprint {
    watched_paths: Vec<PathFingerprint>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct RulesIndexFingerprint {
    scanned_dirs: Vec<PathFingerprint>,
    discovered_files: Vec<PathFingerprint>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct PathFingerprint {
    path: PathBuf,
    kind: PathKind,
    modified_at: Option<SystemTime>,
    len: Option<u64>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
enum PathKind {
    Missing,
    File,
    Directory,
}

/// Shared loader and cache for rules, workspace memory preload, and rules index state.
pub struct ContextArtifactsService {
    home_dir: Option<PathBuf>,
    state: Mutex<ContextArtifactsState>,
    #[cfg(test)]
    rules_index_builds: std::sync::atomic::AtomicUsize,
}

impl ContextArtifactsService {
    /// Create a new context-artifacts cache rooted at the current user's home directory.
    pub fn new() -> Self {
        Self {
            home_dir: Some(PathBuf::from(crate::core::paths::home_dir())),
            state: Mutex::new(ContextArtifactsState::default()),
            #[cfg(test)]
            rules_index_builds: std::sync::atomic::AtomicUsize::new(0),
        }
    }

    pub(crate) fn load(
        &self,
        event_store: &EventStore,
        working_dir: &str,
        settings: &crate::settings::TronSettings,
    ) -> ResolvedContextArtifacts {
        let key = ContextArtifactsKey {
            working_dir: working_dir.to_owned(),
            discover_standalone_files: settings.context.rules.discover_standalone_files,
        };

        loop {
            let wait_slot = {
                let mut state = lock_unpoisoned(&self.state);
                match state.entries.get(&key) {
                    Some(CacheSlot::Ready(cached))
                        if cached.is_fresh(
                            event_store,
                            working_dir,
                            settings,
                            self.home_dir.as_deref(),
                        ) =>
                    {
                        return cached.artifacts.clone();
                    }
                    Some(CacheSlot::Loading(waiter)) => Some(waiter.clone()),
                    _ => {
                        let waiter = Arc::new(LoadingSlot::new());
                        let _ = state
                            .entries
                            .insert(key.clone(), CacheSlot::Loading(waiter.clone()));
                        drop(state);

                        #[cfg(test)]
                        let _ = self
                            .rules_index_builds
                            .fetch_add(1, std::sync::atomic::Ordering::Relaxed);

                        let cached = Self::build_cached_artifacts(
                            event_store,
                            working_dir,
                            settings,
                            self.home_dir.as_deref(),
                        );

                        let mut state = lock_unpoisoned(&self.state);
                        let _ = state
                            .entries
                            .insert(key.clone(), CacheSlot::Ready(Box::new(cached.clone())));
                        waiter.finish();
                        return cached.artifacts;
                    }
                }
            };

            if let Some(waiter) = wait_slot {
                waiter.wait();
            }
        }
    }

    fn build_cached_artifacts(
        event_store: &EventStore,
        working_dir: &str,
        settings: &crate::settings::TronSettings,
        home_dir: Option<&Path>,
    ) -> CachedArtifacts {
        let working_dir_path = Path::new(working_dir);
        let workspace = event_store
            .get_workspace_by_path(working_dir)
            .ok()
            .flatten();
        let rules = load_rules(working_dir_path, settings, home_dir);
        let rules_discovery = discover_rules_state(working_dir_path, settings);
        let rules_index = rules_index_from_discovery(&rules_discovery);
        let workspace_id = workspace.as_ref().map(|workspace| workspace.id.clone());

        let session = SessionContextArtifacts { rules };
        let artifacts = ResolvedContextArtifacts {
            session,
            rules_index,
            workspace_id,
        };

        CachedArtifacts {
            rules_fingerprint: build_rules_fingerprint(
                working_dir_path,
                home_dir,
                &artifacts.session.rules,
            ),
            rules_index_fingerprint: build_rules_index_fingerprint(&rules_discovery),
            artifacts,
        }
    }
}

impl Default for ContextArtifactsService {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
pub(crate) fn load_session_context_artifacts_with_home(
    event_store: &EventStore,
    working_dir: &str,
    settings: &crate::settings::TronSettings,
    home_dir: Option<&Path>,
) -> SessionContextArtifacts {
    let wd_path = Path::new(working_dir);
    let _workspace = event_store
        .get_workspace_by_path(working_dir)
        .ok()
        .flatten();
    let rules = load_rules(wd_path, settings, home_dir);
    SessionContextArtifacts { rules }
}

impl CachedArtifacts {
    fn is_fresh(
        &self,
        _event_store: &EventStore,
        _working_dir: &str,
        _settings: &crate::settings::TronSettings,
        _home_dir: Option<&Path>,
    ) -> bool {
        self.rules_fingerprint.is_fresh() && self.rules_index_fingerprint.is_fresh()
    }
}

impl RulesFingerprint {
    fn is_fresh(&self) -> bool {
        self.watched_paths
            .iter()
            .all(PathFingerprint::matches_current)
    }
}

impl RulesIndexFingerprint {
    fn is_fresh(&self) -> bool {
        self.scanned_dirs
            .iter()
            .all(PathFingerprint::matches_current)
            && self
                .discovered_files
                .iter()
                .all(PathFingerprint::matches_current)
    }
}

impl PathFingerprint {
    fn capture(path: &Path) -> Self {
        match std::fs::metadata(path) {
            Ok(metadata) if metadata.is_dir() => Self {
                path: path.to_path_buf(),
                kind: PathKind::Directory,
                modified_at: metadata.modified().ok(),
                len: None,
            },
            Ok(metadata) if metadata.is_file() => Self {
                path: path.to_path_buf(),
                kind: PathKind::File,
                modified_at: metadata.modified().ok(),
                len: Some(metadata.len()),
            },
            _ => Self {
                path: path.to_path_buf(),
                kind: PathKind::Missing,
                modified_at: None,
                len: None,
            },
        }
    }

    fn matches_current(&self) -> bool {
        Self::capture(&self.path) == *self
    }
}

fn build_rules_fingerprint(
    working_dir: &Path,
    home_dir: Option<&Path>,
    rules: &LoadedRules,
) -> RulesFingerprint {
    let mut watched_paths = vec![PathFingerprint::capture(working_dir)];
    for agent_dir in RULES_AGENT_DIRS {
        let path = working_dir.join(agent_dir);
        if path.exists() {
            watched_paths.push(PathFingerprint::capture(&path));
        }
    }

    if let Some(home_dir) = home_dir {
        watched_paths.push(PathFingerprint::capture(home_dir));
        let tron_dir = home_dir.join(".tron");
        if tron_dir.exists() {
            watched_paths.push(PathFingerprint::capture(&tron_dir));
        }
    }

    for file in &rules.files {
        watched_paths.push(PathFingerprint::capture(&file.path));
    }

    watched_paths.sort_by(|a, b| a.path.cmp(&b.path));
    RulesFingerprint { watched_paths }
}

fn build_rules_index_fingerprint(discovery: &RulesDiscoveryResult) -> RulesIndexFingerprint {
    let mut scanned_dirs: Vec<PathFingerprint> = discovery
        .scanned_dirs
        .iter()
        .map(|dir| PathFingerprint {
            path: dir.path.clone(),
            kind: PathKind::Directory,
            modified_at: dir.modified_at,
            len: None,
        })
        .collect();
    scanned_dirs.sort_by(|a, b| a.path.cmp(&b.path));

    let mut discovered_files: Vec<PathFingerprint> = discovery
        .files
        .iter()
        .map(|rule| PathFingerprint {
            path: rule.path.clone(),
            kind: PathKind::File,
            modified_at: Some(rule.modified_at),
            len: Some(rule.size_bytes),
        })
        .collect();
    discovered_files.sort_by(|a, b| a.path.cmp(&b.path));

    RulesIndexFingerprint {
        scanned_dirs,
        discovered_files,
    }
}

fn lock_unpoisoned<T>(mutex: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    match mutex.lock() {
        Ok(guard) => guard,
        Err(poisoned) => poisoned.into_inner(),
    }
}
