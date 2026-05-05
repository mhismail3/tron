//! Profile-backed instruction prompt loading.
//!
//! Normal Tron behavior is compiled by `ProfileRuntime` before context
//! construction. This module only loads optional project/user prompt overlays
//! such as `.tron/SYSTEM.md` and `~/.tron/profiles/user/prompts/core.md`; it
//! does not resolve active profiles or embed normal prompt fallbacks.

use std::fs;
use std::path::Path;

use tracing::{debug, warn};

use super::constants::MAX_SYSTEM_PROMPT_FILE_SIZE;

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
// Tests
// =============================================================================

#[cfg(test)]
mod tests {
    use super::*;

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
