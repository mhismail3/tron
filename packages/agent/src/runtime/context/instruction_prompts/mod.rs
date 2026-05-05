//! Profile-backed instruction prompt loading.
//!
//! Normal Tron behavior is read from the active execution profile under
//! `~/.tron/profiles/`, seeded from managed defaults during install/startup.
//! This module does not embed normal prompt fallbacks; missing profile
//! instruction files are configuration defects.

use std::fs;
use std::path::{Path, PathBuf};

use tracing::{debug, warn};

use crate::core::messages::Provider;

use super::constants::MAX_SYSTEM_PROMPT_FILE_SIZE;

/// Working directory suffix template appended to system prompts.
pub const WORKING_DIRECTORY_SUFFIX: &str = "\n\nCurrent working directory: {workingDirectory}";

/// Read a managed/default prompt from the active profile.
#[must_use]
pub fn default_prompt(name: &str) -> String {
    read_instruction_file(crate::core::paths::default_prompt_path(name))
}

/// Read an entrypoint prompt through an explicit profile inheritance chain.
#[must_use]
pub fn entrypoint_prompt(profile_name: &str, entrypoint: &str, _fallback_name: &str) -> String {
    let home = crate::core::paths::tron_home();
    let profile = crate::core::profile::resolve_profile_at(&home, profile_name)
        .expect("requested profile must resolve before entrypoint prompt loading");
    let relative = profile
        .spec
        .entrypoint_prompt(entrypoint)
        .unwrap_or_else(|| {
            panic!("profile `{profile_name}` entrypoint `{entrypoint}` must define a prompt")
        });
    let path = crate::core::profile::resolve_profile_file_at(&home, profile_name, relative)
        .expect("validated profile must provide entrypoint prompt");
    read_instruction_file(path)
}

/// Read a managed/default process prompt from the active profile.
#[must_use]
pub fn process_prompt(name: &str) -> String {
    read_instruction_file(crate::core::paths::default_process_prompt_path(name))
}

/// Read a managed/default provider prompt from the active profile.
#[must_use]
pub fn provider_prompt(provider: &str, name: &str) -> String {
    read_instruction_file(crate::core::paths::default_provider_prompt_path(
        provider, name,
    ))
}

fn read_instruction_file(path: PathBuf) -> String {
    let content = fs::read_to_string(&path).unwrap_or_else(|error| {
        panic!(
            "validated profile instruction file must be readable: {} ({error})",
            path.display()
        )
    });
    assert!(
        !content.trim().is_empty(),
        "validated profile instruction file must not be empty: {}",
        path.display()
    );
    content
}

// =============================================================================
// File-Based Instruction Prompt Loading
// =============================================================================

/// Result of loading a system prompt from file.
#[derive(Debug, Clone)]
pub struct LoadedSystemPrompt {
    /// File content.
    pub content: String,
    /// Source of the prompt.
    pub source: SystemPromptSource,
}

/// Where a loaded system prompt came from.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SystemPromptSource {
    /// Project-level `.tron/SYSTEM.md`.
    Project,
    /// Global `~/.tron/profiles/user/prompts/core.md`.
    Global,
}

/// Load system prompt from project directory (synchronous).
///
/// Looks for `.tron/SYSTEM.md` in the working directory.
/// Returns `None` if not found or if the file exceeds the size limit.
#[must_use]
pub fn load_system_prompt_from_file(working_directory: &str) -> Option<LoadedSystemPrompt> {
    let project_path = Path::new(working_directory).join(".tron").join("SYSTEM.md");

    let Ok(metadata) = fs::metadata(&project_path) else {
        return None;
    };

    if metadata.len() > MAX_SYSTEM_PROMPT_FILE_SIZE {
        warn!(
            path = %project_path.display(),
            size = metadata.len(),
            limit = MAX_SYSTEM_PROMPT_FILE_SIZE,
            "Project SYSTEM.md exceeds size limit"
        );
        return None;
    }

    match fs::read_to_string(&project_path) {
        Ok(content) => {
            debug!(path = %project_path.display(), "Loaded system prompt from project");
            Some(LoadedSystemPrompt {
                content,
                source: SystemPromptSource::Project,
            })
        }
        Err(_) => None,
    }
}

/// Load the global system prompt from a given home directory.
///
/// Looks for `{home}/.tron/profiles/user/prompts/core.md`.
/// Returns `None` if the file is missing, empty, or oversized.
#[must_use]
pub fn load_global_system_prompt_from(home: &Path) -> Option<LoadedSystemPrompt> {
    let path = home
        .join(".tron")
        .join(crate::core::paths::dirs::PROFILES)
        .join("user")
        .join(crate::core::paths::dirs::PROMPTS)
        .join("core.md");

    let Ok(metadata) = fs::metadata(&path) else {
        return None;
    };

    if metadata.len() > MAX_SYSTEM_PROMPT_FILE_SIZE {
        warn!(
            path = %path.display(),
            size = metadata.len(),
            limit = MAX_SYSTEM_PROMPT_FILE_SIZE,
            "Global SYSTEM.md exceeds size limit"
        );
        return None;
    }

    match fs::read_to_string(&path) {
        Ok(content) => {
            if content.trim().is_empty() {
                return None;
            }
            debug!(path = %path.display(), "Loaded global system prompt");
            Some(LoadedSystemPrompt {
                content,
                source: SystemPromptSource::Global,
            })
        }
        Err(_) => None,
    }
}

/// Load the global system prompt from `~/.tron/profiles/user/prompts/core.md`.
///
/// Convenience wrapper around [`load_global_system_prompt_from`] using the
/// user's home directory.
#[must_use]
pub fn load_global_system_prompt() -> Option<LoadedSystemPrompt> {
    let home = crate::core::paths::home_dir();
    load_global_system_prompt_from(Path::new(&home))
}

// =============================================================================
// Provider-Specific Instruction Builders
// =============================================================================

/// Configuration for building system prompts.
#[derive(Debug, Clone)]
pub struct SystemPromptConfig {
    /// Provider type.
    pub provider_type: Provider,
    /// Working directory path.
    pub working_directory: String,
    /// Custom system prompt override.
    pub custom_prompt: Option<String>,
}

/// Build a system prompt appropriate for the given provider.
///
/// For most providers, returns a system prompt string. For `OpenAI` Codex,
/// returns an empty string (context is injected via tool clarification).
#[must_use]
pub fn build_system_prompt(config: &SystemPromptConfig) -> String {
    if config.provider_type == Provider::OpenAiCodex {
        // Codex: system prompt is fixed by OAuth validation.
        // Tron context goes via tool clarification message.
        String::new()
    } else {
        let default = default_prompt("core");
        let base = config.custom_prompt.as_deref().unwrap_or(&default);
        let suffix =
            WORKING_DIRECTORY_SUFFIX.replace("{workingDirectory}", &config.working_directory);
        format!("{base}{suffix}")
    }
}

/// Build the Codex tool clarification message.
///
/// For `OpenAI` Codex, the system instructions are fixed and cannot be modified.
/// Instead, Tron-specific context is injected as a user message at the start
/// of the conversation.
#[must_use]
pub fn build_codex_tool_clarification(config: &SystemPromptConfig) -> String {
    let default = default_prompt("core");
    let base = config.custom_prompt.as_deref().unwrap_or(&default);

    format!(
        "[TRON CONTEXT]\n\
         {base}\n\
         \n\
         Current working directory: {wd}\n\
         \n\
         NOTE: The tools mentioned in the system instructions (shell, apply_patch, etc.) are NOT available.\n\
         Use ONLY the tools listed above (read, write, edit, bash, grep, find, ls).",
        wd = config.working_directory
    )
}

/// Check if a provider requires a tool clarification message
/// instead of a custom system prompt.
#[must_use]
pub fn requires_tool_clarification(provider_type: &Provider) -> bool {
    *provider_type == Provider::OpenAiCodex
}

/// Get the tool clarification message for providers that need it.
///
/// Returns `None` if the provider uses standard system prompts.
#[must_use]
pub fn get_tool_clarification(config: &SystemPromptConfig) -> Option<String> {
    if config.provider_type == Provider::OpenAiCodex {
        Some(build_codex_tool_clarification(config))
    } else {
        None
    }
}

// =============================================================================
// Tests
// =============================================================================

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn working_directory_suffix_has_placeholder() {
        assert!(WORKING_DIRECTORY_SUFFIX.contains("{workingDirectory}"));
    }

    // ── System prompt builders ───────────────────────────────────────────

    fn make_config(provider_type: Provider) -> SystemPromptConfig {
        SystemPromptConfig {
            provider_type,
            working_directory: "/tmp/project".into(),
            custom_prompt: None,
        }
    }

    #[test]
    fn build_anthropic_prompt() {
        let config = make_config(Provider::Anthropic);
        let prompt = build_system_prompt(&config);
        assert!(prompt.contains("/tmp/project"));
        assert!(!prompt.is_empty());
    }

    #[test]
    fn build_openai_prompt() {
        let config = make_config(Provider::OpenAi);
        let prompt = build_system_prompt(&config);
        assert!(prompt.contains("/tmp/project"));
        assert!(!prompt.is_empty());
    }

    #[test]
    fn build_google_prompt() {
        let config = make_config(Provider::Google);
        let prompt = build_system_prompt(&config);
        assert!(prompt.contains("/tmp/project"));
        assert!(!prompt.is_empty());
    }

    #[test]
    fn build_codex_prompt_is_empty() {
        let config = make_config(Provider::OpenAiCodex);
        let prompt = build_system_prompt(&config);
        assert!(prompt.is_empty());
    }

    #[test]
    fn build_codex_tool_clarification_contains_context() {
        let config = make_config(Provider::OpenAiCodex);
        let clarification = build_codex_tool_clarification(&config);
        assert!(clarification.contains("[TRON CONTEXT]"));
        assert!(clarification.contains("/tmp/project"));
        assert!(clarification.contains("NOT available"));
    }

    #[test]
    fn custom_prompt_overrides_core() {
        let config = SystemPromptConfig {
            provider_type: Provider::Anthropic,
            working_directory: "/tmp".into(),
            custom_prompt: Some("Custom system prompt".into()),
        };
        let prompt = build_system_prompt(&config);
        assert!(prompt.contains("Custom system prompt"));
        assert!(!prompt.contains("Tron Home instructions are missing"));
        assert!(prompt.contains("/tmp"));
    }

    #[test]
    #[should_panic(expected = "validated profile instruction file must be readable")]
    fn read_missing_instruction_file_panics() {
        let dir = tempfile::tempdir().unwrap();
        let _ = read_instruction_file(dir.path().join("missing.md"));
    }

    // ── Provider detection ───────────────────────────────────────────────

    #[test]
    fn codex_requires_tool_clarification() {
        assert!(requires_tool_clarification(&Provider::OpenAiCodex));
    }

    #[test]
    fn non_codex_does_not_require_tool_clarification() {
        assert!(!requires_tool_clarification(&Provider::Anthropic));
        assert!(!requires_tool_clarification(&Provider::OpenAi));
        assert!(!requires_tool_clarification(&Provider::Google));
    }

    #[test]
    fn get_tool_clarification_codex() {
        let config = make_config(Provider::OpenAiCodex);
        let result = get_tool_clarification(&config);
        assert!(result.is_some());
        assert!(result.unwrap().contains("[TRON CONTEXT]"));
    }

    #[test]
    fn get_tool_clarification_non_codex() {
        let config = make_config(Provider::Anthropic);
        assert!(get_tool_clarification(&config).is_none());
    }

    // ── File loading ─────────────────────────────────────────────────────

    #[test]
    fn load_from_nonexistent_directory() {
        let result = load_system_prompt_from_file("/nonexistent/path");
        assert!(result.is_none());
    }

    #[test]
    fn load_from_directory_without_system_md() {
        let dir = tempfile::tempdir().unwrap();
        let result = load_system_prompt_from_file(dir.path().to_str().unwrap());
        assert!(result.is_none());
    }

    #[test]
    fn load_from_directory_with_system_md() {
        let dir = tempfile::tempdir().unwrap();
        let tron_dir = dir.path().join(".tron");
        fs::create_dir_all(&tron_dir).unwrap();
        fs::write(tron_dir.join("SYSTEM.md"), "Custom prompt content").unwrap();

        let result = load_system_prompt_from_file(dir.path().to_str().unwrap());
        assert!(result.is_some());
        let loaded = result.unwrap();
        assert_eq!(loaded.content, "Custom prompt content");
        assert_eq!(loaded.source, SystemPromptSource::Project);
    }

    #[test]
    fn load_rejects_oversized_file() {
        let dir = tempfile::tempdir().unwrap();
        let tron_dir = dir.path().join(".tron");
        fs::create_dir_all(&tron_dir).unwrap();
        // Write a file larger than MAX_SYSTEM_PROMPT_FILE_SIZE (100KB)
        let big_content = "x".repeat(150_000);
        fs::write(tron_dir.join("SYSTEM.md"), big_content).unwrap();

        let result = load_system_prompt_from_file(dir.path().to_str().unwrap());
        assert!(result.is_none());
    }

    // ── Global prompt loading ───────────────────────────────────────────

    #[test]
    fn load_global_returns_none_when_file_missing() {
        let dir = tempfile::tempdir().unwrap();
        assert!(load_global_system_prompt_from(dir.path()).is_none());
    }

    #[test]
    fn load_global_returns_content_when_file_exists() {
        let dir = tempfile::tempdir().unwrap();
        let prompt_dir = dir
            .path()
            .join(".tron")
            .join(crate::core::paths::dirs::PROFILES)
            .join("user")
            .join(crate::core::paths::dirs::PROMPTS);
        fs::create_dir_all(&prompt_dir).unwrap();
        fs::write(prompt_dir.join("core.md"), "Custom global prompt").unwrap();

        let loaded = load_global_system_prompt_from(dir.path()).unwrap();
        assert_eq!(loaded.content, "Custom global prompt");
    }

    #[test]
    fn load_global_source_is_global() {
        let dir = tempfile::tempdir().unwrap();
        let prompt_dir = dir
            .path()
            .join(".tron")
            .join(crate::core::paths::dirs::PROFILES)
            .join("user")
            .join(crate::core::paths::dirs::PROMPTS);
        fs::create_dir_all(&prompt_dir).unwrap();
        fs::write(prompt_dir.join("core.md"), "prompt").unwrap();

        let loaded = load_global_system_prompt_from(dir.path()).unwrap();
        assert_eq!(loaded.source, SystemPromptSource::Global);
    }

    #[test]
    fn load_global_rejects_oversized_file() {
        let dir = tempfile::tempdir().unwrap();
        let prompt_dir = dir
            .path()
            .join(".tron")
            .join(crate::core::paths::dirs::PROFILES)
            .join("user")
            .join(crate::core::paths::dirs::PROMPTS);
        fs::create_dir_all(&prompt_dir).unwrap();
        let big = "x".repeat(150_000);
        fs::write(prompt_dir.join("core.md"), big).unwrap();

        assert!(load_global_system_prompt_from(dir.path()).is_none());
    }

    #[test]
    fn load_global_returns_none_for_empty_file() {
        let dir = tempfile::tempdir().unwrap();
        let prompt_dir = dir
            .path()
            .join(".tron")
            .join(crate::core::paths::dirs::PROFILES)
            .join("user")
            .join(crate::core::paths::dirs::PROMPTS);
        fs::create_dir_all(&prompt_dir).unwrap();
        fs::write(prompt_dir.join("core.md"), "").unwrap();

        assert!(load_global_system_prompt_from(dir.path()).is_none());
    }
}
