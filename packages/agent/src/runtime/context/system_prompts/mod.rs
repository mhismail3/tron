//! System prompt definitions.
//!
//! Centralized system prompts for Tron agents and subagents. Provider-specific
//! canonical prompts (OAuth prefix, Codex instructions) are handled by each
//! provider crate — this module provides the Tron-specific prompts.
//!
//! ## Prompts
//!
//! - **`core.md`** → [`TRON_CORE_PROMPT`]: Full prompt for cloud models (~5.5K tokens)
//! - **`chat.md`** → [`TRON_CHAT_PROMPT`]: Lightweight chat sessions
//! - **`local.md`** → [`TRON_LOCAL_PROMPT`]: Condensed prompt for local models (~460 tokens)
//!
//! The default core prompt is loaded from `core.md` via [`include_str!`].
//! Users can optionally override at two levels:
//!
//! 1. **Project**: `.tron/SYSTEM.md` in the working directory
//! 2. **Global**: `~/.tron/workspace/memory/rules/SYSTEM.md` (manually created)
//!
//! Precedence: project override > global override > embedded default.
//! For Ollama models, the default is `TRON_LOCAL_PROMPT` instead of `TRON_CORE_PROMPT`.
//!
//! The server does NOT auto-seed `SYSTEM.md` — the embedded prompts are used
//! directly. Override files are opt-in for users who want customization.

use std::fs;
use std::path::Path;

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

/// Chat system prompt for lightweight conversational sessions.
///
/// Used when `session.source == "chat"` (quick chat sessions).
/// Not scoped to a project — no rules or workspace context loaded.
pub const TRON_CHAT_PROMPT: &str = include_str!("chat.md");

/// Condensed system prompt for local models (Ollama).
///
/// ~1,500 tokens vs ~5,500 for `core.md`. Keeps tool routing, file operation
/// rules, bash/git safety, and communication style. Cuts identity philosophy,
/// memory management, digital identity, filesystem boundaries, path references,
/// and specialized tool sections (subagents, containers, self-deployment).
pub const TRON_LOCAL_PROMPT: &str = include_str!("local.md");

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
- Be concise but complete — every sentence should carry information
- If skills were used (referenced with @skill-name), note which skills were active for context, but do NOT instruct the reader to continue using them. Skills are managed separately and may not be available after compaction"#;

/// System prompt for the memory retain summarizer subagent.
///
/// Used by the `memory.retain` RPC handler as a smart router that produces
/// up to three structured sections: journal (always), core memory (conditional),
/// and argument (conditional). The handler parses `<journal>`, `<core_memory>`,
/// and `<argument>` tags from the output.
pub const MEMORY_RETAIN_SUMMARIZER_PROMPT: &str = r#"You are a memory archivist for an AI agent named Tron. Analyze the provided session transcript and produce structured output with up to three sections.

## Section 1: Journal (ALWAYS produce this)

Wrap in <journal>...</journal> tags. The caller owns the file header and
timestamp range — do NOT emit any heading markers (`#`) or dates yourself.
The first line of your output MUST be just the title text.

Format:

{Title under 60 chars}

**Goal**: what the user was trying to accomplish

### Completed
- concrete things done

### Key Decisions
- decision: rationale

### Files Modified
- path (if applicable)

### Context
2-4 sentences of narrative.

## Section 2: Core Memory (ONLY if timeless identity facts were revealed)

Wrap in <core_memory>...</core_memory> tags. Only produce this if the conversation revealed something genuinely timeless about the user's identity, preferences, working style, or the agent's own behavioral patterns. NOT for ephemeral task details.

file: {filename, e.g. user-preferences.md or tron-identity.md}
update: {concise statement to add, e.g. "Prefers systems thinking and first-principles reasoning"}

## Section 3: Argument (ONLY if knowledge topics were discussed)

Wrap in <argument>...</argument> tags. Only produce this if the conversation involved substantive discussion connecting ideas, topics, or sources from the knowledge base at ~/.tron/workspace/knowledge/.

title: {descriptive title}
thesis: {core connection or insight}
topics: [topic-slug-1, topic-slug-2]
sources: [source-slug-1]
evidence:
- How topic-a connects to topic-b
- Supporting evidence from sources

## Rules

- Journal section is MANDATORY. Sections 2 and 3 are conditional.
- The first line of the journal MUST be the title text only (no `#`, no date, no timestamp).
- Be specific: include exact file paths, function names, decisions.
- Omit empty subsections within journal.
- Keep journal under 400 words.
- Core memory updates must be genuinely timeless — not task-specific.
- Arguments must articulate a thesis, not just summarize.
- If no knowledge topics were discussed, omit the argument section entirely.
- If no identity-relevant facts were revealed, omit the core memory section entirely.
- Do NOT include JSON, code fences, or tool call traces."#;

/// Git workflow prompt block — injected conditionally when the session
/// has an active worktree.
///
/// Teaches the LLM:
/// - it is inside an isolated session branch in a worktree (not on `main`);
/// - how to reason about source-control state via standard `git` commands;
/// - which destructive operations are reserved for the user's Source
///   Control sheet (sync, push, switch, finalize merge) — the agent does
///   not drive those directly.
pub const GIT_WORKFLOW_PROMPT: &str = r#"
## Git Workflow

You are running inside an **isolated git worktree** on a dedicated session branch — **not** on the user's `main`. Every file edit lands in that worktree; the user's editor at the repo root is untouched until the user chooses to finalise via the iOS Source Control sheet.

### What you do directly

Use `Bash` with standard `git` commands for everything source-control related. There are no typed git tools — just `git` via the shell.

Common read-only inspection:

- `git status` — working tree state.
- `git diff` / `git diff --cached` — unstaged / staged changes.
- `git log --oneline -20` — recent history on the current branch.
- `git branch --show-current` — the session branch name.
- `git log --oneline <branch>..HEAD` — commits on this branch vs another.

Making commits as you work:

- `git add <path>` (or `git add -A` when appropriate) followed by `git commit -m "<message>"`.
- Commit small, logical units. The user reviews your branch in the Source Control sheet before finalising.

### What the user drives (do NOT do these yourself)

These operations belong to the user via the Source Control sheet. Don't run them from `Bash`:

- `git push` — the user decides when to publish the branch.
- `git merge <session> → main`, `git rebase --onto main`, finalizing a session — the user drives finalize from the sheet.
- `git fetch origin` + fast-forwarding `main` — the user taps "Sync Main".
- `git checkout <other-branch>` / `git switch <other-branch>` — the user drives branch switching from the sheet.

If you believe one of these is needed to make progress, tell the user what you want them to do and why — **don't** shell out to do it yourself.

### Merge conflicts

If a merge or rebase is in progress and produces conflicts (you'll see `<<<<<<<` / `=======` / `>>>>>>>` markers in files, and `git status` will report `Unmerged paths`):

1. Enumerate: `git diff --name-only --diff-filter=U`.
2. For each conflicted file, resolve using one of:
   - `git checkout --ours -- <path> && git add -- <path>` (keep this branch's version wholesale),
   - `git checkout --theirs -- <path> && git add -- <path>` (keep incoming version wholesale),
   - `Edit` the file manually to produce marker-free merged content, then `git add -- <path>`.
3. When `git diff --name-only --diff-filter=U` is empty: finish with `git commit --no-edit` (merge) or `git rebase --continue` (rebase).
4. Abort path (last resort): `git merge --abort` or `git rebase --abort`.

Note: the user can instead delegate conflict resolution to a dedicated subagent from the Source Control sheet — that's usually preferable for large conflict sets.

### Hard rules

- **NEVER** run destructive operations on uncommitted work: `git reset --hard`, `git checkout --`, `git clean -f`, `git restore --staged` on files you didn't modify, etc. Ask the user first.
- **NEVER** force-push (`--force`, `--force-with-lease`) anywhere. This is the user's decision from the Source Control sheet if needed.
- **NEVER** push to a protected branch (`main`, `master`, `develop`).
- **NEVER** edit `.git/` directly.
- The user's editor is still open at the repo root on `main`. Changes you make inside the session worktree are invisible there until the user finalises.
"#;

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
    /// Global `~/.tron/workspace/memory/rules/SYSTEM.md`.
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
/// Looks for `{home}/.tron/workspace/memory/rules/SYSTEM.md`.
/// Returns `None` if the file is missing, empty, or oversized.
///
/// Users can manually create this file to override the embedded core prompt.
/// The server no longer auto-seeds it — if the file doesn't exist, the
/// embedded `TRON_CORE_PROMPT` is used directly.
#[must_use]
pub fn load_global_system_prompt_from(home: &Path) -> Option<LoadedSystemPrompt> {
    use crate::core::paths::{dirs, files};
    let path = home
        .join(".tron")
        .join(dirs::WORKSPACE)
        .join(dirs::MEMORY)
        .join(dirs::RULES)
        .join(files::SYSTEM_MD);

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

/// Load the global system prompt from `~/.tron/workspace/memory/rules/SYSTEM.md`.
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
    fn chat_prompt_is_non_empty() {
        assert!(!TRON_CHAT_PROMPT.is_empty());
        assert!(TRON_CHAT_PROMPT.len() > 500);
    }

    #[test]
    fn local_prompt_is_non_empty() {
        assert!(!TRON_LOCAL_PROMPT.is_empty());
        assert!(TRON_LOCAL_PROMPT.len() > 500);
    }

    #[test]
    fn local_prompt_is_smaller_than_core() {
        assert!(TRON_LOCAL_PROMPT.len() < TRON_CORE_PROMPT.len() / 2);
    }

    #[test]
    fn local_prompt_has_essential_sections() {
        assert!(TRON_LOCAL_PROMPT.contains("Tool routing"));
        assert!(TRON_LOCAL_PROMPT.contains("File operations"));
        assert!(TRON_LOCAL_PROMPT.contains("Bash"));
        assert!(TRON_LOCAL_PROMPT.contains("Git rules"));
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
    fn memory_retain_summarizer_prompt_non_empty() {
        assert!(!MEMORY_RETAIN_SUMMARIZER_PROMPT.is_empty());
        assert!(MEMORY_RETAIN_SUMMARIZER_PROMPT.contains("Goal"));
        assert!(MEMORY_RETAIN_SUMMARIZER_PROMPT.contains("Completed"));
        assert!(MEMORY_RETAIN_SUMMARIZER_PROMPT.contains("Context"));
        assert!(MEMORY_RETAIN_SUMMARIZER_PROMPT.contains("title"));
    }

    #[test]
    fn git_workflow_prompt_covers_key_surface() {
        assert!(!GIT_WORKFLOW_PROMPT.is_empty());
        // Section heading so it renders correctly when appended to memory.
        assert!(GIT_WORKFLOW_PROMPT.contains("## Git Workflow"));
        // The prompt must NOT mention the now-removed typed git tools —
        // a regression there would teach the LLM to call non-existent
        // tools and fail noisily at runtime.
        for removed in [
            "WorktreeStatus",
            "GitSyncMain",
            "GitPush",
            "GitSwitch",
            "GitMergeSession",
            "GitConflict",
        ] {
            assert!(
                !GIT_WORKFLOW_PROMPT.contains(removed),
                "GIT_WORKFLOW_PROMPT must not reference removed tool `{removed}`"
            );
        }
        // Core raw-git guidance the agent needs so it doesn't have to
        // guess the shape of the workflow.
        for needle in [
            "isolated git worktree",
            "git status",
            "git add",
            "git commit",
            "<<<<<<<",
            "Source Control sheet",
        ] {
            assert!(
                GIT_WORKFLOW_PROMPT.contains(needle),
                "GIT_WORKFLOW_PROMPT must mention `{needle}`"
            );
        }
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

    // ── Global prompt loading ───────────────────────────────────────────

    #[test]
    fn load_global_returns_none_when_file_missing() {
        let dir = tempfile::tempdir().unwrap();
        assert!(load_global_system_prompt_from(dir.path()).is_none());
    }

    #[test]
    fn load_global_returns_content_when_file_exists() {
        let dir = tempfile::tempdir().unwrap();
        let rules_dir = dir
            .path()
            .join(".tron")
            .join(crate::core::paths::dirs::WORKSPACE)
            .join(crate::core::paths::dirs::MEMORY)
            .join(crate::core::paths::dirs::RULES);
        fs::create_dir_all(&rules_dir).unwrap();
        fs::write(rules_dir.join("SYSTEM.md"), "Custom global prompt").unwrap();

        let loaded = load_global_system_prompt_from(dir.path()).unwrap();
        assert_eq!(loaded.content, "Custom global prompt");
    }

    #[test]
    fn load_global_source_is_global() {
        let dir = tempfile::tempdir().unwrap();
        let rules_dir = dir
            .path()
            .join(".tron")
            .join(crate::core::paths::dirs::WORKSPACE)
            .join(crate::core::paths::dirs::MEMORY)
            .join(crate::core::paths::dirs::RULES);
        fs::create_dir_all(&rules_dir).unwrap();
        fs::write(rules_dir.join("SYSTEM.md"), "prompt").unwrap();

        let loaded = load_global_system_prompt_from(dir.path()).unwrap();
        assert_eq!(loaded.source, SystemPromptSource::Global);
    }

    #[test]
    fn load_global_rejects_oversized_file() {
        let dir = tempfile::tempdir().unwrap();
        let rules_dir = dir
            .path()
            .join(".tron")
            .join(crate::core::paths::dirs::WORKSPACE)
            .join(crate::core::paths::dirs::MEMORY)
            .join(crate::core::paths::dirs::RULES);
        fs::create_dir_all(&rules_dir).unwrap();
        let big = "x".repeat(150_000);
        fs::write(rules_dir.join("SYSTEM.md"), big).unwrap();

        assert!(load_global_system_prompt_from(dir.path()).is_none());
    }

    #[test]
    fn load_global_returns_none_for_empty_file() {
        let dir = tempfile::tempdir().unwrap();
        let rules_dir = dir
            .path()
            .join(".tron")
            .join(crate::core::paths::dirs::WORKSPACE)
            .join(crate::core::paths::dirs::MEMORY)
            .join(crate::core::paths::dirs::RULES);
        fs::create_dir_all(&rules_dir).unwrap();
        fs::write(rules_dir.join("SYSTEM.md"), "").unwrap();

        assert!(load_global_system_prompt_from(dir.path()).is_none());
    }
}
