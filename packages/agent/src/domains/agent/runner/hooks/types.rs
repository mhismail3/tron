//! Core types for the hook system.
//!
//! Defines hook types, actions, results, execution modes, and context variants
//! for the lifecycle hook system. All context types use `camelCase` serde
//! renaming for wire compatibility with the TypeScript server and iOS client.

use serde::{Deserialize, Serialize};

/// Lifecycle hook type.
///
/// Hooks fire at specific points in the agent's execution lifecycle.
/// Some types are forced-blocking — they can affect agent flow.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum HookType {
    /// Before a tool is executed. Forced-blocking.
    PreToolUse,
    /// After a tool has executed.
    PostToolUse,
    /// When the agent stops.
    Stop,
    /// When a subagent stops.
    SubagentStop,
    /// When a session starts.
    SessionStart,
    /// When a session ends.
    SessionEnd,
    /// When a user submits a prompt. Forced-blocking.
    UserPromptSubmit,
    /// Before context compaction. Forced-blocking.
    PreCompact,
    /// Notification event.
    Notification,
    /// When a worktree is acquired for a session.
    WorktreeAcquired,
}

impl HookType {
    /// Returns `true` if this hook type defaults to blocking mode for all
    /// handlers.
    ///
    /// Forced-blocking hooks can affect agent flow (block a tool call,
    /// modify a prompt, prevent compaction). Running them in the background
    /// would create race conditions.
    ///
    /// Handlers can opt out by returning `true` from
    /// [`HookHandler::bypass_forced_blocking()`], keeping their declared
    /// execution mode. Only handlers that structurally cannot `Block` or
    /// `Modify` should do this.
    #[must_use]
    pub fn is_forced_blocking(self) -> bool {
        matches!(
            self,
            Self::PreToolUse | Self::UserPromptSubmit | Self::PreCompact,
        )
    }

    /// Returns all hook type variants.
    #[must_use]
    pub fn all() -> &'static [HookType] {
        &[
            Self::PreToolUse,
            Self::PostToolUse,
            Self::Stop,
            Self::SubagentStop,
            Self::SessionStart,
            Self::SessionEnd,
            Self::UserPromptSubmit,
            Self::PreCompact,
            Self::Notification,
            Self::WorktreeAcquired,
        ]
    }
}

impl std::fmt::Display for HookType {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::PreToolUse => write!(f, "PreToolUse"),
            Self::PostToolUse => write!(f, "PostToolUse"),
            Self::Stop => write!(f, "Stop"),
            Self::SubagentStop => write!(f, "SubagentStop"),
            Self::SessionStart => write!(f, "SessionStart"),
            Self::SessionEnd => write!(f, "SessionEnd"),
            Self::UserPromptSubmit => write!(f, "UserPromptSubmit"),
            Self::PreCompact => write!(f, "PreCompact"),
            Self::Notification => write!(f, "Notification"),
            Self::WorktreeAcquired => write!(f, "WorktreeAcquired"),
        }
    }
}

/// Action a hook handler can take.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum HookAction {
    /// Continue execution normally.
    Continue,
    /// Block the current operation.
    Block,
    /// Modify the operation with provided modifications (e.g., tool
    /// argument rewriting in PreToolUse).
    Modify,
    /// Append `added_context` to the prompt/turn this hook is firing
    /// on, without otherwise modifying it. Used by hooks that want to
    /// inject context (reminders, policy excerpts, fetched state) into
    /// the next LLM turn. The engine aggregates the `added_context`
    /// field across all `AddContext`-returning hooks before returning
    /// the final `HookResult`. Subject to the engine's fixed
    /// add-context budget — over-budget aggregated content is dropped
    /// with a warn log rather than truncated.
    ///
    /// Serializes as `"add_context"` (snake_case) on the wire so
    /// scripts returning JSON can opt in cleanly.
    AddContext,
}

/// How a hook executes relative to the agent flow.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum HookExecutionMode {
    /// Runs synchronously; agent waits for the result.
    #[default]
    Blocking,
    /// Runs in the background; agent continues immediately.
    Background,
}

/// What to do when a hook handler errors or times out.
///
/// Security / guard hooks that want errors to be treated as policy violations
/// should opt into `Block`. The default is `Continue` (fail-open): errors in
/// a script-based hook are usually developer bugs, not attacks, so the agent
/// proceeds rather than halting every turn on a buggy user script.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum HookErrorPolicy {
    /// On handler error or timeout, treat as `HookResult::continue_()` so
    /// the agent proceeds. This is the default (fail-open): errors in a
    /// script-based hook are usually developer bugs, not attacks.
    #[default]
    Continue,
    /// On handler error or timeout, synthesize a `HookResult::block(reason)`
    /// with a descriptive reason. Blocks the operation.
    Block,
}

/// Result returned by a hook handler.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HookResult {
    /// Action to take.
    pub action: HookAction,
    /// Reason for the action (typically set for `Block`).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
    /// Message to display or log.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub message: Option<String>,
    /// Modifications to apply (for `Modify` action).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub modifications: Option<serde_json::Value>,
    /// Extra context to inject into the prompt/turn this hook is
    /// firing on. Set alongside `action: AddContext`. When multiple
    /// hooks return `AddContext`, the engine concatenates their
    /// `added_context` fields with newlines in registration order.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub added_context: Option<String>,
}

impl HookResult {
    /// Create a `Continue` result (no action needed).
    #[must_use]
    pub fn continue_() -> Self {
        Self {
            action: HookAction::Continue,
            reason: None,
            message: None,
            modifications: None,
            added_context: None,
        }
    }

    /// Create a `Block` result with a reason.
    #[must_use]
    pub fn block(reason: impl Into<String>) -> Self {
        Self {
            action: HookAction::Block,
            reason: Some(reason.into()),
            message: None,
            modifications: None,
            added_context: None,
        }
    }

    /// Create a `Modify` result with modifications.
    #[must_use]
    pub fn modify(modifications: serde_json::Value) -> Self {
        Self {
            action: HookAction::Modify,
            reason: None,
            message: None,
            modifications: Some(modifications),
            added_context: None,
        }
    }

    /// Create a `Modify` result with modifications and a message.
    #[must_use]
    pub fn modify_with_message(
        modifications: serde_json::Value,
        message: impl Into<String>,
    ) -> Self {
        Self {
            action: HookAction::Modify,
            reason: None,
            message: Some(message.into()),
            modifications: Some(modifications),
            added_context: None,
        }
    }

    /// Create an `AddContext` result carrying extra text to inject
    /// into the prompt/turn this hook is firing on.
    #[must_use]
    pub fn add_context(content: impl Into<String>) -> Self {
        Self {
            action: HookAction::AddContext,
            reason: None,
            message: None,
            modifications: None,
            added_context: Some(content.into()),
        }
    }

    /// Whether this result blocks the operation.
    #[must_use]
    pub fn is_blocked(&self) -> bool {
        self.action == HookAction::Block
    }
}

/// Hook context — one variant per [`HookType`].
///
/// Passed to hook handlers so they can inspect and act on the current
/// lifecycle event. All variants include `session_id` and `timestamp`.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "hookType", rename_all = "camelCase")]
pub enum HookContext {
    /// Context for [`HookType::PreToolUse`].
    #[serde(rename_all = "camelCase")]
    PreToolUse {
        /// Session this hook fires in.
        session_id: String,
        /// ISO 8601 timestamp.
        timestamp: String,
        /// Tool being invoked.
        tool_name: String,
        /// Arguments passed to the tool.
        tool_arguments: serde_json::Value,
        /// Unique ID for this tool call.
        tool_call_id: String,
    },
    /// Context for [`HookType::PostToolUse`].
    #[serde(rename_all = "camelCase")]
    PostToolUse {
        /// Session this hook fires in.
        session_id: String,
        /// ISO 8601 timestamp.
        timestamp: String,
        /// Tool that was invoked.
        tool_name: String,
        /// Unique ID for this tool call.
        tool_call_id: String,
        /// Serialized tool result.
        result: serde_json::Value,
        /// How long the tool call took.
        duration_ms: u64,
    },
    /// Context for [`HookType::Stop`].
    #[serde(rename_all = "camelCase")]
    Stop {
        /// Session this hook fires in.
        session_id: String,
        /// ISO 8601 timestamp.
        timestamp: String,
        /// Why the agent is stopping.
        stop_reason: String,
        /// Last message from the agent.
        final_message: Option<String>,
        /// Last user prompt text (for suggestion hooks).
        #[serde(skip_serializing_if = "Option::is_none")]
        last_user_prompt: Option<String>,
        /// Last assistant response text, truncated (for suggestion hooks).
        #[serde(skip_serializing_if = "Option::is_none")]
        last_assistant_response: Option<String>,
    },
    /// Context for [`HookType::SubagentStop`].
    #[serde(rename_all = "camelCase")]
    SubagentStop {
        /// Session this hook fires in.
        session_id: String,
        /// ISO 8601 timestamp.
        timestamp: String,
        /// Subagent session ID.
        subagent_id: String,
        /// Why the subagent stopped.
        stop_reason: String,
        /// Result from the subagent.
        result: Option<serde_json::Value>,
    },
    /// Context for [`HookType::SessionStart`].
    #[serde(rename_all = "camelCase")]
    SessionStart {
        /// Session this hook fires in.
        session_id: String,
        /// ISO 8601 timestamp.
        timestamp: String,
        /// Working directory for the session.
        working_directory: String,
    },
    /// Context for [`HookType::SessionEnd`].
    #[serde(rename_all = "camelCase")]
    SessionEnd {
        /// Session this hook fires in.
        session_id: String,
        /// ISO 8601 timestamp.
        timestamp: String,
        /// Number of messages in the session.
        message_count: u64,
        /// Number of tool calls in the session.
        tool_call_count: u64,
    },
    /// Context for [`HookType::UserPromptSubmit`].
    #[serde(rename_all = "camelCase")]
    UserPromptSubmit {
        /// Session this hook fires in.
        session_id: String,
        /// ISO 8601 timestamp.
        timestamp: String,
        /// The user's prompt text.
        prompt: String,
    },
    /// Context for [`HookType::PreCompact`].
    #[serde(rename_all = "camelCase")]
    PreCompact {
        /// Session this hook fires in.
        session_id: String,
        /// ISO 8601 timestamp.
        timestamp: String,
        /// Current token usage.
        current_tokens: u64,
        /// Target token usage after compaction.
        target_tokens: u64,
    },
    /// Context for [`HookType::Notification`].
    #[serde(rename_all = "camelCase")]
    Notification {
        /// Session this hook fires in.
        session_id: String,
        /// ISO 8601 timestamp.
        timestamp: String,
        /// Notification severity level.
        level: String,
        /// Notification title.
        title: String,
        /// Optional notification body.
        body: Option<String>,
    },
    /// Context for [`HookType::WorktreeAcquired`].
    #[serde(rename_all = "camelCase")]
    WorktreeAcquired {
        /// Session this hook fires in.
        session_id: String,
        /// ISO 8601 timestamp.
        timestamp: String,
        /// Branch name (e.g. `session/abc123`).
        branch: String,
        /// Root of the git repository.
        repo_root: String,
        /// Base branch (e.g. `main`).
        base_branch: Option<String>,
        /// Path to the worktree directory.
        working_directory: String,
    },
}

impl HookContext {
    /// Get the [`HookType`] for this context.
    #[must_use]
    pub fn hook_type(&self) -> HookType {
        match self {
            Self::PreToolUse { .. } => HookType::PreToolUse,
            Self::PostToolUse { .. } => HookType::PostToolUse,
            Self::Stop { .. } => HookType::Stop,
            Self::SubagentStop { .. } => HookType::SubagentStop,
            Self::SessionStart { .. } => HookType::SessionStart,
            Self::SessionEnd { .. } => HookType::SessionEnd,
            Self::UserPromptSubmit { .. } => HookType::UserPromptSubmit,
            Self::PreCompact { .. } => HookType::PreCompact,
            Self::Notification { .. } => HookType::Notification,
            Self::WorktreeAcquired { .. } => HookType::WorktreeAcquired,
        }
    }

    /// Get the session ID from any context variant.
    #[must_use]
    pub fn session_id(&self) -> &str {
        match self {
            Self::PreToolUse { session_id, .. }
            | Self::PostToolUse { session_id, .. }
            | Self::Stop { session_id, .. }
            | Self::SubagentStop { session_id, .. }
            | Self::SessionStart { session_id, .. }
            | Self::SessionEnd { session_id, .. }
            | Self::UserPromptSubmit { session_id, .. }
            | Self::PreCompact { session_id, .. }
            | Self::Notification { session_id, .. }
            | Self::WorktreeAcquired { session_id, .. } => session_id,
        }
    }

    /// Get the timestamp from any context variant.
    #[must_use]
    pub fn timestamp(&self) -> &str {
        match self {
            Self::PreToolUse { timestamp, .. }
            | Self::PostToolUse { timestamp, .. }
            | Self::Stop { timestamp, .. }
            | Self::SubagentStop { timestamp, .. }
            | Self::SessionStart { timestamp, .. }
            | Self::SessionEnd { timestamp, .. }
            | Self::UserPromptSubmit { timestamp, .. }
            | Self::PreCompact { timestamp, .. }
            | Self::Notification { timestamp, .. }
            | Self::WorktreeAcquired { timestamp, .. } => timestamp,
        }
    }
}

/// Information about a registered hook (for listing/inspection).
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HookInfo {
    /// Hook name.
    pub name: String,
    /// Hook type.
    pub hook_type: HookType,
    /// Execution priority (higher runs first).
    pub priority: i32,
    /// Execution mode.
    pub execution_mode: HookExecutionMode,
    /// Optional description.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    /// Optional timeout in milliseconds.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub timeout_ms: Option<u64>,
}

/// Where a discovered hook file was found.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum HookSource {
    /// From project-level `.agent/hooks/` or `.tron/hooks/`.
    Project,
    /// From user-level `~/.config/tron/hooks/`.
    User,
    /// From a custom additional path.
    Custom,
}

impl std::fmt::Display for HookSource {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Project => write!(f, "project"),
            Self::User => write!(f, "user"),
            Self::Custom => write!(f, "custom"),
        }
    }
}

/// A discovered hook file from filesystem scanning.
#[derive(Debug, Clone)]
pub struct DiscoveredHook {
    /// Hook name (e.g., `user:title-gen`).
    pub name: String,
    /// Absolute path to the hook file.
    pub path: std::path::PathBuf,
    /// File extension (e.g., `"sh"`, `"prompt"`, `"js"`).
    pub extension: String,
    /// Where the hook was found.
    pub source: HookSource,
    /// Parsed metadata from frontmatter.
    pub config: HookFileConfig,
}

impl DiscoveredHook {
    /// Whether this is an LLM prompt hook (`.prompt` file).
    pub fn is_prompt(&self) -> bool {
        self.extension == "prompt"
    }

    /// Whether this is a script hook (`.sh`, `.js`, `.ts`, `.mjs`).
    pub fn is_script(&self) -> bool {
        !self.is_prompt()
    }
}

/// Parsed metadata from a hook file's frontmatter.
///
/// All hook files (scripts and prompts) use frontmatter for metadata.
/// `type` is required; all other fields have defaults.
///
/// `.prompt` files use standard `---` delimiters:
/// ```text
/// ---
/// type: session-start
/// label: Generate title
/// ---
/// Prompt body here...
/// ```
///
/// Script files use comment-prefixed frontmatter (`# `, `// `):
/// ```text
/// # ---
/// # type: pre-tool-use
/// # label: Safety check
/// # ---
/// #!/bin/bash
/// ...
/// ```
#[derive(Debug, Clone)]
pub struct HookFileConfig {
    /// Lifecycle event this hook fires on (from `type:` field).
    pub hook_type: HookType,
    /// Human-readable label (from `label:` field, default: empty).
    pub label: String,
    /// Whether this hook is active (from `enabled:` field, default: true).
    pub enabled: bool,
    /// Execution priority — higher runs first (from `priority:` field, default: 0).
    pub priority: i32,
    /// The prompt body (only for `.prompt` files — content after frontmatter).
    pub prompt: Option<String>,
}

/// Configuration for hook discovery.
#[derive(Debug, Clone, Default)]
pub struct DiscoveryConfig {
    /// Project root path for scanning `.agent/hooks/` and `.tron/hooks/`.
    pub project_path: Option<String>,
    /// User home directory override.
    pub user_home: Option<String>,
    /// Additional paths to scan for hooks.
    pub additional_paths: Vec<String>,
    /// Whether to include hooks from user-level directory.
    pub include_user_hooks: bool,
    /// File extensions to consider (e.g., `.sh`, `.ts`, `.js`).
    pub extensions: Vec<String>,
}

#[cfg(test)]
mod tests {
    use super::*;

    // --- HookType ---

    #[test]
    fn test_hook_type_forced_blocking() {
        assert!(HookType::PreToolUse.is_forced_blocking());
        assert!(HookType::UserPromptSubmit.is_forced_blocking());
        assert!(HookType::PreCompact.is_forced_blocking());
    }

    #[test]
    fn test_hook_type_not_forced_blocking() {
        assert!(!HookType::PostToolUse.is_forced_blocking());
        assert!(!HookType::Stop.is_forced_blocking());
        assert!(!HookType::SubagentStop.is_forced_blocking());
        assert!(!HookType::SessionStart.is_forced_blocking());
        assert!(!HookType::SessionEnd.is_forced_blocking());
        assert!(!HookType::Notification.is_forced_blocking());
        assert!(!HookType::WorktreeAcquired.is_forced_blocking());
    }

    #[test]
    fn test_hook_type_all_returns_ten_variants() {
        assert_eq!(HookType::all().len(), 10);
    }

    #[test]
    fn test_hook_type_display() {
        assert_eq!(HookType::PreToolUse.to_string(), "PreToolUse");
        assert_eq!(HookType::PostToolUse.to_string(), "PostToolUse");
        assert_eq!(HookType::Stop.to_string(), "Stop");
        assert_eq!(HookType::Notification.to_string(), "Notification");
    }

    // --- HookAction ---

    #[test]
    fn test_hook_action_serde_roundtrip() {
        for action in &[
            HookAction::Continue,
            HookAction::Block,
            HookAction::Modify,
            HookAction::AddContext,
        ] {
            let json = serde_json::to_string(action).unwrap();
            let deserialized: HookAction = serde_json::from_str(&json).unwrap();
            assert_eq!(&deserialized, action);
        }
    }

    #[test]
    fn test_hook_action_serde_values() {
        assert_eq!(
            serde_json::to_string(&HookAction::Continue).unwrap(),
            "\"continue\""
        );
        assert_eq!(
            serde_json::to_string(&HookAction::Block).unwrap(),
            "\"block\""
        );
        assert_eq!(
            serde_json::to_string(&HookAction::Modify).unwrap(),
            "\"modify\""
        );
        // AddContext serializes snake_case so scripts emitting JSON
        // can opt in with a readable token.
        assert_eq!(
            serde_json::to_string(&HookAction::AddContext).unwrap(),
            "\"add_context\""
        );
    }

    // End-to-end serde of the whole HookResult with added_context.
    #[test]
    fn test_hook_result_add_context_constructor() {
        let result = HookResult::add_context("helpful reminder");
        assert_eq!(result.action, HookAction::AddContext);
        assert_eq!(result.added_context.as_deref(), Some("helpful reminder"));
        assert!(result.modifications.is_none());
        assert!(!result.is_blocked());
    }

    #[test]
    fn test_hook_result_add_context_wire_shape() {
        let result = HookResult::add_context("payload");
        let json = serde_json::to_string(&result).unwrap();
        assert!(json.contains("\"action\":\"add_context\""));
        assert!(json.contains("\"addedContext\":\"payload\""));
    }

    #[test]
    fn test_hook_result_parses_add_context_from_script_shape() {
        let json = r#"{"action":"add_context","addedContext":"reminder"}"#;
        let result: HookResult = serde_json::from_str(json).unwrap();
        assert_eq!(result.action, HookAction::AddContext);
        assert_eq!(result.added_context.as_deref(), Some("reminder"));
    }

    // --- HookExecutionMode ---

    #[test]
    fn test_hook_execution_mode_serde() {
        assert_eq!(
            serde_json::to_string(&HookExecutionMode::Blocking).unwrap(),
            "\"blocking\""
        );
        assert_eq!(
            serde_json::to_string(&HookExecutionMode::Background).unwrap(),
            "\"background\""
        );
    }

    #[test]
    fn test_hook_execution_mode_default() {
        assert_eq!(HookExecutionMode::default(), HookExecutionMode::Blocking);
    }

    // --- HookResult ---

    #[test]
    fn test_hook_result_continue() {
        let result = HookResult::continue_();
        assert_eq!(result.action, HookAction::Continue);
        assert!(result.reason.is_none());
        assert!(result.message.is_none());
        assert!(result.modifications.is_none());
        assert!(!result.is_blocked());
    }

    #[test]
    fn test_hook_result_block() {
        let result = HookResult::block("dangerous command");
        assert_eq!(result.action, HookAction::Block);
        assert_eq!(result.reason.as_deref(), Some("dangerous command"));
        assert!(result.is_blocked());
    }

    #[test]
    fn test_hook_result_modify() {
        let mods = serde_json::json!({"key": "value"});
        let result = HookResult::modify(mods.clone());
        assert_eq!(result.action, HookAction::Modify);
        assert_eq!(result.modifications, Some(mods));
        assert!(!result.is_blocked());
    }

    #[test]
    fn test_hook_result_modify_with_message() {
        let mods = serde_json::json!({"key": "value"});
        let result = HookResult::modify_with_message(mods, "updated prompt");
        assert_eq!(result.action, HookAction::Modify);
        assert_eq!(result.message.as_deref(), Some("updated prompt"));
    }

    #[test]
    fn test_hook_result_serde_roundtrip() {
        let result = HookResult::block("blocked");
        let json = serde_json::to_string(&result).unwrap();
        let deserialized: HookResult = serde_json::from_str(&json).unwrap();
        assert_eq!(deserialized.action, HookAction::Block);
        assert_eq!(deserialized.reason.as_deref(), Some("blocked"));
    }

    #[test]
    fn test_hook_result_serde_skips_none_fields() {
        let result = HookResult::continue_();
        let json = serde_json::to_string(&result).unwrap();
        assert!(!json.contains("reason"));
        assert!(!json.contains("message"));
        assert!(!json.contains("modifications"));
    }

    // --- HookContext ---

    #[test]
    fn test_hook_context_pre_tool_use_type() {
        let ctx = HookContext::PreToolUse {
            session_id: "s1".to_string(),
            timestamp: "2026-01-01T00:00:00Z".to_string(),
            tool_name: "Bash".to_string(),
            tool_arguments: serde_json::json!({"command": "ls"}),
            tool_call_id: "tc1".to_string(),
        };
        assert_eq!(ctx.hook_type(), HookType::PreToolUse);
        assert_eq!(ctx.session_id(), "s1");
        assert_eq!(ctx.timestamp(), "2026-01-01T00:00:00Z");
    }

    #[test]
    fn test_hook_context_post_tool_use_type() {
        let ctx = HookContext::PostToolUse {
            session_id: "s1".to_string(),
            timestamp: "2026-01-01T00:00:00Z".to_string(),
            tool_name: "Bash".to_string(),
            tool_call_id: "tc1".to_string(),
            result: serde_json::json!({"ok": true}),
            duration_ms: 150,
        };
        assert_eq!(ctx.hook_type(), HookType::PostToolUse);
    }

    #[test]
    fn test_hook_context_stop_type() {
        let ctx = HookContext::Stop {
            session_id: "s1".to_string(),
            timestamp: "2026-01-01T00:00:00Z".to_string(),
            stop_reason: "end_turn".to_string(),
            final_message: Some("Done.".to_string()),
            last_user_prompt: None,
            last_assistant_response: None,
        };
        assert_eq!(ctx.hook_type(), HookType::Stop);
    }

    #[test]
    fn test_hook_context_session_start_type() {
        let ctx = HookContext::SessionStart {
            session_id: "s1".to_string(),
            timestamp: "2026-01-01T00:00:00Z".to_string(),
            working_directory: "/tmp".to_string(),
        };
        assert_eq!(ctx.hook_type(), HookType::SessionStart);
    }

    #[test]
    fn test_hook_context_session_end_type() {
        let ctx = HookContext::SessionEnd {
            session_id: "s1".to_string(),
            timestamp: "2026-01-01T00:00:00Z".to_string(),
            message_count: 5,
            tool_call_count: 3,
        };
        assert_eq!(ctx.hook_type(), HookType::SessionEnd);
    }

    #[test]
    fn test_hook_context_user_prompt_submit_type() {
        let ctx = HookContext::UserPromptSubmit {
            session_id: "s1".to_string(),
            timestamp: "2026-01-01T00:00:00Z".to_string(),
            prompt: "Hello".to_string(),
        };
        assert_eq!(ctx.hook_type(), HookType::UserPromptSubmit);
    }

    #[test]
    fn test_hook_context_pre_compact_type() {
        let ctx = HookContext::PreCompact {
            session_id: "s1".to_string(),
            timestamp: "2026-01-01T00:00:00Z".to_string(),
            current_tokens: 50000,
            target_tokens: 30000,
        };
        assert_eq!(ctx.hook_type(), HookType::PreCompact);
    }

    #[test]
    fn test_hook_context_notification_type() {
        let ctx = HookContext::Notification {
            session_id: "s1".to_string(),
            timestamp: "2026-01-01T00:00:00Z".to_string(),
            level: "info".to_string(),
            title: "Update".to_string(),
            body: None,
        };
        assert_eq!(ctx.hook_type(), HookType::Notification);
    }

    #[test]
    fn test_hook_context_subagent_stop_type() {
        let ctx = HookContext::SubagentStop {
            session_id: "s1".to_string(),
            timestamp: "2026-01-01T00:00:00Z".to_string(),
            subagent_id: "sub1".to_string(),
            stop_reason: "done".to_string(),
            result: None,
        };
        assert_eq!(ctx.hook_type(), HookType::SubagentStop);
    }

    #[test]
    fn test_hook_context_serde_roundtrip_pre_tool_use() {
        let ctx = HookContext::PreToolUse {
            session_id: "s1".to_string(),
            timestamp: "2026-01-01T00:00:00Z".to_string(),
            tool_name: "Bash".to_string(),
            tool_arguments: serde_json::json!({"command": "ls"}),
            tool_call_id: "tc1".to_string(),
        };
        let json = serde_json::to_string(&ctx).unwrap();
        let deserialized: HookContext = serde_json::from_str(&json).unwrap();
        assert_eq!(deserialized.hook_type(), HookType::PreToolUse);
        assert_eq!(deserialized.session_id(), "s1");
    }

    #[test]
    fn test_hook_context_worktree_acquired_type() {
        let ctx = HookContext::WorktreeAcquired {
            session_id: "s1".to_string(),
            timestamp: "2026-01-01T00:00:00Z".to_string(),
            branch: "session/abc123".to_string(),
            repo_root: "/repo".to_string(),
            base_branch: Some("main".to_string()),
            working_directory: "/repo/.worktrees/session/abc123".to_string(),
        };
        assert_eq!(ctx.hook_type(), HookType::WorktreeAcquired);
        assert_eq!(ctx.session_id(), "s1");
        assert_eq!(ctx.timestamp(), "2026-01-01T00:00:00Z");
    }

    #[test]
    fn test_hook_context_worktree_acquired_serde_roundtrip() {
        let ctx = HookContext::WorktreeAcquired {
            session_id: "s1".to_string(),
            timestamp: "2026-01-01T00:00:00Z".to_string(),
            branch: "session/abc".to_string(),
            repo_root: "/repo".to_string(),
            base_branch: None,
            working_directory: "/repo/.worktrees/session/abc".to_string(),
        };
        let json = serde_json::to_string(&ctx).unwrap();
        assert!(json.contains("\"hookType\""));
        let deserialized: HookContext = serde_json::from_str(&json).unwrap();
        assert_eq!(deserialized.hook_type(), HookType::WorktreeAcquired);
    }

    #[test]
    fn test_hook_type_worktree_acquired_display() {
        assert_eq!(HookType::WorktreeAcquired.to_string(), "WorktreeAcquired");
    }

    #[test]
    fn test_hook_context_serde_tag() {
        let ctx = HookContext::Stop {
            session_id: "s1".to_string(),
            timestamp: "t".to_string(),
            stop_reason: "done".to_string(),
            final_message: None,
            last_user_prompt: None,
            last_assistant_response: None,
        };
        let json = serde_json::to_string(&ctx).unwrap();
        // The tag field should be "hookType"
        assert!(json.contains("\"hookType\""));
    }

    // --- HookInfo ---

    #[test]
    fn test_hook_info_serde_roundtrip() {
        let info = HookInfo {
            name: "test-hook".to_string(),
            hook_type: HookType::PreToolUse,
            priority: 100,
            execution_mode: HookExecutionMode::Blocking,
            description: Some("A test hook".to_string()),
            timeout_ms: Some(5000),
        };
        let json = serde_json::to_string(&info).unwrap();
        let deserialized: HookInfo = serde_json::from_str(&json).unwrap();
        assert_eq!(deserialized.name, "test-hook");
        assert_eq!(deserialized.priority, 100);
    }

    // --- HookSource ---

    #[test]
    fn test_hook_source_display() {
        assert_eq!(HookSource::Project.to_string(), "project");
        assert_eq!(HookSource::User.to_string(), "user");
        assert_eq!(HookSource::Custom.to_string(), "custom");
    }
}
