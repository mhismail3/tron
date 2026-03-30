//! System prompt definitions.
//!
//! Centralized system prompts for Tron agents and subagents. Provider-specific
//! canonical prompts (OAuth prefix, Codex instructions) are handled by each
//! provider crate — this module provides the Tron-specific prompts.
//!
//! The default core prompt is loaded from `core.md` via [`include_str!`].
//! Users can override at two levels:
//!
//! 1. **Project**: `.tron/SYSTEM.md` in the working directory
//! 2. **Global**: `~/.tron/memory/rules/SYSTEM.md`
//!
//! Precedence: project override > global override > embedded `TRON_CORE_PROMPT`.

use std::fs;
use std::path::Path;

use sha2::{Digest, Sha256};
use tracing::{debug, warn};

use crate::core::messages::Provider;

use super::constants::MAX_SYSTEM_PROMPT_FILE_SIZE;

// =============================================================================
// Core Prompt
// =============================================================================

/// Core Tron system prompt defining the assistant's role and capabilities.
///
/// Loaded from `core.md` at compile time. Users can override at runtime by
/// creating `.tron/SYSTEM.md` in their project directory.
pub const TRON_CORE_PROMPT: &str = include_str!("core.md");

/// Chat-mode system prompt for the default conversational session.
///
/// More conversational, general-purpose persona. Not project-scoped.
pub const TRON_CHAT_PROMPT: &str = include_str!("chat.md");

/// Working directory suffix template appended to system prompts.
pub const WORKING_DIRECTORY_SUFFIX: &str = "\n\nCurrent working directory: {workingDirectory}";

// =============================================================================
// Subagent Prompts
// =============================================================================

/// System prompt for the compaction summarizer subagent.
///
/// Used by the compaction engine's Haiku subagent to produce dense,
/// structured summaries of conversation context.
pub const COMPACTION_SUMMARIZER_PROMPT: &str = r#"You are a context compaction summarizer. Your job is to distill a conversation transcript into a dense summary that preserves all information needed to continue the conversation.

## Instructions

Analyze the provided conversation transcript and return a JSON object with two fields:
1. `narrative` — a prose summary (2-5 paragraphs) capturing the full context
2. `extractedData` — structured metadata extracted from the conversation

## Priority Order for Narrative

1. **User's goal** — What are they trying to accomplish?
2. **What was accomplished** — Concrete results, not process
3. **Decisions and rationale** — Why specific approaches were chosen
4. **File changes** — What was created, modified, or deleted
5. **Pending work** — What still needs to be done
6. **Constraints and preferences** — User-stated requirements

## Output Format

Return a single JSON object:
{
  "narrative": "Dense prose summary...",
  "extractedData": {
    "currentGoal": "The main task being worked on",
    "completedSteps": ["Step 1", "Step 2"],
    "pendingTasks": ["Remaining task 1"],
    "keyDecisions": [{"decision": "What", "reason": "Why"}],
    "filesModified": ["path/to/file.ts"],
    "topicsDiscussed": ["topic1", "topic2"],
    "userPreferences": ["preference or constraint"],
    "importantContext": ["critical context to preserve"],
    "thinkingInsights": ["key reasoning insights"]
  }
}

## Rules

- Return ONLY valid JSON — no markdown fences, no explanation text
- The narrative must be self-contained: a reader with no prior context should understand the full situation
- Preserve specific values: file paths, variable names, error messages, URLs, command outputs
- Do NOT summarize tool results as "the tool succeeded" — include what the result was
- Omit empty arrays from extractedData rather than including []
- Be concise but complete — every sentence should carry information"#;

/// System prompt for the memory retain summarizer subagent.
///
/// Used by the `memory.retain` RPC handler to produce structured markdown
/// summaries optimized for future recall, not context reduction.
pub const MEMORY_RETAIN_SUMMARIZER_PROMPT: &str = "You are a memory archivist for an AI coding agent. Your job is to produce a structured session summary that will be stored in long-term memory and recalled in future sessions to provide continuity.\n\
\n\
## Instructions\n\
\n\
Analyze the provided session transcript and output structured markdown. The first line must be a short title (under 60 characters) summarizing the session's main goal — this is used as the UI notification title.\n\
\n\
## Output Format\n\
\n\
<title — one line, under 60 chars>\n\
\n\
**Goal**: <what the user was trying to accomplish>\n\
**Model**: <model name if visible, else omit>\n\
\n\
### Completed\n\
- <concrete thing done>\n\
\n\
### Pending\n\
- <remaining task, if any>\n\
\n\
### Key Decisions\n\
- <decision>: <rationale>\n\
\n\
### Files Modified\n\
- <path>\n\
\n\
### Context\n\
<2-4 sentences of narrative context. What was asked, what approach was taken, any important constraints or outcomes.>\n\
\n\
## Rules\n\
\n\
- First line = title only (no heading prefix)\n\
- Be specific: include exact file paths, function names, error messages, command outputs.\n\
- Omit sections that are empty.\n\
- Do NOT include JSON, code fences, or tool call traces.\n\
- Keep the whole summary under 400 words.";

// =============================================================================
// File-Based System Prompt Loading
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
    /// Global `~/.tron/memory/rules/SYSTEM.md`.
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

// =============================================================================
// Global System Prompt — Hash-Based Seeding
// =============================================================================

/// Hash header prefix used to detect unmodified seeded files.
const HASH_HEADER_PREFIX: &str = "<!-- tron-prompt-hash:";
const HASH_HEADER_SUFFIX: &str = " -->";

/// Compute a truncated SHA-256 hex digest of prompt content (16 hex chars).
pub fn compute_prompt_hash(content: &str) -> String {
    let full = Sha256::digest(content.as_bytes());
    // Take first 8 bytes → 16 hex chars
    full[..8].iter().map(|b| format!("{b:02x}")).collect()
}

/// Build the seeded file content: hash header line + prompt body.
///
/// Format: `<!-- tron-prompt-hash:XXXXXXXXXXXXXXXX -->\n{content}`
pub fn build_seeded_content(prompt: &str) -> String {
    let hash = compute_prompt_hash(prompt);
    format!("{HASH_HEADER_PREFIX}{hash}{HASH_HEADER_SUFFIX}\n{prompt}")
}

/// Check if a file's content has been customized by the user.
///
/// Returns `true` if the hash header is missing, malformed, or doesn't match
/// the body content. Returns `false` only when the hash header matches —
/// meaning the file is a pristine seeded copy.
pub fn is_user_customized(file_content: &str) -> bool {
    let Some(first_line) = file_content.lines().next() else {
        return true;
    };

    let Some(hash_value) = first_line
        .strip_prefix(HASH_HEADER_PREFIX)
        .and_then(|rest| rest.strip_suffix(HASH_HEADER_SUFFIX))
    else {
        return true;
    };

    let body = strip_hash_header(file_content);
    let actual_hash = compute_prompt_hash(body);

    hash_value != actual_hash
}

/// Strip the hash header line from file content, returning the prompt body.
///
/// If no hash header is present, returns the full content unchanged.
pub fn strip_hash_header(file_content: &str) -> &str {
    let Some(first_line) = file_content.lines().next() else {
        return file_content;
    };

    if first_line.starts_with(HASH_HEADER_PREFIX) && first_line.ends_with(HASH_HEADER_SUFFIX) {
        // Skip the first line + the newline separator
        &file_content[first_line.len().min(file_content.len())..]
            .strip_prefix('\n')
            .unwrap_or("")
    } else {
        file_content
    }
}

/// Seed or update the global `SYSTEM.md` file.
///
/// - File doesn't exist → create with hash header + `TRON_CORE_PROMPT`
/// - File exists, not customized (hash matches) → overwrite with latest
/// - File exists, customized → leave alone
///
/// Returns `true` if the file was written, `false` otherwise.
pub fn seed_global_system_prompt(tron_home: &Path) -> bool {
    let path = tron_home
        .join("memory")
        .join("rules")
        .join("SYSTEM.md");

    if let Ok(existing) = fs::read_to_string(&path) {
        if is_user_customized(&existing) {
            debug!(path = %path.display(), "Global SYSTEM.md is user-customized, leaving unchanged");
            return false;
        }
        // Pristine — check if content matches current embedded prompt
        let body = strip_hash_header(&existing);
        if body == TRON_CORE_PROMPT {
            return false; // Already up to date
        }
        debug!(path = %path.display(), "Updating pristine global SYSTEM.md to latest version");
    }

    let content = build_seeded_content(TRON_CORE_PROMPT);
    match fs::write(&path, &content) {
        Ok(()) => {
            debug!(path = %path.display(), "Seeded global SYSTEM.md");
            true
        }
        Err(e) => {
            warn!(path = %path.display(), error = %e, "Failed to seed global SYSTEM.md");
            false
        }
    }
}

/// Load the global system prompt from a given home directory.
///
/// Looks for `{home}/.tron/memory/rules/SYSTEM.md`. Strips the hash header
/// if present. Returns `None` if the file is missing, empty, or oversized.
#[must_use]
pub fn load_global_system_prompt_from(home: &Path) -> Option<LoadedSystemPrompt> {
    let path = home.join(".tron").join("memory").join("rules").join("SYSTEM.md");

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
            let body = strip_hash_header(&content).to_owned();
            if body.trim().is_empty() {
                return None;
            }
            debug!(path = %path.display(), "Loaded global system prompt");
            Some(LoadedSystemPrompt {
                content: body,
                source: SystemPromptSource::Global,
            })
        }
        Err(_) => None,
    }
}

/// Load the global system prompt from `~/.tron/memory/rules/SYSTEM.md`.
///
/// Convenience wrapper around [`load_global_system_prompt_from`] using the
/// user's home directory.
#[must_use]
pub fn load_global_system_prompt() -> Option<LoadedSystemPrompt> {
    let home = crate::core::paths::home_dir();
    load_global_system_prompt_from(Path::new(&home))
}

// =============================================================================
// Provider-Specific System Prompt Builders
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
        let base = config.custom_prompt.as_deref().unwrap_or(TRON_CORE_PROMPT);
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
    let base = config.custom_prompt.as_deref().unwrap_or(TRON_CORE_PROMPT);

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

    // ── Core prompt ──────────────────────────────────────────────────────

    #[test]
    fn core_prompt_is_non_empty() {
        assert!(!TRON_CORE_PROMPT.is_empty());
        assert!(TRON_CORE_PROMPT.len() > 1000);
    }

    #[test]
    fn working_directory_suffix_has_placeholder() {
        assert!(WORKING_DIRECTORY_SUFFIX.contains("{workingDirectory}"));
    }

    #[test]
    fn chat_prompt_is_non_empty() {
        assert!(!TRON_CHAT_PROMPT.is_empty());
        assert!(TRON_CHAT_PROMPT.len() > 500);
        assert!(TRON_CHAT_PROMPT.contains("Tron"));
    }

    // ── Subagent prompts ─────────────────────────────────────────────────

    #[test]
    fn compaction_summarizer_prompt_non_empty() {
        assert!(!COMPACTION_SUMMARIZER_PROMPT.is_empty());
        assert!(COMPACTION_SUMMARIZER_PROMPT.contains("JSON"));
        assert!(COMPACTION_SUMMARIZER_PROMPT.contains("narrative"));
        assert!(COMPACTION_SUMMARIZER_PROMPT.contains("extractedData"));
    }

    #[test]
    fn memory_retain_summarizer_prompt_non_empty() {
        assert!(!MEMORY_RETAIN_SUMMARIZER_PROMPT.is_empty());
        assert!(MEMORY_RETAIN_SUMMARIZER_PROMPT.contains("Goal"));
        assert!(MEMORY_RETAIN_SUMMARIZER_PROMPT.contains("Completed"));
        assert!(MEMORY_RETAIN_SUMMARIZER_PROMPT.contains("Context"));
        assert!(MEMORY_RETAIN_SUMMARIZER_PROMPT.contains("title"));
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
        assert!(prompt.contains(TRON_CORE_PROMPT));
        assert!(prompt.contains("/tmp/project"));
        assert!(!prompt.is_empty());
    }

    #[test]
    fn build_openai_prompt() {
        let config = make_config(Provider::OpenAi);
        let prompt = build_system_prompt(&config);
        assert!(prompt.contains(TRON_CORE_PROMPT));
        assert!(prompt.contains("/tmp/project"));
    }

    #[test]
    fn build_google_prompt() {
        let config = make_config(Provider::Google);
        let prompt = build_system_prompt(&config);
        assert!(prompt.contains(TRON_CORE_PROMPT));
        assert!(prompt.contains("/tmp/project"));
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
        assert!(clarification.contains(TRON_CORE_PROMPT));
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
        assert!(!prompt.contains(TRON_CORE_PROMPT));
        assert!(prompt.contains("/tmp"));
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

    // ── Hash helpers ────────────────────────────────────────────────────

    #[test]
    fn hash_is_deterministic() {
        let h1 = compute_prompt_hash("hello world");
        let h2 = compute_prompt_hash("hello world");
        assert_eq!(h1, h2);
    }

    #[test]
    fn hash_differs_for_different_input() {
        let h1 = compute_prompt_hash("hello");
        let h2 = compute_prompt_hash("world");
        assert_ne!(h1, h2);
    }

    #[test]
    fn hash_is_16_hex_chars() {
        let h = compute_prompt_hash("test content");
        assert_eq!(h.len(), 16);
        assert!(h.chars().all(|c| c.is_ascii_hexdigit()));
    }

    #[test]
    fn build_seeded_content_starts_with_hash_line() {
        let content = build_seeded_content("My prompt");
        let first_line = content.lines().next().unwrap();
        assert!(first_line.starts_with(HASH_HEADER_PREFIX));
        assert!(first_line.ends_with(HASH_HEADER_SUFFIX));
    }

    #[test]
    fn build_seeded_content_body_matches_input() {
        let prompt = "My custom prompt\nwith multiple lines";
        let content = build_seeded_content(prompt);
        let body = strip_hash_header(&content);
        assert_eq!(body, prompt);
    }

    #[test]
    fn build_seeded_content_roundtrip_not_customized() {
        let content = build_seeded_content("Some prompt text");
        assert!(!is_user_customized(&content));
    }

    #[test]
    fn is_user_customized_returns_true_for_edited_body() {
        let mut content = build_seeded_content("Original prompt");
        content.push_str("\nUser added this line");
        assert!(is_user_customized(&content));
    }

    #[test]
    fn is_user_customized_returns_true_for_no_header() {
        assert!(is_user_customized("Just a plain prompt with no header"));
    }

    #[test]
    fn is_user_customized_returns_true_for_empty_string() {
        assert!(is_user_customized(""));
    }

    #[test]
    fn is_user_customized_returns_true_for_tampered_hash() {
        let content = format!(
            "{HASH_HEADER_PREFIX}0000000000000000{HASH_HEADER_SUFFIX}\nSome body"
        );
        assert!(is_user_customized(&content));
    }

    #[test]
    fn is_user_customized_returns_false_for_pristine() {
        let content = build_seeded_content("Pristine prompt");
        assert!(!is_user_customized(&content));
    }

    #[test]
    fn strip_hash_header_removes_header() {
        let content = build_seeded_content("body text");
        assert_eq!(strip_hash_header(&content), "body text");
    }

    #[test]
    fn strip_hash_header_no_header_returns_full() {
        let text = "No header here\nJust text";
        assert_eq!(strip_hash_header(text), text);
    }

    #[test]
    fn strip_hash_header_empty_string() {
        assert_eq!(strip_hash_header(""), "");
    }

    #[test]
    fn build_seeded_content_with_core_prompt() {
        let content = build_seeded_content(TRON_CORE_PROMPT);
        assert!(!is_user_customized(&content));
        assert_eq!(strip_hash_header(&content), TRON_CORE_PROMPT);
    }

    // ── Seed function ───────────────────────────────────────────────────

    #[test]
    fn seed_creates_file_when_missing() {
        let dir = tempfile::tempdir().unwrap();
        let rules_dir = dir.path().join("memory").join("rules");
        fs::create_dir_all(&rules_dir).unwrap();

        assert!(seed_global_system_prompt(dir.path()));
        assert!(rules_dir.join("SYSTEM.md").exists());
    }

    #[test]
    fn seed_created_file_is_not_user_customized() {
        let dir = tempfile::tempdir().unwrap();
        let rules_dir = dir.path().join("memory").join("rules");
        fs::create_dir_all(&rules_dir).unwrap();

        seed_global_system_prompt(dir.path());
        let content = fs::read_to_string(rules_dir.join("SYSTEM.md")).unwrap();
        assert!(!is_user_customized(&content));
    }

    #[test]
    fn seed_created_file_body_is_core_prompt() {
        let dir = tempfile::tempdir().unwrap();
        let rules_dir = dir.path().join("memory").join("rules");
        fs::create_dir_all(&rules_dir).unwrap();

        seed_global_system_prompt(dir.path());
        let content = fs::read_to_string(rules_dir.join("SYSTEM.md")).unwrap();
        assert_eq!(strip_hash_header(&content), TRON_CORE_PROMPT);
    }

    #[test]
    fn seed_updates_pristine_file_with_different_hash() {
        let dir = tempfile::tempdir().unwrap();
        let rules_dir = dir.path().join("memory").join("rules");
        fs::create_dir_all(&rules_dir).unwrap();

        // Write a pristine file with different content (simulating old version)
        let old_content = build_seeded_content("Old embedded prompt");
        fs::write(rules_dir.join("SYSTEM.md"), &old_content).unwrap();

        // Seed should overwrite since it's not customized and body differs
        assert!(seed_global_system_prompt(dir.path()));
        let new_content = fs::read_to_string(rules_dir.join("SYSTEM.md")).unwrap();
        assert_eq!(strip_hash_header(&new_content), TRON_CORE_PROMPT);
    }

    #[test]
    fn seed_preserves_customized_file() {
        let dir = tempfile::tempdir().unwrap();
        let rules_dir = dir.path().join("memory").join("rules");
        fs::create_dir_all(&rules_dir).unwrap();

        let custom = "My fully custom prompt";
        fs::write(rules_dir.join("SYSTEM.md"), custom).unwrap();

        assert!(!seed_global_system_prompt(dir.path()));
        let content = fs::read_to_string(rules_dir.join("SYSTEM.md")).unwrap();
        assert_eq!(content, custom);
    }

    #[test]
    fn seed_preserves_file_without_hash_header() {
        let dir = tempfile::tempdir().unwrap();
        let rules_dir = dir.path().join("memory").join("rules");
        fs::create_dir_all(&rules_dir).unwrap();

        let manual = "Manually created SYSTEM.md\nwith custom content";
        fs::write(rules_dir.join("SYSTEM.md"), manual).unwrap();

        assert!(!seed_global_system_prompt(dir.path()));
        assert_eq!(
            fs::read_to_string(rules_dir.join("SYSTEM.md")).unwrap(),
            manual
        );
    }

    #[test]
    fn seed_returns_true_on_write_false_on_skip() {
        let dir = tempfile::tempdir().unwrap();
        let rules_dir = dir.path().join("memory").join("rules");
        fs::create_dir_all(&rules_dir).unwrap();

        // First call creates → true
        assert!(seed_global_system_prompt(dir.path()));
        // Second call, already up to date → false
        assert!(!seed_global_system_prompt(dir.path()));
    }

    #[test]
    fn seed_handles_empty_existing_file() {
        let dir = tempfile::tempdir().unwrap();
        let rules_dir = dir.path().join("memory").join("rules");
        fs::create_dir_all(&rules_dir).unwrap();

        fs::write(rules_dir.join("SYSTEM.md"), "").unwrap();

        // Empty file is treated as customized → not overwritten
        assert!(!seed_global_system_prompt(dir.path()));
    }

    #[test]
    fn seed_handles_missing_parent_dir() {
        let dir = tempfile::tempdir().unwrap();
        // Don't create memory/rules/ — seed should handle gracefully
        assert!(!seed_global_system_prompt(dir.path()));
    }

    #[test]
    fn seed_idempotent_when_pristine() {
        let dir = tempfile::tempdir().unwrap();
        let rules_dir = dir.path().join("memory").join("rules");
        fs::create_dir_all(&rules_dir).unwrap();

        let _ = seed_global_system_prompt(dir.path());
        let first = fs::read_to_string(rules_dir.join("SYSTEM.md")).unwrap();

        let _ = seed_global_system_prompt(dir.path());
        let second = fs::read_to_string(rules_dir.join("SYSTEM.md")).unwrap();

        assert_eq!(first, second);
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
        let rules_dir = dir.path().join(".tron").join("memory").join("rules");
        fs::create_dir_all(&rules_dir).unwrap();
        fs::write(rules_dir.join("SYSTEM.md"), "Custom global prompt").unwrap();

        let loaded = load_global_system_prompt_from(dir.path()).unwrap();
        assert_eq!(loaded.content, "Custom global prompt");
    }

    #[test]
    fn load_global_strips_hash_header() {
        let dir = tempfile::tempdir().unwrap();
        let rules_dir = dir.path().join(".tron").join("memory").join("rules");
        fs::create_dir_all(&rules_dir).unwrap();

        let seeded = build_seeded_content("Prompt body");
        fs::write(rules_dir.join("SYSTEM.md"), &seeded).unwrap();

        let loaded = load_global_system_prompt_from(dir.path()).unwrap();
        assert_eq!(loaded.content, "Prompt body");
        assert!(!loaded.content.contains(HASH_HEADER_PREFIX));
    }

    #[test]
    fn load_global_source_is_global() {
        let dir = tempfile::tempdir().unwrap();
        let rules_dir = dir.path().join(".tron").join("memory").join("rules");
        fs::create_dir_all(&rules_dir).unwrap();
        fs::write(rules_dir.join("SYSTEM.md"), "prompt").unwrap();

        let loaded = load_global_system_prompt_from(dir.path()).unwrap();
        assert_eq!(loaded.source, SystemPromptSource::Global);
    }

    #[test]
    fn load_global_rejects_oversized_file() {
        let dir = tempfile::tempdir().unwrap();
        let rules_dir = dir.path().join(".tron").join("memory").join("rules");
        fs::create_dir_all(&rules_dir).unwrap();
        let big = "x".repeat(150_000);
        fs::write(rules_dir.join("SYSTEM.md"), big).unwrap();

        assert!(load_global_system_prompt_from(dir.path()).is_none());
    }

    #[test]
    fn load_global_returns_customized_content_as_is() {
        let dir = tempfile::tempdir().unwrap();
        let rules_dir = dir.path().join(".tron").join("memory").join("rules");
        fs::create_dir_all(&rules_dir).unwrap();

        let custom = "User's custom prompt\nwith multiple lines";
        fs::write(rules_dir.join("SYSTEM.md"), custom).unwrap();

        let loaded = load_global_system_prompt_from(dir.path()).unwrap();
        assert_eq!(loaded.content, custom);
    }

    #[test]
    fn load_global_returns_none_for_empty_file() {
        let dir = tempfile::tempdir().unwrap();
        let rules_dir = dir.path().join(".tron").join("memory").join("rules");
        fs::create_dir_all(&rules_dir).unwrap();
        fs::write(rules_dir.join("SYSTEM.md"), "").unwrap();

        assert!(load_global_system_prompt_from(dir.path()).is_none());
    }
}
