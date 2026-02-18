//! Shared session-context data loading used by RPC handlers.

use std::collections::HashSet;
use std::fmt::Write;
use std::path::{Path, PathBuf};

use serde_json::Value;

use tron_events::EventStore;
use tron_runtime::context::loader::{self, ContextLevel, ContextLoader, ContextLoaderConfig};

const GLOBAL_RULE_NAMES: &[&str] = &["CLAUDE.md", "claude.md", "AGENTS.md", "agents.md"];

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

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct MemoryEntry {
    pub(crate) title: String,
    pub(crate) summary: String,
}

#[derive(Clone, Debug)]
pub(crate) struct LoadedMemory {
    pub(crate) workspace_id: String,
    pub(crate) raw_event_count: usize,
    pub(crate) raw_payload_tokens: u64,
    pub(crate) entries: Vec<MemoryEntry>,
    pub(crate) content: String,
}

impl LoadedMemory {
    pub(crate) fn content_tokens_estimate(&self) -> u64 {
        #[allow(clippy::cast_possible_truncation)]
        {
            (self.content.len() / 4) as u64
        }
    }
}

#[derive(Clone, Debug, Default)]
pub(crate) struct SessionContextArtifacts {
    pub(crate) rules: LoadedRules,
    pub(crate) memory: Option<LoadedMemory>,
}

pub(crate) fn load_session_context_artifacts(
    event_store: &EventStore,
    working_dir: &str,
    settings: &tron_settings::TronSettings,
) -> SessionContextArtifacts {
    let home_dir = std::env::var("HOME").ok().map(PathBuf::from);
    load_session_context_artifacts_with_home(
        event_store,
        working_dir,
        settings,
        home_dir.as_deref(),
    )
}

pub(crate) fn load_session_context_artifacts_with_home(
    event_store: &EventStore,
    working_dir: &str,
    settings: &tron_settings::TronSettings,
    home_dir: Option<&Path>,
) -> SessionContextArtifacts {
    let wd_path = Path::new(working_dir);
    let rules = load_rules(wd_path, settings, home_dir);
    let memory = load_memory(event_store, working_dir, settings);
    SessionContextArtifacts { rules, memory }
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
    settings: &tron_settings::TronSettings,
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

    let global_rules = home_dir.and_then(load_global_rules_with_path);
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
            relative_path: format!(".tron/{file_name}"),
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

fn load_global_rules_with_path(home_dir: &Path) -> Option<(PathBuf, String)> {
    let tron_dir = home_dir.join(".tron");
    for name in GLOBAL_RULE_NAMES {
        let path = tron_dir.join(name);
        if !path.is_file() {
            continue;
        }
        let Ok(content) = std::fs::read_to_string(&path) else {
            continue;
        };
        if content.trim().is_empty() {
            continue;
        }
        return Some((path, content));
    }
    None
}

fn load_memory(
    event_store: &EventStore,
    working_dir: &str,
    settings: &tron_settings::TronSettings,
) -> Option<LoadedMemory> {
    let auto_inject = &settings.context.memory.auto_inject;
    if !auto_inject.enabled {
        return None;
    }

    let workspace = event_store
        .get_workspace_by_path(working_dir)
        .ok()
        .flatten()?;
    #[allow(clippy::cast_possible_wrap)]
    let count = auto_inject.count.clamp(1, 10) as i64;
    let events = event_store
        .get_events_by_workspace_and_types(&workspace.id, &["memory.ledger"], Some(count), None)
        .unwrap_or_default();

    if events.is_empty() {
        return None;
    }

    let mut sections = vec!["# Memory\n\n## Recent sessions in this workspace".to_string()];
    let mut entries = Vec::new();

    for event in events.iter().rev() {
        let Ok(payload) = serde_json::from_str::<Value>(&event.payload) else {
            continue;
        };
        let title = payload
            .get("title")
            .and_then(Value::as_str)
            .unwrap_or("Untitled");
        let mut summary = format!("### {title}");
        if let Some(lessons) = payload.get("lessons").and_then(Value::as_array) {
            for lesson in lessons
                .iter()
                .filter_map(Value::as_str)
                .filter(|text| !text.is_empty())
            {
                write!(summary, "\n- {lesson}").unwrap();
            }
        }
        sections.push(format!("\n{summary}"));
        entries.push(MemoryEntry {
            title: title.to_string(),
            summary,
        });
    }

    #[allow(clippy::cast_possible_truncation)]
    let raw_payload_tokens: u64 = events
        .iter()
        .map(|event| (event.payload.len() / 4) as u64)
        .sum();

    Some(LoadedMemory {
        workspace_id: workspace.id,
        raw_event_count: events.len(),
        raw_payload_tokens,
        entries,
        content: sections.join("\n"),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::rpc::handlers::test_helpers::make_test_context;
    use tron_events::{AppendOptions, EventType};

    #[tokio::test]
    async fn loads_rules_from_project_and_global() {
        let ctx = make_test_context();
        let mut settings = tron_settings::TronSettings::default();
        settings.context.rules.discover_standalone_files = true;

        let home_dir = tempfile::tempdir().unwrap();
        let tron_dir = home_dir.path().join(".tron");
        std::fs::create_dir_all(&tron_dir).unwrap();
        std::fs::write(tron_dir.join("AGENTS.md"), "global rules").unwrap();

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
    async fn loads_workspace_memory_entries() {
        let ctx = make_test_context();
        let settings = tron_settings::TronSettings::default();

        let working_dir = tempfile::tempdir().unwrap();
        let working_dir_str = working_dir.path().to_str().unwrap();
        let session_id = ctx
            .session_manager
            .create_session("claude-sonnet-4-20250514", working_dir_str, Some("test"))
            .unwrap();

        let _ = ctx.event_store.append(&AppendOptions {
            session_id: &session_id,
            event_type: EventType::MemoryLedger,
            payload: serde_json::json!({
                "title": "Previous session",
                "lessons": ["Keep cache warm", "Avoid duplicate IO"]
            }),
            parent_id: None,
        });

        let artifacts =
            load_session_context_artifacts(ctx.event_store.as_ref(), working_dir_str, &settings);
        let memory = artifacts.memory.expect("memory should be loaded");

        assert_eq!(memory.raw_event_count, 1);
        assert_eq!(memory.entries.len(), 1);
        assert_eq!(memory.entries[0].title, "Previous session");
        assert!(memory.entries[0].summary.contains("Keep cache warm"));
        assert!(memory.content.contains("Recent sessions in this workspace"));
    }

    #[tokio::test]
    async fn dynamic_rules_reset_after_compaction_boundary() {
        let ctx = make_test_context();
        let session_id = ctx
            .session_manager
            .create_session("claude-sonnet-4-20250514", "/tmp", Some("test"))
            .unwrap();

        let _ = ctx.event_store.append(&AppendOptions {
            session_id: &session_id,
            event_type: EventType::RulesActivated,
            payload: serde_json::json!({
                "rules": [{"relativePath": "a/AGENTS.md", "scopeDir": "a"}]
            }),
            parent_id: None,
        });
        let _ = ctx.event_store.append(&AppendOptions {
            session_id: &session_id,
            event_type: EventType::CompactBoundary,
            payload: serde_json::json!({}),
            parent_id: None,
        });
        let _ = ctx.event_store.append(&AppendOptions {
            session_id: &session_id,
            event_type: EventType::RulesActivated,
            payload: serde_json::json!({
                "rules": [{"relativePath": "b/AGENTS.md", "scopeDir": "b"}]
            }),
            parent_id: None,
        });

        let paths = collect_dynamic_rule_paths(ctx.event_store.as_ref(), &session_id);
        assert_eq!(paths, vec!["b/AGENTS.md"]);
    }
}
