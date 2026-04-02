//! Filesystem hook discovery.
//!
//! Scans directories for hook files matching naming conventions:
//! - `pre-tool-use.sh` → [`HookType::PreToolUse`]
//! - `100-session-start.sh` → [`HookType::SessionStart`] with priority 100
//!
//! Searches three paths in order:
//! 1. Project-level: `.agent/hooks/` and `.tron/hooks/`
//! 2. User-level: `~/.config/tron/hooks/`
//! 3. Additional custom paths

use std::path::{Path, PathBuf};

use tracing::{debug, warn};

use super::types::{DiscoveredHook, DiscoveryConfig, HookSource, HookType, PromptHookConfig};

/// Default file extensions to consider as hook files.
const DEFAULT_EXTENSIONS: &[&str] = &[".sh", ".ts", ".js", ".prompt"];

/// Project-level hook directories (relative to project root).
const PROJECT_HOOK_DIRS: &[&str] = &[".agent/hooks", ".tron/hooks"];

/// User-level hook directory (relative to home).
const USER_HOOK_DIR: &str = ".tron/hooks";

/// Discover hook files from configured paths.
///
/// Returns a list of discovered hooks with inferred types and priorities.
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
            .unwrap_or_else(crate::core::paths::home_dir);
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

        // Parse hook type and priority from filename
        if let Some(hook) = parse_hook_filename(&filename, &path, source) {
            debug!(
                name = %hook.name,
                hook_type = %hook.hook_type,
                source = %source,
                "Discovered hook file"
            );
            results.push(hook);
        }
    }
}

/// Parse a hook filename into a [`DiscoveredHook`].
///
/// Supports formats:
/// - `pre-tool-use.sh` → script hook, type=PreToolUse
/// - `100-session-start.sh` → script hook, type=SessionStart, priority=100
/// - `session-start-title.prompt` → LLM prompt hook, type=SessionStart
fn parse_hook_filename(filename: &str, path: &Path, source: HookSource) -> Option<DiscoveredHook> {
    let ext = Path::new(filename).extension()?.to_str()?;
    let stem = Path::new(filename).file_stem()?.to_str()?;

    let is_shell = ext.eq_ignore_ascii_case("sh");
    let is_prompt = ext.eq_ignore_ascii_case("prompt");

    // Try to extract priority prefix: "100-pre-tool-use" → (Some(100), "pre-tool-use")
    let (priority, hook_name) = extract_priority(stem);

    let hook_type = parse_hook_type(hook_name)?;

    let name = format!("{source}:{stem}");

    // For .prompt files, parse the file content for frontmatter + prompt body
    let prompt_config = if is_prompt {
        match std::fs::read_to_string(path) {
            Ok(content) => Some(parse_prompt_file(&content)),
            Err(e) => {
                warn!(path = %path.display(), error = %e, "Failed to read prompt hook file");
                None
            }
        }
    } else {
        None
    };

    Some(DiscoveredHook {
        name,
        path: path.to_path_buf(),
        hook_type,
        is_shell_script: is_shell,
        is_prompt,
        source,
        priority,
        prompt_config,
    })
}

/// Extract optional numeric priority prefix from a stem.
///
/// `"100-pre-tool-use"` → `(Some(100), "pre-tool-use")`
/// `"pre-tool-use"` → `(None, "pre-tool-use")`
fn extract_priority(stem: &str) -> (Option<i32>, &str) {
    if let Some(pos) = stem.find('-') {
        let prefix = &stem[..pos];
        if let Ok(priority) = prefix.parse::<i32>() {
            return (Some(priority), &stem[pos + 1..]);
        }
    }
    (None, stem)
}

/// Map a hook name to its [`HookType`].
///
/// Supports both exact matches (`session-start`) and prefix matches
/// (`session-start-title`) so that multiple hooks can target the same
/// event with descriptive filenames.
fn parse_hook_type(name: &str) -> Option<HookType> {
    // Exact matches first
    match name {
        "pre-tool-use" | "pre-tool" => return Some(HookType::PreToolUse),
        "post-tool-use" | "post-tool" => return Some(HookType::PostToolUse),
        "session-start" => return Some(HookType::SessionStart),
        "session-end" => return Some(HookType::SessionEnd),
        "stop" => return Some(HookType::Stop),
        "subagent-stop" => return Some(HookType::SubagentStop),
        "user-prompt-submit" => return Some(HookType::UserPromptSubmit),
        "pre-compact" => return Some(HookType::PreCompact),
        "notification" => return Some(HookType::Notification),
        _ => {}
    }

    // Prefix matches for compound names (e.g., "session-start-title")
    // Check longest prefixes first to avoid false matches
    if name.starts_with("pre-tool-use-") || name.starts_with("pre-tool-") {
        return Some(HookType::PreToolUse);
    }
    if name.starts_with("post-tool-use-") || name.starts_with("post-tool-") {
        return Some(HookType::PostToolUse);
    }
    if name.starts_with("user-prompt-submit-") {
        return Some(HookType::UserPromptSubmit);
    }
    if name.starts_with("subagent-stop-") {
        return Some(HookType::SubagentStop);
    }
    if name.starts_with("session-start-") {
        return Some(HookType::SessionStart);
    }
    if name.starts_with("session-end-") {
        return Some(HookType::SessionEnd);
    }
    if name.starts_with("pre-compact-") {
        return Some(HookType::PreCompact);
    }
    if name.starts_with("notification-") {
        return Some(HookType::Notification);
    }
    if name.starts_with("stop-") {
        return Some(HookType::Stop);
    }

    None
}

/// Parse a `.prompt` file into a [`PromptHookConfig`].
///
/// Format:
/// ```text
/// ---
/// label: Generate session title
/// enabled: true
/// ---
/// Your prompt instruction here...
/// ```
///
/// If no frontmatter is present, the entire content is the prompt
/// with defaults for label (filename) and enabled (true).
fn parse_prompt_file(content: &str) -> PromptHookConfig {
    let trimmed = content.trim();

    // Check for YAML frontmatter delimiters
    if !trimmed.starts_with("---") {
        return PromptHookConfig {
            label: String::new(),
            enabled: true,
            prompt: trimmed.to_string(),
        };
    }

    // Find the closing ---
    let after_first = &trimmed[3..].trim_start_matches(['\n', '\r']);
    let Some(end_pos) = after_first.find("\n---") else {
        // No closing delimiter — treat entire content as prompt
        return PromptHookConfig {
            label: String::new(),
            enabled: true,
            prompt: trimmed.to_string(),
        };
    };

    let frontmatter = &after_first[..end_pos];
    let body = after_first[end_pos + 4..].trim(); // skip "\n---"

    // Parse simple YAML key: value pairs
    let mut label = String::new();
    let mut enabled = true;

    for line in frontmatter.lines() {
        let line = line.trim();
        if let Some(value) = line.strip_prefix("label:") {
            label = value.trim().to_string();
        } else if let Some(value) = line.strip_prefix("enabled:") {
            enabled = value.trim().parse().unwrap_or(true);
        }
    }

    PromptHookConfig {
        label,
        enabled,
        prompt: body.to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use tempfile::TempDir;

    fn create_hook_file(dir: &Path, filename: &str) {
        fs::write(dir.join(filename), "#!/bin/sh\nexit 0").unwrap();
    }

    // --- extract_priority ---

    #[test]
    fn test_extract_priority_with_prefix() {
        let (priority, name) = extract_priority("100-pre-tool-use");
        assert_eq!(priority, Some(100));
        assert_eq!(name, "pre-tool-use");
    }

    #[test]
    fn test_extract_priority_without_prefix() {
        let (priority, name) = extract_priority("pre-tool-use");
        assert_eq!(priority, None);
        assert_eq!(name, "pre-tool-use");
    }

    #[test]
    fn test_extract_priority_non_numeric_prefix() {
        let (priority, name) = extract_priority("abc-pre-tool-use");
        assert_eq!(priority, None);
        // Non-numeric, so the entire string is the name
        assert_eq!(name, "abc-pre-tool-use");
    }

    // --- parse_hook_type ---

    #[test]
    fn test_parse_hook_type_all_types() {
        assert_eq!(parse_hook_type("pre-tool-use"), Some(HookType::PreToolUse));
        assert_eq!(parse_hook_type("pre-tool"), Some(HookType::PreToolUse));
        assert_eq!(
            parse_hook_type("post-tool-use"),
            Some(HookType::PostToolUse)
        );
        assert_eq!(parse_hook_type("post-tool"), Some(HookType::PostToolUse));
        assert_eq!(
            parse_hook_type("session-start"),
            Some(HookType::SessionStart)
        );
        assert_eq!(parse_hook_type("session-end"), Some(HookType::SessionEnd));
        assert_eq!(parse_hook_type("stop"), Some(HookType::Stop));
        assert_eq!(
            parse_hook_type("subagent-stop"),
            Some(HookType::SubagentStop)
        );
        assert_eq!(
            parse_hook_type("user-prompt-submit"),
            Some(HookType::UserPromptSubmit)
        );
        assert_eq!(parse_hook_type("pre-compact"), Some(HookType::PreCompact));
        assert_eq!(
            parse_hook_type("notification"),
            Some(HookType::Notification)
        );
    }

    #[test]
    fn test_parse_hook_type_unknown() {
        assert_eq!(parse_hook_type("unknown-type"), None);
        assert_eq!(parse_hook_type(""), None);
    }

    // --- parse_hook_filename ---

    #[test]
    fn test_parse_simple_filename() {
        let path = PathBuf::from("/hooks/pre-tool-use.sh");
        let hook = parse_hook_filename("pre-tool-use.sh", &path, HookSource::Project).unwrap();
        assert_eq!(hook.hook_type, HookType::PreToolUse);
        assert!(hook.is_shell_script);
        assert!(!hook.is_prompt);
        assert_eq!(hook.source, HookSource::Project);
        assert!(hook.priority.is_none());
        assert_eq!(hook.name, "project:pre-tool-use");
        assert!(hook.prompt_config.is_none());
    }

    #[test]
    fn test_parse_filename_with_priority() {
        let path = PathBuf::from("/hooks/100-session-start.sh");
        let hook = parse_hook_filename("100-session-start.sh", &path, HookSource::User).unwrap();
        assert_eq!(hook.hook_type, HookType::SessionStart);
        assert_eq!(hook.priority, Some(100));
        assert_eq!(hook.name, "user:100-session-start");
    }

    #[test]
    fn test_parse_js_filename() {
        let path = PathBuf::from("/hooks/post-tool-use.js");
        let hook = parse_hook_filename("post-tool-use.js", &path, HookSource::Custom).unwrap();
        assert_eq!(hook.hook_type, HookType::PostToolUse);
        assert!(!hook.is_shell_script);
    }

    #[test]
    fn test_parse_unknown_filename() {
        let path = PathBuf::from("/hooks/unknown.sh");
        assert!(parse_hook_filename("unknown.sh", &path, HookSource::Project).is_none());
    }

    // --- discover_hooks ---

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
    fn test_discover_project_hooks() {
        let tmp = TempDir::new().unwrap();
        let hooks_dir = tmp.path().join(".tron/hooks");
        fs::create_dir_all(&hooks_dir).unwrap();
        create_hook_file(&hooks_dir, "pre-tool-use.sh");
        create_hook_file(&hooks_dir, "session-start.sh");

        let config = DiscoveryConfig {
            project_path: Some(tmp.path().to_string_lossy().into_owned()),
            include_user_hooks: false,
            ..Default::default()
        };

        let hooks = discover_hooks(&config);
        assert_eq!(hooks.len(), 2);
        assert!(hooks.iter().any(|h| h.hook_type == HookType::PreToolUse));
        assert!(hooks.iter().any(|h| h.hook_type == HookType::SessionStart));
        assert!(hooks.iter().all(|h| h.source == HookSource::Project));
    }

    #[test]
    fn test_discover_skips_non_hook_files() {
        let tmp = TempDir::new().unwrap();
        let hooks_dir = tmp.path().join(".tron/hooks");
        fs::create_dir_all(&hooks_dir).unwrap();
        create_hook_file(&hooks_dir, "pre-tool-use.sh");
        create_hook_file(&hooks_dir, "readme.txt"); // Not a hook
        create_hook_file(&hooks_dir, "helper.sh"); // Unknown hook name

        let config = DiscoveryConfig {
            project_path: Some(tmp.path().to_string_lossy().into_owned()),
            include_user_hooks: false,
            ..Default::default()
        };

        let hooks = discover_hooks(&config);
        // Only pre-tool-use.sh should match (helper.sh has unknown name, readme.txt wrong ext)
        assert_eq!(hooks.len(), 1);
    }

    #[test]
    fn test_discover_user_hooks() {
        let tmp = TempDir::new().unwrap();
        let hooks_dir = tmp.path().join(USER_HOOK_DIR);
        fs::create_dir_all(&hooks_dir).unwrap();
        create_hook_file(&hooks_dir, "stop.sh");

        let config = DiscoveryConfig {
            project_path: None,
            user_home: Some(tmp.path().to_string_lossy().into_owned()),
            include_user_hooks: true,
            ..Default::default()
        };

        let hooks = discover_hooks(&config);
        assert_eq!(hooks.len(), 1);
        assert_eq!(hooks[0].hook_type, HookType::Stop);
        assert_eq!(hooks[0].source, HookSource::User);
    }

    #[test]
    fn test_discover_user_hooks_disabled() {
        let tmp = TempDir::new().unwrap();
        let hooks_dir = tmp.path().join(USER_HOOK_DIR);
        fs::create_dir_all(&hooks_dir).unwrap();
        create_hook_file(&hooks_dir, "stop.sh");

        let config = DiscoveryConfig {
            project_path: None,
            user_home: Some(tmp.path().to_string_lossy().into_owned()),
            include_user_hooks: false, // Disabled
            ..Default::default()
        };

        let hooks = discover_hooks(&config);
        assert!(hooks.is_empty());
    }

    #[test]
    fn test_discover_custom_paths() {
        let tmp = TempDir::new().unwrap();
        create_hook_file(tmp.path(), "notification.sh");

        let config = DiscoveryConfig {
            additional_paths: vec![tmp.path().to_string_lossy().into_owned()],
            include_user_hooks: false,
            ..Default::default()
        };

        let hooks = discover_hooks(&config);
        assert_eq!(hooks.len(), 1);
        assert_eq!(hooks[0].source, HookSource::Custom);
    }

    #[test]
    fn test_discover_with_priority_prefix() {
        let tmp = TempDir::new().unwrap();
        let hooks_dir = tmp.path().join(".tron/hooks");
        fs::create_dir_all(&hooks_dir).unwrap();
        create_hook_file(&hooks_dir, "100-pre-tool-use.sh");

        let config = DiscoveryConfig {
            project_path: Some(tmp.path().to_string_lossy().into_owned()),
            include_user_hooks: false,
            ..Default::default()
        };

        let hooks = discover_hooks(&config);
        assert_eq!(hooks.len(), 1);
        assert_eq!(hooks[0].priority, Some(100));
        assert_eq!(hooks[0].hook_type, HookType::PreToolUse);
    }

    #[test]
    fn test_discover_custom_extensions() {
        let tmp = TempDir::new().unwrap();
        let hooks_dir = tmp.path().join(".tron/hooks");
        fs::create_dir_all(&hooks_dir).unwrap();
        create_hook_file(&hooks_dir, "pre-tool-use.sh");
        create_hook_file(&hooks_dir, "session-start.py");

        let config = DiscoveryConfig {
            project_path: Some(tmp.path().to_string_lossy().into_owned()),
            include_user_hooks: false,
            extensions: vec![".py".to_string()], // Only .py
            ..Default::default()
        };

        let hooks = discover_hooks(&config);
        // Should only find .py file, but session-start.py is unknown type → 0 hooks
        // Actually, wait: session-start maps correctly. Let me re-check.
        assert_eq!(hooks.len(), 1);
        assert_eq!(hooks[0].hook_type, HookType::SessionStart);
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
    fn test_discover_agent_hooks_dir() {
        let tmp = TempDir::new().unwrap();
        let hooks_dir = tmp.path().join(".agent/hooks");
        fs::create_dir_all(&hooks_dir).unwrap();
        create_hook_file(&hooks_dir, "stop.sh");

        let config = DiscoveryConfig {
            project_path: Some(tmp.path().to_string_lossy().into_owned()),
            include_user_hooks: false,
            ..Default::default()
        };

        let hooks = discover_hooks(&config);
        assert_eq!(hooks.len(), 1);
        assert_eq!(hooks[0].hook_type, HookType::Stop);
    }

    // --- parse_hook_type prefix matching ---

    #[test]
    fn test_parse_hook_type_compound_names() {
        assert_eq!(
            parse_hook_type("session-start-title"),
            Some(HookType::SessionStart)
        );
        assert_eq!(
            parse_hook_type("session-start-summary"),
            Some(HookType::SessionStart)
        );
        assert_eq!(
            parse_hook_type("stop-cleanup"),
            Some(HookType::Stop)
        );
        assert_eq!(
            parse_hook_type("session-end-report"),
            Some(HookType::SessionEnd)
        );
        assert_eq!(
            parse_hook_type("user-prompt-submit-validate"),
            Some(HookType::UserPromptSubmit)
        );
    }

    // --- parse_prompt_file ---

    #[test]
    fn test_parse_prompt_file_with_frontmatter() {
        let content = "---\nlabel: Generate title\nenabled: true\n---\nGenerate a 3-6 word title.";
        let config = parse_prompt_file(content);
        assert_eq!(config.label, "Generate title");
        assert!(config.enabled);
        assert_eq!(config.prompt, "Generate a 3-6 word title.");
    }

    #[test]
    fn test_parse_prompt_file_disabled() {
        let content = "---\nlabel: My hook\nenabled: false\n---\nDo something.";
        let config = parse_prompt_file(content);
        assert_eq!(config.label, "My hook");
        assert!(!config.enabled);
        assert_eq!(config.prompt, "Do something.");
    }

    #[test]
    fn test_parse_prompt_file_no_frontmatter() {
        let content = "Just a prompt with no frontmatter.";
        let config = parse_prompt_file(content);
        assert_eq!(config.label, "");
        assert!(config.enabled);
        assert_eq!(config.prompt, "Just a prompt with no frontmatter.");
    }

    #[test]
    fn test_parse_prompt_file_empty() {
        let config = parse_prompt_file("");
        assert_eq!(config.prompt, "");
        assert!(config.enabled);
    }

    #[test]
    fn test_parse_prompt_file_multiline_prompt() {
        let content = "---\nlabel: Complex\n---\nLine one.\nLine two.\nLine three.";
        let config = parse_prompt_file(content);
        assert_eq!(config.label, "Complex");
        assert!(config.prompt.contains("Line one."));
        assert!(config.prompt.contains("Line three."));
    }

    // --- prompt file discovery ---

    #[test]
    fn test_discover_prompt_hooks() {
        let tmp = TempDir::new().unwrap();
        let hooks_dir = tmp.path().join(".tron/hooks");
        fs::create_dir_all(&hooks_dir).unwrap();

        fs::write(
            hooks_dir.join("session-start-title.prompt"),
            "---\nlabel: Generate title\n---\nGenerate a title.",
        )
        .unwrap();

        let config = DiscoveryConfig {
            project_path: Some(tmp.path().to_string_lossy().into_owned()),
            include_user_hooks: false,
            ..Default::default()
        };

        let hooks = discover_hooks(&config);
        assert_eq!(hooks.len(), 1);
        assert_eq!(hooks[0].hook_type, HookType::SessionStart);
        assert!(hooks[0].is_prompt);
        assert!(!hooks[0].is_shell_script);
        let cfg = hooks[0].prompt_config.as_ref().unwrap();
        assert_eq!(cfg.label, "Generate title");
        assert_eq!(cfg.prompt, "Generate a title.");
    }

    #[test]
    fn test_discover_mixed_script_and_prompt_hooks() {
        let tmp = TempDir::new().unwrap();
        let hooks_dir = tmp.path().join(".tron/hooks");
        fs::create_dir_all(&hooks_dir).unwrap();

        create_hook_file(&hooks_dir, "pre-tool-use.sh");
        fs::write(
            hooks_dir.join("session-start-title.prompt"),
            "Generate a title.",
        )
        .unwrap();

        let config = DiscoveryConfig {
            project_path: Some(tmp.path().to_string_lossy().into_owned()),
            include_user_hooks: false,
            ..Default::default()
        };

        let hooks = discover_hooks(&config);
        assert_eq!(hooks.len(), 2);
        assert!(hooks.iter().any(|h| h.is_shell_script && h.hook_type == HookType::PreToolUse));
        assert!(hooks.iter().any(|h| h.is_prompt && h.hook_type == HookType::SessionStart));
    }
}
