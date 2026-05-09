//! Filesystem hook discovery.
//!
//! Scans directories for hook files and parses their frontmatter metadata.
//! All hook metadata (type, label, priority, enabled) lives in YAML
//! frontmatter — filenames are purely descriptive.
//!
//! Searches three paths in order:
//! 1. Project-level: `.agent/hooks/` and `.tron/hooks/`
//! 2. User-level: `~/.tron/hooks/`
//! 3. Additional custom paths

use std::path::{Path, PathBuf};

use tracing::{debug, warn};

use super::types::{DiscoveredHook, DiscoveryConfig, HookFileConfig, HookSource, HookType};

/// Default file extensions to consider as hook files.
const DEFAULT_EXTENSIONS: &[&str] = &[".sh", ".ts", ".js", ".mjs", ".prompt"];

/// Project-level hook directories (relative to project root).
const PROJECT_HOOK_DIRS: &[&str] = &[".agent/hooks", ".tron/hooks"];

/// User-level hook directory (relative to home).
const USER_HOOK_DIR: &str = ".tron/hooks";

/// Maximum file size to read for frontmatter parsing (1 MB).
const MAX_HOOK_FILE_SIZE: u64 = 1_048_576;

/// Discover hook files from configured paths.
///
/// Returns a list of discovered hooks with parsed frontmatter.
/// Files without valid frontmatter (missing `type:`) are skipped.
/// Non-existent directories are silently skipped.
pub fn discover_hooks(config: &DiscoveryConfig) -> Vec<DiscoveredHook> {
    let mut discovered = Vec::new();
    let extensions = if config.extensions.is_empty() {
        DEFAULT_EXTENSIONS
            .iter()
            .map(|s| (*s).to_string())
            .collect()
    } else {
        config.extensions.clone()
    };

    // 1. Project-level hooks
    if let Some(project_path) = &config.project_path {
        for dir in PROJECT_HOOK_DIRS {
            let path = PathBuf::from(project_path).join(dir);
            scan_directory(&path, HookSource::Project, &extensions, &mut discovered);
        }
    }

    // 2. User-level hooks
    if config.include_user_hooks {
        let home = config
            .user_home
            .clone()
            .unwrap_or_else(crate::shared::paths::home_dir);
        let path = PathBuf::from(home).join(USER_HOOK_DIR);
        scan_directory(&path, HookSource::User, &extensions, &mut discovered);
    }

    // 3. Custom paths
    for custom in &config.additional_paths {
        let path = PathBuf::from(custom);
        scan_directory(&path, HookSource::Custom, &extensions, &mut discovered);
    }

    debug!(count = discovered.len(), "Discovered hooks");
    discovered
}

/// Scan a single directory for hook files.
fn scan_directory(
    dir: &Path,
    source: HookSource,
    extensions: &[String],
    results: &mut Vec<DiscoveredHook>,
) {
    if !dir.exists() || !dir.is_dir() {
        return;
    }

    let entries = match std::fs::read_dir(dir) {
        Ok(entries) => entries,
        Err(e) => {
            warn!(dir = %dir.display(), error = %e, "Failed to read hooks directory");
            return;
        }
    };

    for entry in entries {
        let Ok(entry) = entry else { continue };
        let path = entry.path();

        if !path.is_file() {
            continue;
        }

        let filename = match path.file_name().and_then(|n| n.to_str()) {
            Some(name) => name.to_string(),
            None => continue,
        };

        // Check extension
        let has_valid_ext = extensions
            .iter()
            .any(|ext| filename.ends_with(ext.as_str()));
        if !has_valid_ext {
            continue;
        }

        // Check file size
        if let Ok(metadata) = std::fs::metadata(&path) {
            if metadata.len() > MAX_HOOK_FILE_SIZE {
                warn!(path = %path.display(), size = metadata.len(), "Hook file too large, skipping");
                continue;
            }
        }

        // Read and parse the file
        if let Some(hook) = parse_hook_file(&path, source) {
            debug!(
                name = %hook.name,
                hook_type = %hook.config.hook_type,
                source = %source,
                "Discovered hook file"
            );
            results.push(hook);
        }
    }
}

/// Parse a hook file by reading its content and extracting frontmatter.
///
/// Returns `None` if:
/// - The file can't be read
/// - No valid frontmatter is found
/// - The `type:` field is missing or invalid
fn parse_hook_file(path: &Path, source: HookSource) -> Option<DiscoveredHook> {
    let ext = path.extension()?.to_str()?.to_string();
    let stem = path.file_stem()?.to_str()?.to_string();

    let content = match std::fs::read_to_string(path) {
        Ok(c) => c,
        Err(e) => {
            warn!(path = %path.display(), error = %e, "Failed to read hook file");
            return None;
        }
    };

    let is_prompt = ext == "prompt";
    let config = parse_frontmatter(&content, is_prompt)?;

    let name = format!("{source}:{stem}");

    Some(DiscoveredHook {
        name,
        path: path.to_path_buf(),
        extension: ext,
        source,
        config,
    })
}

/// Parse frontmatter from file content.
///
/// For `.prompt` files, uses standard `---` delimiters.
/// For script files, uses comment-prefixed delimiters (`# ---`, `// ---`).
///
/// Returns `None` if no valid frontmatter with `type:` field is found.
pub fn parse_frontmatter(content: &str, is_prompt: bool) -> Option<HookFileConfig> {
    if is_prompt {
        parse_prompt_frontmatter(content)
    } else {
        parse_script_frontmatter(content)
    }
}

/// Parse standard YAML frontmatter from a `.prompt` file.
fn parse_prompt_frontmatter(content: &str) -> Option<HookFileConfig> {
    let trimmed = content.trim();

    if !trimmed.starts_with("---") {
        return None;
    }

    let after_first = trimmed[3..].trim_start_matches(['\n', '\r']);
    let end_pos = after_first.find("\n---")?;

    let frontmatter = &after_first[..end_pos];
    let body = after_first[end_pos + 4..].trim();

    let fields = parse_yaml_fields(frontmatter);
    let hook_type = parse_type_value(fields.get("type")?)?;

    // `enabled` and `priority` surface parse errors loudly: a typo like
    // `enabled: ya` used to silently enable the hook. We now reject the
    // whole frontmatter so the user gets a clear signal that their hook
    // file is malformed.
    let enabled = match fields.get("enabled") {
        None => true,
        Some(v) => v
            .parse()
            .map_err(|e| {
                tracing::warn!(value = %v, error = %e, "hook frontmatter: invalid `enabled` value");
                e
            })
            .ok()?,
    };
    let priority = match fields.get("priority") {
        None => 0,
        Some(v) => v.parse().map_err(|e| {
            tracing::warn!(value = %v, error = %e, "hook frontmatter: invalid `priority` value");
            e
        }).ok()?,
    };

    Some(HookFileConfig {
        hook_type,
        label: fields.get("label").cloned().unwrap_or_default(),
        enabled,
        priority,
        prompt: Some(body.to_string()),
    })
}

/// Parse comment-prefixed frontmatter from a script file.
///
/// Supports `# ` prefix (shell, Python) and `// ` prefix (JS, TS).
fn parse_script_frontmatter(content: &str) -> Option<HookFileConfig> {
    let lines: Vec<&str> = content.lines().collect();

    // Detect comment prefix and opening delimiter
    let (prefix, start_idx) = detect_comment_frontmatter(&lines)?;

    // Collect frontmatter lines until closing delimiter
    let mut frontmatter_lines = Vec::new();
    let mut end_idx = None;

    for (i, line) in lines.iter().enumerate().skip(start_idx + 1) {
        let stripped = line.strip_prefix(prefix).unwrap_or(line).trim();
        if stripped == "---" {
            end_idx = Some(i);
            break;
        }
        frontmatter_lines.push(stripped);
    }

    let _end = end_idx?; // No closing delimiter → invalid
    let frontmatter = frontmatter_lines.join("\n");

    let fields = parse_yaml_fields(&frontmatter);
    let hook_type = parse_type_value(fields.get("type")?)?;

    // Same strict parsing as markdown frontmatter: a typo on `enabled` or
    // `priority` now invalidates the file rather than silently accepting
    // the default.
    let enabled = match fields.get("enabled") {
        None => true,
        Some(v) => v
            .parse()
            .map_err(|e| {
                tracing::warn!(value = %v, error = %e, "hook frontmatter: invalid `enabled` value");
                e
            })
            .ok()?,
    };
    let priority = match fields.get("priority") {
        None => 0,
        Some(v) => v.parse().map_err(|e| {
            tracing::warn!(value = %v, error = %e, "hook frontmatter: invalid `priority` value");
            e
        }).ok()?,
    };

    Some(HookFileConfig {
        hook_type,
        label: fields.get("label").cloned().unwrap_or_default(),
        enabled,
        priority,
        prompt: None, // Scripts don't have a prompt body
    })
}

/// Detect comment-prefixed frontmatter opening delimiter.
///
/// Returns the comment prefix and the line index of the opening `---`.
fn detect_comment_frontmatter(lines: &[&str]) -> Option<(&'static str, usize)> {
    for (i, line) in lines.iter().enumerate() {
        let trimmed = line.trim();
        if trimmed == "# ---" {
            return Some(("# ", i));
        }
        if trimmed == "// ---" {
            return Some(("// ", i));
        }
        // Skip empty lines and shebangs before frontmatter
        if trimmed.is_empty() || trimmed.starts_with("#!") {
            continue;
        }
        // Non-comment, non-empty line before frontmatter → no frontmatter
        break;
    }
    None
}

/// Parse simple `key: value` YAML fields from a string.
fn parse_yaml_fields(content: &str) -> std::collections::HashMap<String, String> {
    let mut fields = std::collections::HashMap::new();
    for line in content.lines() {
        let line = line.trim();
        if let Some(pos) = line.find(':') {
            let key = line[..pos].trim().to_string();
            let value = line[pos + 1..].trim().to_string();
            if !key.is_empty() {
                let _ = fields.insert(key, value);
            }
        }
    }
    fields
}

/// Map a type value string to [`HookType`].
fn parse_type_value(value: &str) -> Option<HookType> {
    match value.trim() {
        "pre-tool-use" => Some(HookType::PreToolUse),
        "post-tool-use" => Some(HookType::PostToolUse),
        "session-start" => Some(HookType::SessionStart),
        "session-end" => Some(HookType::SessionEnd),
        "stop" => Some(HookType::Stop),
        "subagent-stop" => Some(HookType::SubagentStop),
        "user-prompt-submit" => Some(HookType::UserPromptSubmit),
        "pre-compact" => Some(HookType::PreCompact),
        "notification" => Some(HookType::Notification),
        "worktree-acquired" => Some(HookType::WorktreeAcquired),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use tempfile::TempDir;

    // ── Prompt frontmatter ──

    #[test]
    fn test_parse_frontmatter_prompt_full() {
        let content = "---\ntype: session-start\nlabel: Generate title\npriority: 10\nenabled: true\n---\nDo the thing.";
        let config = parse_prompt_frontmatter(content).unwrap();
        assert_eq!(config.hook_type, HookType::SessionStart);
        assert_eq!(config.label, "Generate title");
        assert_eq!(config.priority, 10);
        assert!(config.enabled);
        assert_eq!(config.prompt.as_deref(), Some("Do the thing."));
    }

    #[test]
    fn test_parse_frontmatter_prompt_type_only() {
        let content = "---\ntype: stop\n---\nSummarize.";
        let config = parse_prompt_frontmatter(content).unwrap();
        assert_eq!(config.hook_type, HookType::Stop);
        assert_eq!(config.label, "");
        assert_eq!(config.priority, 0);
        assert!(config.enabled);
    }

    #[test]
    fn test_parse_frontmatter_prompt_missing_type() {
        let content = "---\nlabel: No type here\n---\nPrompt.";
        assert!(parse_prompt_frontmatter(content).is_none());
    }

    #[test]
    fn test_parse_frontmatter_prompt_no_frontmatter() {
        let content = "Just a plain file with no frontmatter.";
        assert!(parse_prompt_frontmatter(content).is_none());
    }

    #[test]
    fn test_parse_frontmatter_prompt_invalid_type() {
        let content = "---\ntype: invalid-event\n---\nPrompt.";
        assert!(parse_prompt_frontmatter(content).is_none());
    }

    #[test]
    fn test_parse_frontmatter_prompt_disabled() {
        let content = "---\ntype: session-start\nenabled: false\n---\nPrompt.";
        let config = parse_prompt_frontmatter(content).unwrap();
        assert!(!config.enabled);
    }

    #[test]
    fn test_parse_frontmatter_prompt_multiline_body() {
        let content = "---\ntype: stop\n---\nLine one.\nLine two.\nLine three.";
        let config = parse_prompt_frontmatter(content).unwrap();
        let prompt = config.prompt.unwrap();
        assert!(prompt.contains("Line one."));
        assert!(prompt.contains("Line three."));
    }

    #[test]
    fn test_parse_frontmatter_prompt_empty_body() {
        let content = "---\ntype: session-start\n---\n";
        let config = parse_prompt_frontmatter(content).unwrap();
        assert_eq!(config.prompt.as_deref(), Some(""));
    }

    #[test]
    fn test_parse_frontmatter_prompt_whitespace_handling() {
        let content = "---\ntype:  session-start  \nlabel:   My Hook  \n---\nPrompt.";
        let config = parse_prompt_frontmatter(content).unwrap();
        assert_eq!(config.hook_type, HookType::SessionStart);
        assert_eq!(config.label, "My Hook");
    }

    #[test]
    fn test_parse_frontmatter_prompt_priority_negative() {
        let content = "---\ntype: stop\npriority: -10\n---\nPrompt.";
        let config = parse_prompt_frontmatter(content).unwrap();
        assert_eq!(config.priority, -10);
    }

    #[test]
    fn test_parse_frontmatter_prompt_priority_non_numeric_rejects_file() {
        // A typo in `priority` used to silently fall back to 0, which would
        // register the hook at the wrong priority relative to its siblings.
        // Now it's treated as a malformed frontmatter → the hook is skipped.
        let content = "---\ntype: stop\npriority: high\n---\nPrompt.";
        assert!(
            parse_prompt_frontmatter(content).is_none(),
            "non-numeric priority must reject the frontmatter, not default to 0"
        );
    }

    #[test]
    fn test_parse_frontmatter_prompt_enabled_non_boolean_rejects_file() {
        // Previously `enabled: ya` silently defaulted to `true`; a user
        // trying to disable a hook via a typo would accidentally leave it
        // active. Now the whole file is rejected so the error surfaces.
        let content = "---\ntype: stop\nenabled: ya\n---\nPrompt.";
        assert!(
            parse_prompt_frontmatter(content).is_none(),
            "non-boolean enabled must reject the frontmatter, not default to true"
        );
    }

    #[test]
    fn test_parse_frontmatter_empty_file() {
        assert!(parse_prompt_frontmatter("").is_none());
    }

    // ── Script frontmatter (# prefix) ──

    #[test]
    fn test_parse_frontmatter_script_hash() {
        let content = "# ---\n# type: pre-tool-use\n# label: Safety check\n# priority: 100\n# ---\n#!/bin/bash\necho ok";
        let config = parse_script_frontmatter(content).unwrap();
        assert_eq!(config.hook_type, HookType::PreToolUse);
        assert_eq!(config.label, "Safety check");
        assert_eq!(config.priority, 100);
        assert!(config.enabled);
        assert!(config.prompt.is_none());
    }

    #[test]
    fn test_parse_frontmatter_script_type_only() {
        let content = "# ---\n# type: stop\n# ---\n#!/bin/bash\nexit 0";
        let config = parse_script_frontmatter(content).unwrap();
        assert_eq!(config.hook_type, HookType::Stop);
        assert_eq!(config.label, "");
        assert_eq!(config.priority, 0);
        assert!(config.enabled);
    }

    #[test]
    fn test_parse_frontmatter_script_disabled() {
        let content = "# ---\n# type: session-start\n# enabled: false\n# ---\n#!/bin/bash";
        let config = parse_script_frontmatter(content).unwrap();
        assert!(!config.enabled);
    }

    #[test]
    fn test_parse_frontmatter_script_missing_type() {
        let content = "# ---\n# label: No type\n# ---\n#!/bin/bash";
        assert!(parse_script_frontmatter(content).is_none());
    }

    #[test]
    fn test_parse_frontmatter_script_no_frontmatter() {
        let content = "#!/bin/bash\necho hello";
        assert!(parse_script_frontmatter(content).is_none());
    }

    #[test]
    fn test_parse_frontmatter_script_no_closing_delimiter() {
        let content = "# ---\n# type: stop\n#!/bin/bash";
        assert!(parse_script_frontmatter(content).is_none());
    }

    #[test]
    fn test_parse_frontmatter_script_shebang_before_frontmatter() {
        // Shebang before frontmatter is OK (skipped)
        let content = "#!/bin/bash\n# ---\n# type: session-start\n# ---\necho ok";
        let config = parse_script_frontmatter(content).unwrap();
        assert_eq!(config.hook_type, HookType::SessionStart);
    }

    // ── Script frontmatter (// prefix) ──

    #[test]
    fn test_parse_frontmatter_script_slash_prefix() {
        let content =
            "// ---\n// type: post-tool-use\n// label: Logger\n// ---\nconsole.log('ok');";
        let config = parse_script_frontmatter(content).unwrap();
        assert_eq!(config.hook_type, HookType::PostToolUse);
        assert_eq!(config.label, "Logger");
    }

    // ── parse_frontmatter dispatch ──

    #[test]
    fn test_parse_frontmatter_dispatches_prompt() {
        let content = "---\ntype: session-start\n---\nPrompt body.";
        let config = parse_frontmatter(content, true).unwrap();
        assert_eq!(config.hook_type, HookType::SessionStart);
        assert_eq!(config.prompt.as_deref(), Some("Prompt body."));
    }

    #[test]
    fn test_parse_frontmatter_dispatches_script() {
        let content = "# ---\n# type: stop\n# ---\n#!/bin/bash";
        let config = parse_frontmatter(content, false).unwrap();
        assert_eq!(config.hook_type, HookType::Stop);
        assert!(config.prompt.is_none());
    }

    // ── Discovery integration ──

    fn write_hook(dir: &Path, filename: &str, content: &str) {
        fs::write(dir.join(filename), content).unwrap();
    }

    #[test]
    fn test_discover_prompt_with_frontmatter() {
        let tmp = TempDir::new().unwrap();
        let hooks_dir = tmp.path().join(".tron/hooks");
        fs::create_dir_all(&hooks_dir).unwrap();
        write_hook(
            &hooks_dir,
            "title-gen.prompt",
            "---\ntype: session-start\nlabel: Title\n---\nGenerate title.",
        );

        let config = DiscoveryConfig {
            project_path: Some(tmp.path().to_string_lossy().into_owned()),
            include_user_hooks: false,
            ..Default::default()
        };

        let hooks = discover_hooks(&config);
        assert_eq!(hooks.len(), 1);
        assert_eq!(hooks[0].config.hook_type, HookType::SessionStart);
        assert_eq!(hooks[0].config.label, "Title");
        assert!(hooks[0].is_prompt());
        assert_eq!(hooks[0].name, "project:title-gen");
    }

    #[test]
    fn test_discover_script_with_frontmatter() {
        let tmp = TempDir::new().unwrap();
        let hooks_dir = tmp.path().join(".tron/hooks");
        fs::create_dir_all(&hooks_dir).unwrap();
        write_hook(
            &hooks_dir,
            "safety.sh",
            "# ---\n# type: pre-tool-use\n# ---\n#!/bin/bash\necho ok",
        );

        let config = DiscoveryConfig {
            project_path: Some(tmp.path().to_string_lossy().into_owned()),
            include_user_hooks: false,
            ..Default::default()
        };

        let hooks = discover_hooks(&config);
        assert_eq!(hooks.len(), 1);
        assert_eq!(hooks[0].config.hook_type, HookType::PreToolUse);
        assert!(hooks[0].is_script());
    }

    #[test]
    fn test_discover_skips_files_without_frontmatter() {
        let tmp = TempDir::new().unwrap();
        let hooks_dir = tmp.path().join(".tron/hooks");
        fs::create_dir_all(&hooks_dir).unwrap();
        write_hook(&hooks_dir, "no-frontmatter.sh", "#!/bin/bash\necho hello");

        let config = DiscoveryConfig {
            project_path: Some(tmp.path().to_string_lossy().into_owned()),
            include_user_hooks: false,
            ..Default::default()
        };

        let hooks = discover_hooks(&config);
        assert!(hooks.is_empty());
    }

    #[test]
    fn test_discover_skips_invalid_type() {
        let tmp = TempDir::new().unwrap();
        let hooks_dir = tmp.path().join(".tron/hooks");
        fs::create_dir_all(&hooks_dir).unwrap();
        write_hook(&hooks_dir, "bad.prompt", "---\ntype: invalid\n---\nPrompt.");

        let config = DiscoveryConfig {
            project_path: Some(tmp.path().to_string_lossy().into_owned()),
            include_user_hooks: false,
            ..Default::default()
        };

        let hooks = discover_hooks(&config);
        assert!(hooks.is_empty());
    }

    #[test]
    fn test_discover_mixed_valid_invalid() {
        let tmp = TempDir::new().unwrap();
        let hooks_dir = tmp.path().join(".tron/hooks");
        fs::create_dir_all(&hooks_dir).unwrap();
        write_hook(
            &hooks_dir,
            "good.prompt",
            "---\ntype: session-start\n---\nOk.",
        );
        write_hook(&hooks_dir, "bad.sh", "#!/bin/bash\necho no frontmatter");
        write_hook(
            &hooks_dir,
            "also-good.sh",
            "# ---\n# type: stop\n# ---\n#!/bin/bash\necho ok",
        );

        let config = DiscoveryConfig {
            project_path: Some(tmp.path().to_string_lossy().into_owned()),
            include_user_hooks: false,
            ..Default::default()
        };

        let hooks = discover_hooks(&config);
        assert_eq!(hooks.len(), 2);
    }

    #[test]
    fn test_discover_filename_is_descriptive_only() {
        let tmp = TempDir::new().unwrap();
        let hooks_dir = tmp.path().join(".tron/hooks");
        fs::create_dir_all(&hooks_dir).unwrap();
        // Filename says "my-cool-hook" but type is "stop"
        write_hook(
            &hooks_dir,
            "my-cool-hook.prompt",
            "---\ntype: stop\n---\nSummarize.",
        );

        let config = DiscoveryConfig {
            project_path: Some(tmp.path().to_string_lossy().into_owned()),
            include_user_hooks: false,
            ..Default::default()
        };

        let hooks = discover_hooks(&config);
        assert_eq!(hooks.len(), 1);
        assert_eq!(hooks[0].config.hook_type, HookType::Stop);
        assert_eq!(hooks[0].name, "project:my-cool-hook");
    }

    #[test]
    fn test_discover_same_type_different_files() {
        let tmp = TempDir::new().unwrap();
        let hooks_dir = tmp.path().join(".tron/hooks");
        fs::create_dir_all(&hooks_dir).unwrap();
        write_hook(
            &hooks_dir,
            "title.prompt",
            "---\ntype: session-start\n---\nTitle.",
        );
        write_hook(
            &hooks_dir,
            "tags.prompt",
            "---\ntype: session-start\n---\nTags.",
        );

        let config = DiscoveryConfig {
            project_path: Some(tmp.path().to_string_lossy().into_owned()),
            include_user_hooks: false,
            ..Default::default()
        };

        let hooks = discover_hooks(&config);
        assert_eq!(hooks.len(), 2);
        assert!(
            hooks
                .iter()
                .all(|h| h.config.hook_type == HookType::SessionStart)
        );
    }

    #[test]
    fn test_discover_empty_directory() {
        let tmp = TempDir::new().unwrap();
        let config = DiscoveryConfig {
            project_path: Some(tmp.path().to_string_lossy().into_owned()),
            include_user_hooks: false,
            ..Default::default()
        };
        let hooks = discover_hooks(&config);
        assert!(hooks.is_empty());
    }

    #[test]
    fn test_discover_nonexistent_path() {
        let config = DiscoveryConfig {
            project_path: Some("/nonexistent/path".to_string()),
            include_user_hooks: false,
            ..Default::default()
        };
        let hooks = discover_hooks(&config);
        assert!(hooks.is_empty());
    }

    #[test]
    fn test_discover_user_hooks() {
        let tmp = TempDir::new().unwrap();
        let hooks_dir = tmp.path().join(USER_HOOK_DIR);
        fs::create_dir_all(&hooks_dir).unwrap();
        write_hook(
            &hooks_dir,
            "cleanup.sh",
            "# ---\n# type: stop\n# ---\n#!/bin/bash\nexit 0",
        );

        let config = DiscoveryConfig {
            project_path: None,
            user_home: Some(tmp.path().to_string_lossy().into_owned()),
            include_user_hooks: true,
            ..Default::default()
        };

        let hooks = discover_hooks(&config);
        assert_eq!(hooks.len(), 1);
        assert_eq!(hooks[0].source, HookSource::User);
    }

    #[test]
    fn test_discover_skips_non_hook_extensions() {
        let tmp = TempDir::new().unwrap();
        let hooks_dir = tmp.path().join(".tron/hooks");
        fs::create_dir_all(&hooks_dir).unwrap();
        write_hook(&hooks_dir, "readme.txt", "not a hook");
        write_hook(&hooks_dir, "notes.md", "also not a hook");

        let config = DiscoveryConfig {
            project_path: Some(tmp.path().to_string_lossy().into_owned()),
            include_user_hooks: false,
            ..Default::default()
        };

        let hooks = discover_hooks(&config);
        assert!(hooks.is_empty());
    }

    // ── parse_type_value ──

    #[test]
    fn test_parse_type_value_all_valid() {
        assert_eq!(parse_type_value("pre-tool-use"), Some(HookType::PreToolUse));
        assert_eq!(
            parse_type_value("post-tool-use"),
            Some(HookType::PostToolUse)
        );
        assert_eq!(
            parse_type_value("session-start"),
            Some(HookType::SessionStart)
        );
        assert_eq!(parse_type_value("session-end"), Some(HookType::SessionEnd));
        assert_eq!(parse_type_value("stop"), Some(HookType::Stop));
        assert_eq!(
            parse_type_value("subagent-stop"),
            Some(HookType::SubagentStop)
        );
        assert_eq!(
            parse_type_value("user-prompt-submit"),
            Some(HookType::UserPromptSubmit)
        );
        assert_eq!(parse_type_value("pre-compact"), Some(HookType::PreCompact));
        assert_eq!(
            parse_type_value("notification"),
            Some(HookType::Notification)
        );
        assert_eq!(
            parse_type_value("worktree-acquired"),
            Some(HookType::WorktreeAcquired)
        );
    }

    #[test]
    fn test_parse_type_value_invalid() {
        assert!(parse_type_value("invalid").is_none());
        assert!(parse_type_value("").is_none());
    }
}
