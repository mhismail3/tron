use super::types::{LoadedRules, RuleFile, RuleFileLevel};
use super::{
    ContextLevel, ContextLoader, ContextLoaderConfig, Path, RulesDiscoveryConfig,
    RulesDiscoveryResult, RulesIndex, discover_rules_files_with_state,
};
use crate::runtime::context::loader;

pub(super) const RULES_AGENT_DIRS: &[&str] = &[".claude", ".tron", ".agent"];

pub(super) fn load_rules(
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

pub(super) fn discover_rules_state(
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

pub(super) fn rules_index_from_discovery(discovery: &RulesDiscoveryResult) -> Option<RulesIndex> {
    if discovery.files.is_empty() {
        None
    } else {
        Some(RulesIndex::new(discovery.files.clone()))
    }
}
