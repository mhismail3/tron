//! Hook execution engine.
//!
//! Orchestrates hook execution with priority ordering, blocking/background
//! mode support, fail-open error handling, and background task tracking.
//!
//! # Execution Model
//!
//! Hooks are evaluated in priority order (highest first). For blocking hooks:
//! - A `Block` action stops the chain immediately.
//! - A `Modify` action collects modifications and continues.
//! - A `Continue` action continues to the next hook.
//!
//! Background hooks are fire-and-forget: spawned as tasks and tracked for
//! eventual draining.
//!
//! # Fail-Open
//!
//! Hook errors never crash the agent. They are logged and treated as `Continue`.

use std::sync::Arc;
use std::time::Instant;

use tracing::{debug, instrument, warn};

use super::background::BackgroundTracker;
use super::handler::HookHandler;
use super::prompt_handler::PromptHookHandler;
use super::registry::HookRegistry;
use super::script_handler::ScriptHookHandler;
use super::types::{
    DiscoveredHook, HookAction, HookContext, HookErrorPolicy, HookExecutionMode, HookResult,
    HookType,
};

/// Fixed per-event limit for hook `AddContext` payloads.
///
/// The budget is intentionally not user configurable: it is an internal
/// safety fuse that lets hooks provide a small amount of context without
/// allowing a misbehaving hook to flood the next LLM prompt. Over-budget
/// payloads are dropped all-or-nothing so hook authors can rely on complete
/// context blocks or no injection at all.
pub(crate) const HOOK_ADDED_CONTEXT_CHAR_BUDGET: usize = 16384;

/// Hook execution engine.
///
/// Owns the [`HookRegistry`] and [`BackgroundTracker`]. Provides the main
/// `execute()` method that runs all registered hooks for a given context.
///
/// ## Error policy
///
/// When a handler returns `Err` or times out, the engine consults
/// `error_policy`. The default is [`HookErrorPolicy::Continue`] (fail-open).
/// Hooks that protect the agent from policy violations (security / guardrail
/// hooks) should configure [`HookErrorPolicy::Block`] via the top-level
/// setting — an error or timeout then synthesizes a `HookResult::block(...)`
/// instead of a silent `Continue`.
pub struct HookEngine {
    registry: HookRegistry,
    background: BackgroundTracker,
    error_policy: HookErrorPolicy,
}

impl HookEngine {
    /// Create a new engine with the given registry and default
    /// (fail-open) error policy.
    #[must_use]
    pub fn new(registry: HookRegistry) -> Self {
        Self {
            registry,
            background: BackgroundTracker::new(),
            error_policy: HookErrorPolicy::default(),
        }
    }

    /// Update the error policy applied to handler errors and timeouts.
    /// Default is [`HookErrorPolicy::Continue`]. Real construction paths
    /// pass the value from `HookSettings::error_policy`.
    pub fn set_error_policy(&mut self, policy: HookErrorPolicy) {
        self.error_policy = policy;
    }

    /// The current error policy. Exposed for introspection / tests.
    #[must_use]
    pub fn error_policy(&self) -> HookErrorPolicy {
        self.error_policy
    }

    /// Execute all registered hooks for the given context.
    ///
    /// Blocking hooks run sequentially in priority order.
    /// Background hooks are spawned and tracked.
    ///
    /// Returns the aggregated result. If any blocking hook returns `Block`,
    /// execution stops and the block result is returned. Modifications from
    /// all `Modify` results are merged.
    #[instrument(skip_all, fields(hook_type = %context.hook_type()))]
    pub async fn execute(&self, context: &HookContext) -> HookResult {
        let hook_type = context.hook_type();
        let handlers = self.registry.get_handlers(hook_type);

        if handlers.is_empty() {
            return HookResult::continue_();
        }

        let start = Instant::now();

        // Separate blocking and background handlers
        let (blocking, background): (Vec<_>, Vec<_>) = handlers
            .into_iter()
            .partition(|h| Self::effective_mode(h, hook_type) == HookExecutionMode::Blocking);

        debug!(
            hook_type = %hook_type,
            blocking_count = blocking.len(),
            background_count = background.len(),
            blocking_names = ?blocking.iter().map(|h| h.name()).collect::<Vec<_>>(),
            "[engine] partitioned handlers"
        );

        // Execute blocking hooks sequentially
        let result = self.execute_blocking(&blocking, context).await;

        // Spawn background hooks
        if !background.is_empty() {
            self.spawn_background(background, context);
        }

        let duration_ms = start.elapsed().as_millis();
        debug!(
            hook_type = %hook_type,
            duration_ms = duration_ms,
            blocked = result.is_blocked(),
            "Hook execution complete"
        );

        result
    }

    /// Execute blocking hooks sequentially.
    async fn execute_blocking(
        &self,
        handlers: &[Arc<dyn HookHandler>],
        context: &HookContext,
    ) -> HookResult {
        let mut merged_modifications: Option<serde_json::Value> = None;
        let mut messages: Vec<String> = Vec::new();
        // Accumulated `added_context` fragments from every handler
        // that returns `AddContext`. Concatenated with newlines in
        // registration order so hooks compose deterministically.
        let mut added_context_fragments: Vec<String> = Vec::new();

        for handler in handlers {
            // Check filter
            if !handler.should_handle(context) {
                debug!(name = %handler.name(), "Hook skipped by filter");
                continue;
            }

            // Execute with optional timeout
            let result = self.execute_single_handler(handler.as_ref(), context).await;

            match result.action {
                HookAction::Block => {
                    debug!(
                        name = %handler.name(),
                        reason = result.reason.as_deref().unwrap_or("(none)"),
                        "Hook blocked execution"
                    );
                    // Block short-circuits: any partial modifications
                    // or added-context from prior hooks are
                    // intentionally discarded so a guard hook's veto
                    // isn't silently mixed with a permissive hook's
                    // contribution.
                    return result;
                }
                HookAction::Modify => {
                    if let Some(mods) = &result.modifications {
                        merged_modifications =
                            Some(merge_json(merged_modifications.as_ref(), mods));
                    }
                    if let Some(msg) = &result.message {
                        messages.push(msg.clone());
                    }
                }
                HookAction::AddContext => {
                    if let Some(content) = &result.added_context
                        && !content.is_empty()
                    {
                        added_context_fragments.push(content.clone());
                    }
                    if let Some(msg) = &result.message {
                        messages.push(msg.clone());
                    }
                }
                HookAction::Continue => {
                    if let Some(msg) = &result.message {
                        messages.push(msg.clone());
                    }
                }
            }
        }

        // Budget check on the concatenated added_context. Over-budget
        // drops the entire batch (silent truncation would violate the
        // "all or nothing" contract callers rely on), and logs a warn
        // so operators can see the miss.
        let aggregated_added_context = if added_context_fragments.is_empty() {
            None
        } else {
            let joined = added_context_fragments.join("\n");
            if joined.len() > HOOK_ADDED_CONTEXT_CHAR_BUDGET {
                tracing::warn!(
                    hook_type = %context.hook_type(),
                    session_id = %context.session_id(),
                    aggregated_chars = joined.len(),
                    budget_chars = HOOK_ADDED_CONTEXT_CHAR_BUDGET,
                    "hook AddContext exceeded budget — dropping (all or nothing)"
                );
                None
            } else {
                Some(joined)
            }
        };

        // Build aggregated result
        let action = if merged_modifications.is_some() {
            HookAction::Modify
        } else if aggregated_added_context.is_some() {
            HookAction::AddContext
        } else {
            HookAction::Continue
        };
        if merged_modifications.is_some()
            || aggregated_added_context.is_some()
            || !messages.is_empty()
        {
            HookResult {
                action,
                reason: None,
                message: if messages.is_empty() {
                    None
                } else {
                    Some(messages.join("\n"))
                },
                modifications: merged_modifications,
                added_context: aggregated_added_context,
            }
        } else {
            HookResult::continue_()
        }
    }

    /// Execute a single handler, applying timeout and fail-open.
    async fn execute_single_handler(
        &self,
        handler: &dyn HookHandler,
        context: &HookContext,
    ) -> HookResult {
        let timeout_ms = handler.timeout_ms().unwrap_or(30_000);
        let handler_name = handler.name().to_string();
        let start = Instant::now();

        debug!(name = %handler_name, "[engine] calling handler.handle()");

        let result = tokio::time::timeout(
            std::time::Duration::from_millis(timeout_ms),
            handler.handle(context),
        )
        .await;

        let elapsed_ms = start.elapsed().as_millis();
        debug!(name = %handler_name, elapsed_ms = elapsed_ms, "[engine] handler.handle() returned");

        match result {
            Ok(Ok(hook_result)) => hook_result,
            Ok(Err(e)) => self.on_handler_failure(
                &handler_name,
                format!("hook '{}' errored: {e}", handler_name),
                "error",
            ),
            Err(_) => self.on_handler_failure(
                &handler_name,
                format!("hook '{}' timed out after {}ms", handler_name, timeout_ms),
                "timeout",
            ),
        }
    }

    /// Convert a handler failure (error or timeout) into the configured
    /// `HookResult` per [`HookErrorPolicy`]. Always logs — the difference
    /// is whether the agent sees `Continue` (fail-open) or `Block` (hard
    /// stop with a user-visible reason).
    fn on_handler_failure(
        &self,
        handler_name: &str,
        reason: String,
        kind: &'static str,
    ) -> HookResult {
        match self.error_policy {
            HookErrorPolicy::Continue => {
                warn!(name = %handler_name, kind, reason = %reason, "hook failure → fail-open");
                HookResult::continue_()
            }
            HookErrorPolicy::Block => {
                warn!(name = %handler_name, kind, reason = %reason, "hook failure → block (errorPolicy=block)");
                HookResult::block(reason)
            }
        }
    }

    /// Spawn background hooks as tracked tasks.
    fn spawn_background(&self, handlers: Vec<Arc<dyn HookHandler>>, context: &HookContext) {
        for handler in handlers {
            if !handler.should_handle(context) {
                continue;
            }

            let ctx = context.clone();
            let name = handler.name().to_string();

            self.background.spawn(async move {
                match handler.handle(&ctx).await {
                    Ok(result) => {
                        debug!(name = %name, action = ?result.action, "Background hook completed");
                    }
                    Err(e) => {
                        warn!(name = %name, error = %e, "Background hook error");
                    }
                }
            });
        }
    }

    /// Determine the effective execution mode for a handler.
    ///
    /// Forced-blocking hook types default to blocking mode, but handlers
    /// that return `true` from [`HookHandler::bypass_forced_blocking`]
    /// keep their declared mode.
    fn effective_mode(handler: &Arc<dyn HookHandler>, hook_type: HookType) -> HookExecutionMode {
        if hook_type.is_forced_blocking() && !handler.bypass_forced_blocking() {
            HookExecutionMode::Blocking
        } else {
            handler.execution_mode()
        }
    }

    /// Wait for all pending background hooks to complete.
    pub async fn wait_for_background(&self) {
        self.background.drain_all().await;
    }

    /// Wait for background hooks with a timeout.
    ///
    /// Returns `true` if all completed within the timeout.
    pub async fn wait_for_background_with_timeout(&self, timeout: std::time::Duration) -> bool {
        self.background.drain_with_timeout(timeout).await
    }

    /// Get the number of pending background hooks.
    #[must_use]
    pub fn pending_background_count(&self) -> usize {
        self.background.pending_count()
    }

    /// Get a reference to the hook registry.
    #[must_use]
    pub fn registry(&self) -> &HookRegistry {
        &self.registry
    }

    /// Get a mutable reference to the hook registry.
    pub fn registry_mut(&mut self) -> &mut HookRegistry {
        &mut self.registry
    }

    /// Register hooks from discovered hook files.
    ///
    /// Script hooks (`.sh`, `.js`, `.ts`) become [`ScriptHookHandler`]s.
    /// Prompt hooks (`.prompt`) become [`PromptHookHandler`]s.
    pub fn load_discovered_hooks(
        &mut self,
        discovered: Vec<DiscoveredHook>,
        default_timeout_ms: u64,
        llm_model: &str,
        subagent_manager: Option<
            &Arc<crate::domains::agent::runner::orchestrator::subagent_manager::SubagentManager>,
        >,
        event_emitter: Option<
            &Arc<crate::domains::agent::runner::agent::event_emitter::EventEmitter>,
        >,
    ) {
        for hook in discovered {
            if hook.is_prompt() {
                let Some(manager) = subagent_manager else {
                    warn!(name = %hook.name, "Skipping prompt hook: no subagent manager");
                    continue;
                };
                let Some(emitter) = event_emitter else {
                    warn!(name = %hook.name, "Skipping prompt hook: no event emitter");
                    continue;
                };

                let handler = PromptHookHandler::new(
                    hook.name.clone(),
                    hook.name.clone(),
                    hook.config.label.clone(),
                    hook.config.hook_type,
                    hook.config.prompt.clone().unwrap_or_default(),
                    hook.config.enabled,
                    hook.config.priority,
                    llm_model.to_string(),
                    manager.clone(),
                    emitter.clone(),
                );
                self.registry.register(Arc::new(handler));
            } else {
                let handler = ScriptHookHandler::new(
                    hook.name,
                    hook.config.hook_type,
                    hook.path,
                    hook.config.priority,
                    default_timeout_ms,
                );
                self.registry.register(Arc::new(handler));
            }
        }
    }
}

impl std::fmt::Debug for HookEngine {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("HookEngine")
            .field("registry", &self.registry)
            .field("background", &self.background)
            .finish()
    }
}

/// Shallow-merge two JSON objects. `b` fields override `a` fields.
fn merge_json(a: Option<&serde_json::Value>, b: &serde_json::Value) -> serde_json::Value {
    match (a, b) {
        (Some(serde_json::Value::Object(base)), serde_json::Value::Object(overlay)) => {
            let mut merged = base.clone();
            for (key, value) in overlay {
                let _ = merged.insert(key.clone(), value.clone());
            }
            serde_json::Value::Object(merged)
        }
        _ => b.clone(),
    }
}

#[cfg(test)]
#[path = "engine/tests.rs"]
mod tests;
