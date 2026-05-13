//! Lifecycle hook engine for the Tron agent.
//!
//! # Hook Files
//!
//! User hooks live as files in `~/.tron/hooks/` (user-level) or
//! `.tron/hooks/` (project-level). Two kinds:
//!
//! ## Script Hooks (`.sh`, `.js`, `.ts`)
//!
//! Receive [`HookContext`](types::HookContext) JSON on **stdin**, return
//! [`HookResult`](types::HookResult) JSON on **stdout**. Fail-open on
//! all error paths (timeout, bad exit, parse failure).
//!
//! ```text
//! # ---
//! # type: session-start
//! # label: Log session info
//! # ---
//! #!/bin/bash
//! CONTEXT=$(cat)
//! echo '{"action":"continue"}'
//! ```
//!
//! ## LLM Prompt Hooks (`.prompt`)
//!
//! YAML frontmatter (`type`, `label`, `enabled`, `priority`) + prompt body.
//! Spawned as async subsessions via [`SubagentManager`]. Always
//! background — bypasses forced-blocking to never delay the main agent.
//!
//! ```text
//! ---
//! type: stop
//! label: Session summary
//! ---
//! Summarize what happened in this session in one sentence.
//! ```
//!
//! # Frontmatter
//!
//! All metadata lives in YAML frontmatter. Filenames are descriptive only.
//!
//! | Field | Required | Default | Description |
//! |-------|----------|---------|-------------|
//! | `type` | **Yes** | — | Lifecycle event (see below) |
//! | `label` | No | `""` | Human-readable name |
//! | `enabled` | No | `true` | Toggle on/off |
//! | `priority` | No | `0` | Higher runs first |
//!
//! Script files use `# ` or `// ` comment-prefixed frontmatter.
//! Files without valid frontmatter (missing `type:`) are skipped.
//!
//! # Valid `type` Values
//!
//! `session-start`, `session-end`, `stop`, `user-prompt-submit`,
//! `pre-capability-invocation`, `post-capability-invocation`, `pre-compact`, `subagent-stop`,
//! `notification`, `worktree-acquired`
//!
//! # Built-in Hooks
//!
//! Platform hooks registered programmatically in [`builtin`]. Users can
//! enable/disable them via `settings.hooks.builtinHooks`. Current builtins:
//!
//! - `builtin:title-gen` — auto-generates session titles from user prompts
//! - `builtin:branch-name-gen` — renames worktree branches to memorable 3-word names
//! - `builtin:suggest-prompts` — suggests follow-up prompts when the agent finishes
//!
//! `AddContext` hook output is bounded by a fixed engine-level 16384-character
//! per-event budget. The budget is a safety fuse rather than a user setting;
//! over-budget context is dropped all-or-nothing and logged.
//!
//! # Hot Reload
//!
//! Hooks are discovered fresh by the agent domain run-turn bootstrap.
//! Adding, removing, or editing hook files takes effect on the next session
//! without server restart.
//!
//! # Submodules
//!
//! | Module | Purpose |
//! |--------|---------|
//! | [`abort_tracker`] | Abort handles for fire-and-forget hook subsessions |
//! | [`builtin`] | Built-in hook definitions + registration |
//! | [`engine`] | `HookEngine` — dispatch, blocking/background partitioning |
//! | [`registry`] | Priority-sorted handler storage per event type |
//! | [`handler`] | `HookHandler` trait all implementations satisfy |
//! | [`script_handler`] | Executes script files via `tokio::process` |
//! | [`prompt_handler`] | Executes `.prompt` files via LLM subsession |
//! | [`discovery`] | Filesystem scanning + frontmatter parsing |
//! | [`background`] | Background hook task tracking with drain semantics |
//! | [`context`] | `HookContext` factory for each lifecycle event |
//! | [`errors`] | Hook-specific error types |
//! | [`types`] | Shared types (config, results, discovered hooks) |

pub mod abort_tracker;
pub mod background;
pub mod builtin;
pub mod context;
pub mod discovery;
pub mod engine;
pub mod errors;
pub mod handler;
pub mod prompt_handler;
pub mod registry;
pub mod script_handler;
pub mod types;
