//! Lifecycle hook engine for the Tron agent.
//!
//! # Hook Files
//!
//! All hooks are defined as files in `~/.tron/hooks/` (user-level) or
//! `.tron/hooks/` (project-level). Two kinds:
//!
//! ## Script Hooks (`.sh`, `.js`, `.ts`)
//!
//! Receive [`HookContext`](types::HookContext) JSON on **stdin**, return
//! [`HookResult`](types::HookResult) JSON on **stdout**. Fail-open on
//! all error paths (timeout, bad exit, parse failure).
//!
//! ```text
//! ~/.tron/hooks/
//! ├── session-start.sh            # fires on session start
//! ├── 100-pre-tool-use.sh         # priority 100 (higher = runs first)
//! └── post-tool-use.js            # node script
//! ```
//!
//! ## LLM Prompt Hooks (`.prompt`)
//!
//! Optional YAML frontmatter (`label`, `enabled`) + prompt body.
//! Spawned as async subsessions via [`SubagentManager`]. Always
//! background, never blocks the main agent.
//!
//! ```text
//! ---
//! label: Generate session title
//! enabled: true
//! ---
//! Generate a concise 3-6 word title for this session...
//! ```
//!
//! # Naming Convention
//!
//! Filename prefix determines the lifecycle event:
//!
//! | Prefix | Event | Blocking? |
//! |--------|-------|-----------|
//! | `session-start` | Session begins | No |
//! | `stop` | Agent completes | No |
//! | `session-end` | Session cleanup | No |
//! | `user-prompt-submit` | User sends message | Yes |
//! | `pre-tool-use` | Before tool execution | Yes |
//! | `post-tool-use` | After tool execution | No |
//! | `pre-compact` | Before compaction | Yes |
//!
//! Compound names are allowed: `session-start-title.prompt` and
//! `session-start-tags.prompt` both fire on `SessionStart`.
//!
//! Priority prefix: `100-pre-tool-use.sh` runs before `50-pre-tool-use.sh`.
//!
//! # Special: Title Generation
//!
//! Any `.prompt` file with `session-start-title` in its name auto-updates
//! the session title via [`TronEvent::SessionUpdated`].
//!
//! # Submodules
//!
//! | Module | Purpose |
//! |--------|---------|
//! | [`engine`] | `HookEngine` — dispatch, blocking/background partitioning |
//! | [`registry`] | Priority-sorted handler storage per event type |
//! | [`handler`] | `HookHandler` trait all implementations satisfy |
//! | [`script_handler`] | Executes `.sh`/`.js`/`.ts` files via `tokio::process` |
//! | [`prompt_handler`] | Executes `.prompt` files via LLM subsession |
//! | [`discovery`] | Filesystem scanning and `.prompt` file parsing |
//! | [`background`] | Background hook task tracking with drain semantics |
//! | [`context`] | `HookContext` factory for each lifecycle event |
//! | [`errors`] | Hook-specific error types |
//! | [`types`] | Shared types (config, results, discovered hooks) |

pub mod background;
pub mod context;
pub mod discovery;
pub mod engine;
pub mod errors;
pub mod handler;
pub mod prompt_handler;
pub mod registry;
pub mod script_handler;
pub mod types;
