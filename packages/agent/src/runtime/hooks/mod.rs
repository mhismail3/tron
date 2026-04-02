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
//! background, never blocks the main agent.
//!
//! ```text
//! ---
//! type: session-start
//! label: Generate session title
//! ---
//! Generate a concise 3-6 word title for this session...
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
//! `pre-tool-use`, `post-tool-use`, `pre-compact`, `subagent-stop`,
//! `notification`
//!
//! # Built-in Hooks
//!
//! Platform hooks registered programmatically in [`builtin`]. Users can
//! enable/disable them via `settings.hooks.builtinHooks`. Current builtins:
//!
//! - `builtin:title-gen` — auto-generates session titles on session start
//!
//! # Hot Reload
//!
//! Hooks are discovered fresh each session in [`agent_prompt_service`].
//! Adding, removing, or editing hook files takes effect on the next session
//! without server restart.
//!
//! # Submodules
//!
//! | Module | Purpose |
//! |--------|---------|
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
