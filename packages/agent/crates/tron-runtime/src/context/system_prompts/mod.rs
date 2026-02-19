//! System prompt definitions.
//!
//! Centralized system prompts for Tron agents and subagents. Provider-specific
//! canonical prompts (OAuth prefix, Codex instructions) are handled by each
//! provider crate — this module provides the Tron-specific prompts.
//!
//! The default core prompt is loaded from `core.md` via [`include_str!`].
//! Users can override by creating `.tron/SYSTEM.md` in their project directory.

use std::fs;
use std::path::Path;

use tracing::{debug, warn};

use tron_core::messages::ProviderType;

use super::constants::MAX_SYSTEM_PROMPT_FILE_SIZE;

// =============================================================================
// Core Prompt
// =============================================================================

/// Core Tron system prompt defining the assistant's role and capabilities.
///
/// Loaded from `core.md` at compile time. Users can override at runtime by
/// creating `.tron/SYSTEM.md` in their project directory.
pub const TRON_CORE_PROMPT: &str = include_str!("core.md");

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

/// System prompt for the memory ledger subagent.
///
/// Used by the memory manager's Haiku subagent to write structured ledger
/// entries summarizing response cycles.
pub const MEMORY_LEDGER_PROMPT: &str = r#"You are a memory indexer. Analyze the provided session events and decide whether this response cycle is worth recording in the session ledger.

## Instructions

1. Read the events provided (user prompt, tool calls, assistant response, thinking blocks)
2. Decide: is this worth recording? Skip trivial interactions:
   - Simple greetings or pleasantries
   - Clarification questions with no action taken
   - "Yes/No" confirmations with no substantive work
3. If worth recording, return a JSON object (no markdown fencing)
4. If not worth recording, return: {"skip": true}

## Output Format (when recording)

Return a single JSON object:
{
  "title": "Short descriptive title (under 80 chars)",
  "entryType": "feature|bugfix|refactor|docs|config|research|conversation",
  "status": "completed|partial|in_progress",
  "tags": ["relevant", "tags"],
  "input": "What the user asked for (1 sentence)",
  "actions": ["What was done (1-3 bullet points)"],
  "files": [{"path": "relative/path", "op": "C|M|D", "why": "purpose"}],
  "decisions": [{"choice": "What was chosen", "reason": "Why"}],
  "lessons": ["Patterns or insights worth remembering"],
  "thinkingInsights": ["Key reasoning from thinking blocks"]
}

## Rules

- Be concise — this is a metadata index, not a transcript
- Focus on WHAT changed and WHY
- Extract thinking insights that explain non-obvious decisions
- File paths should be relative to the working directory
- Tags should be lowercase, no spaces
- Return ONLY valid JSON, no explanation text"#;

/// System prompt for the web content summarizer subagent.
///
/// Used by `WebFetch`'s Haiku subagent to answer questions about fetched
/// web page content.
pub const WEB_CONTENT_SUMMARIZER_PROMPT: &str = "You are a web content analyzer. Your task is to answer questions about web page content concisely and accurately.

Instructions:
- Answer based ONLY on the content provided
- Be concise but thorough
- If the content doesn't contain the answer, say so clearly
- Do not make up information not present in the content";

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
// Provider-Specific System Prompt Builders
// =============================================================================

/// Configuration for building system prompts.
#[derive(Debug, Clone)]
pub struct SystemPromptConfig {
    /// Provider type.
    pub provider_type: ProviderType,
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
    if config.provider_type == ProviderType::OpenAiCodex {
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
pub fn requires_tool_clarification(provider_type: &ProviderType) -> bool {
    *provider_type == ProviderType::OpenAiCodex
}

/// Get the tool clarification message for providers that need it.
///
/// Returns `None` if the provider uses standard system prompts.
#[must_use]
pub fn get_tool_clarification(config: &SystemPromptConfig) -> Option<String> {
    if config.provider_type == ProviderType::OpenAiCodex {
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

    // ── Subagent prompts ─────────────────────────────────────────────────

    #[test]
    fn compaction_summarizer_prompt_non_empty() {
        assert!(!COMPACTION_SUMMARIZER_PROMPT.is_empty());
        assert!(COMPACTION_SUMMARIZER_PROMPT.contains("JSON"));
        assert!(COMPACTION_SUMMARIZER_PROMPT.contains("narrative"));
        assert!(COMPACTION_SUMMARIZER_PROMPT.contains("extractedData"));
    }

    #[test]
    fn memory_ledger_prompt_non_empty() {
        assert!(!MEMORY_LEDGER_PROMPT.is_empty());
        assert!(MEMORY_LEDGER_PROMPT.contains("memory indexer"));
        assert!(MEMORY_LEDGER_PROMPT.contains("skip"));
    }

    #[test]
    fn web_content_summarizer_prompt_non_empty() {
        assert!(!WEB_CONTENT_SUMMARIZER_PROMPT.is_empty());
        assert!(WEB_CONTENT_SUMMARIZER_PROMPT.contains("web content"));
    }

    // ── System prompt builders ───────────────────────────────────────────

    fn make_config(provider_type: ProviderType) -> SystemPromptConfig {
        SystemPromptConfig {
            provider_type,
            working_directory: "/tmp/project".into(),
            custom_prompt: None,
        }
    }

    #[test]
    fn build_anthropic_prompt() {
        let config = make_config(ProviderType::Anthropic);
        let prompt = build_system_prompt(&config);
        assert!(prompt.contains(TRON_CORE_PROMPT));
        assert!(prompt.contains("/tmp/project"));
        assert!(!prompt.is_empty());
    }

    #[test]
    fn build_openai_prompt() {
        let config = make_config(ProviderType::OpenAi);
        let prompt = build_system_prompt(&config);
        assert!(prompt.contains(TRON_CORE_PROMPT));
        assert!(prompt.contains("/tmp/project"));
    }

    #[test]
    fn build_google_prompt() {
        let config = make_config(ProviderType::Google);
        let prompt = build_system_prompt(&config);
        assert!(prompt.contains(TRON_CORE_PROMPT));
        assert!(prompt.contains("/tmp/project"));
    }

    #[test]
    fn build_codex_prompt_is_empty() {
        let config = make_config(ProviderType::OpenAiCodex);
        let prompt = build_system_prompt(&config);
        assert!(prompt.is_empty());
    }

    #[test]
    fn build_codex_tool_clarification_contains_context() {
        let config = make_config(ProviderType::OpenAiCodex);
        let clarification = build_codex_tool_clarification(&config);
        assert!(clarification.contains("[TRON CONTEXT]"));
        assert!(clarification.contains(TRON_CORE_PROMPT));
        assert!(clarification.contains("/tmp/project"));
        assert!(clarification.contains("NOT available"));
    }

    #[test]
    fn custom_prompt_overrides_core() {
        let config = SystemPromptConfig {
            provider_type: ProviderType::Anthropic,
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
        assert!(requires_tool_clarification(&ProviderType::OpenAiCodex));
    }

    #[test]
    fn non_codex_does_not_require_tool_clarification() {
        assert!(!requires_tool_clarification(&ProviderType::Anthropic));
        assert!(!requires_tool_clarification(&ProviderType::OpenAi));
        assert!(!requires_tool_clarification(&ProviderType::Google));
    }

    #[test]
    fn get_tool_clarification_codex() {
        let config = make_config(ProviderType::OpenAiCodex);
        let result = get_tool_clarification(&config);
        assert!(result.is_some());
        assert!(result.unwrap().contains("[TRON CONTEXT]"));
    }

    #[test]
    fn get_tool_clarification_non_codex() {
        let config = make_config(ProviderType::Anthropic);
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
}
