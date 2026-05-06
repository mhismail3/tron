//! Shared session-context data loading used by RPC handlers.

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Condvar, Mutex};
use std::time::SystemTime;

use serde_json::Value;

use crate::events::EventStore;
use crate::runtime::context::loader::{self, ContextLevel, ContextLoader, ContextLoaderConfig};
use crate::runtime::context::rules_discovery::{
    RulesDiscoveryConfig, RulesDiscoveryResult, discover_rules_files_with_state,
};
use crate::runtime::context::rules_index::RulesIndex;

const RULES_AGENT_DIRS: &[&str] = &[".claude", ".tron", ".agent"];

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum RuleFileLevel {
    Global,
    Project,
    Directory,
}

impl RuleFileLevel {
    pub(crate) const fn as_str(self) -> &'static str {
        match self {
            Self::Global => "global",
            Self::Project => "project",
            Self::Directory => "directory",
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct RuleFile {
    pub(crate) path: PathBuf,
    pub(crate) relative_path: String,
    pub(crate) level: RuleFileLevel,
    pub(crate) depth: usize,
    pub(crate) size_bytes: usize,
}

#[derive(Clone, Debug, Default)]
pub(crate) struct LoadedRules {
    pub(crate) merged_content: Option<String>,
    pub(crate) files: Vec<RuleFile>,
}

impl LoadedRules {
    pub(crate) fn total_size_bytes(&self) -> usize {
        self.files.iter().map(|f| f.size_bytes).sum()
    }

    pub(crate) fn merged_tokens_estimate(&self) -> u32 {
        #[allow(clippy::cast_possible_truncation)]
        {
            (self.total_size_bytes() / 4) as u32
        }
    }
}

#[derive(Clone, Debug, Default)]
pub(crate) struct SessionContextArtifacts {
    pub(crate) rules: LoadedRules,
}

#[derive(Clone, Debug, Default)]
pub(crate) struct ResolvedContextArtifacts {
    pub(crate) session: SessionContextArtifacts,
    pub(crate) rules_index: Option<RulesIndex>,
    pub(crate) workspace_id: Option<String>,
}

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

    #[cfg(test)]
    pub(crate) fn rules_index_builds(&self) -> usize {
        self.rules_index_builds
            .load(std::sync::atomic::Ordering::Relaxed)
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

pub(crate) fn collect_dynamic_rule_paths(
    event_store: &EventStore,
    session_id: &str,
) -> Vec<String> {
    let events = event_store
        .get_events_by_type(
            session_id,
            &[
                "rules.activated",
                "compact.boundary",
                "compact.summary",
                "context.cleared",
            ],
            None,
        )
        .unwrap_or_default();

    let mut seen_paths = HashSet::new();
    let mut ordered_paths = Vec::new();

    for event in events {
        if event.event_type == "compact.boundary"
            || event.event_type == "compact.summary"
            || event.event_type == "context.cleared"
        {
            seen_paths.clear();
            ordered_paths.clear();
            continue;
        }

        let Ok(payload) = serde_json::from_str::<Value>(&event.payload) else {
            continue;
        };
        let Some(rules) = payload.get("rules").and_then(Value::as_array) else {
            continue;
        };

        for rule in rules {
            let Some(relative_path) = rule.get("relativePath").and_then(Value::as_str) else {
                continue;
            };
            if rule.get("scopeDir").and_then(Value::as_str).is_none() {
                continue;
            }

            if seen_paths.insert(relative_path.to_string()) {
                ordered_paths.push(relative_path.to_string());
            }
        }
    }

    ordered_paths
}

fn load_rules(
    working_dir: &Path,
    settings: &crate::settings::TronSettings,
    home_dir: Option<&Path>,
) -> LoadedRules {
    let mut loader = ContextLoader::new(ContextLoaderConfig {
        project_root: working_dir.to_path_buf(),
        discover_standalone_files: settings.context.rules.discover_standalone_files,
        ..Default::default()
    });

    let loaded_context = loader.load(working_dir).ok();
    let project_rules = loaded_context.as_ref().and_then(|ctx| {
        if ctx.merged.trim().is_empty() {
            None
        } else {
            Some(ctx.merged.clone())
        }
    });

    let global_rules = home_dir.and_then(loader::load_global_rules_with_path);
    let merged_content = loader::merge_rules(
        global_rules.as_ref().map(|(_, content)| content.clone()),
        project_rules,
    );

    let mut files = Vec::new();

    if let Some((path, content)) = global_rules {
        let file_name = path
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or("CLAUDE.md")
            .to_string();
        files.push(RuleFile {
            path,
            relative_path: format!(".tron/memory/rules/{file_name}"),
            level: RuleFileLevel::Global,
            depth: 0,
            size_bytes: content.len(),
        });
    }

    if let Some(context) = loaded_context {
        for file in context.files {
            let relative_path = file.path.strip_prefix(working_dir).map_or_else(
                |_| file.path.to_string_lossy().to_string(),
                |p| p.to_string_lossy().to_string(),
            );
            files.push(RuleFile {
                path: file.path,
                relative_path,
                level: match file.level {
                    ContextLevel::Project => RuleFileLevel::Project,
                    ContextLevel::Directory => RuleFileLevel::Directory,
                },
                depth: file.depth,
                size_bytes: file.content.len(),
            });
        }
    }

    LoadedRules {
        merged_content,
        files,
    }
}

fn discover_rules_state(
    working_dir: &Path,
    settings: &crate::settings::TronSettings,
) -> RulesDiscoveryResult {
    let config = RulesDiscoveryConfig {
        project_root: working_dir.to_path_buf(),
        discover_standalone_files: settings.context.rules.discover_standalone_files,
        exclude_root_level: true,
        ..Default::default()
    };

    discover_rules_files_with_state(&config)
}

fn rules_index_from_discovery(discovery: &RulesDiscoveryResult) -> Option<RulesIndex> {
    if discovery.files.is_empty() {
        None
    } else {
        Some(RulesIndex::new(discovery.files.clone()))
    }
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::events::{AppendOptions, EventType};
    use crate::server::rpc::handlers::test_helpers::make_test_context;

    #[tokio::test]
    async fn loads_rules_from_project_and_global() {
        let ctx = make_test_context();
        let mut settings = crate::settings::TronSettings::default();
        settings.context.rules.discover_standalone_files = true;

        let home_dir = tempfile::tempdir().unwrap();
        let rules_dir = home_dir.path().join(".tron").join("memory").join("rules");
        std::fs::create_dir_all(&rules_dir).unwrap();
        std::fs::write(rules_dir.join("AGENTS.md"), "global rules").unwrap();

        let working_dir = tempfile::tempdir().unwrap();
        let agent_dir = working_dir.path().join(".agent");
        std::fs::create_dir_all(&agent_dir).unwrap();
        std::fs::write(agent_dir.join("AGENTS.md"), "project rules").unwrap();

        let artifacts = load_session_context_artifacts_with_home(
            ctx.event_store.as_ref(),
            working_dir.path().to_str().unwrap(),
            &settings,
            Some(home_dir.path()),
        );

        assert_eq!(artifacts.rules.files.len(), 2);
        assert!(
            artifacts
                .rules
                .files
                .iter()
                .any(|f| f.level == RuleFileLevel::Global)
        );
        assert!(
            artifacts.rules.files.iter().any(|f| {
                f.level == RuleFileLevel::Global
                    && f.relative_path == ".tron/memory/rules/AGENTS.md"
            }),
            "global rules should resolve from ~/.tron/memory/rules"
        );
        assert!(
            artifacts
                .rules
                .files
                .iter()
                .any(|f| f.level == RuleFileLevel::Project)
        );
        assert!(
            artifacts
                .rules
                .merged_content
                .as_deref()
                .unwrap_or("")
                .contains("global rules")
        );
        assert!(
            artifacts
                .rules
                .merged_content
                .as_deref()
                .unwrap_or("")
                .contains("project rules")
        );
    }

    #[tokio::test]
    async fn dynamic_rules_reset_after_compaction_boundary() {
        let ctx = make_test_context();
        let session_id = ctx
            .session_manager
            .create_session("claude-sonnet-4-20250514", "/tmp", Some("test"), None)
            .unwrap();

        let _ = ctx.event_store.append(&AppendOptions {
            session_id: &session_id,
            event_type: EventType::RulesActivated,
            payload: serde_json::json!({
                "rules": [{"relativePath": "a/AGENTS.md", "scopeDir": "a"}]
            }),
            parent_id: None,
            sequence: None,
        });
        let _ = ctx.event_store.append(&AppendOptions {
            session_id: &session_id,
            event_type: EventType::CompactBoundary,
            payload: serde_json::json!({
                "originalTokens": 0,
                "compactedTokens": 0,
                "reason": "manual",
            }),
            parent_id: None,
            sequence: None,
        });
        let _ = ctx.event_store.append(&AppendOptions {
            session_id: &session_id,
            event_type: EventType::RulesActivated,
            payload: serde_json::json!({
                "rules": [{"relativePath": "b/AGENTS.md", "scopeDir": "b"}]
            }),
            parent_id: None,
            sequence: None,
        });

        let paths = collect_dynamic_rule_paths(ctx.event_store.as_ref(), &session_id);
        assert_eq!(paths, vec!["b/AGENTS.md"]);
    }

    #[test]
    fn service_invalidates_cached_root_rules_when_project_rules_appear() {
        let ctx = make_test_context();
        let service = ContextArtifactsService::new();
        let settings = crate::settings::TronSettings::default();
        let working_dir = tempfile::tempdir().unwrap();
        let working_dir_str = working_dir.path().to_str().unwrap();

        let first = service.load(ctx.event_store.as_ref(), working_dir_str, &settings);
        assert!(first.session.rules.merged_content.is_none());

        let rules_dir = working_dir.path().join(".agent");
        std::fs::create_dir_all(&rules_dir).unwrap();
        std::fs::write(rules_dir.join("AGENTS.md"), "project rules").unwrap();

        let second = service.load(ctx.event_store.as_ref(), working_dir_str, &settings);
        assert!(
            second
                .session
                .rules
                .merged_content
                .as_deref()
                .unwrap_or("")
                .contains("project rules")
        );
    }

    #[test]
    fn service_invalidates_cached_rules_index_when_scoped_rules_appear() {
        let ctx = make_test_context();
        let service = ContextArtifactsService::new();
        let settings = crate::settings::TronSettings::default();
        let working_dir = tempfile::tempdir().unwrap();
        let working_dir_str = working_dir.path().to_str().unwrap();

        let first = service.load(ctx.event_store.as_ref(), working_dir_str, &settings);
        assert!(first.rules_index.is_none());

        let scoped_rules_dir = working_dir.path().join("src").join(".claude");
        std::fs::create_dir_all(&scoped_rules_dir).unwrap();
        std::fs::write(scoped_rules_dir.join("AGENTS.md"), "scoped rules").unwrap();

        let second = service.load(ctx.event_store.as_ref(), working_dir_str, &settings);
        assert_eq!(
            second.rules_index.as_ref().map(RulesIndex::total_count),
            Some(1)
        );
    }
}
