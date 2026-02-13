//! Memory manager.
//!
//! Orchestrates the compaction → ledger pipeline. The critical invariant is
//! **sequential ordering**: compaction always runs before ledger writing,
//! ensuring `compact.boundary` events always precede `memory.ledger` events
//! in the event log.
//!
//! All operations are **fail-silent** — errors are logged but never propagated.
//! Memory errors must never crash a session.

use std::sync::Arc;

use async_trait::async_trait;
use tracing::{info, warn};

use crate::errors::MemoryError;
use crate::trigger::CompactionTrigger;
use crate::types::{
    CompactionTriggerInput, CycleInfo, LedgerWriteOpts, LedgerWriteResult,
};

/// Dependencies for the memory manager.
///
/// Implemented by the runtime to provide compaction execution, ledger writing,
/// event emission, and embedding. Uses trait-based dependency injection to
/// avoid circular dependencies.
#[async_trait]
pub trait MemoryManagerDeps: Send + Sync {
    /// Execute context compaction.
    async fn execute_compaction(&self) -> Result<(), MemoryError>;

    /// Write a ledger entry via subagent.
    async fn write_ledger_entry(&self, opts: &LedgerWriteOpts) -> LedgerWriteResult;

    /// Whether ledger writing is enabled (checked each cycle).
    fn is_ledger_enabled(&self) -> bool;

    /// Emit `memory.updating` event (before ledger write starts).
    fn emit_memory_updating(&self, session_id: &str);

    /// Emit `memory.updated` event (after ledger write completes or skips).
    fn emit_memory_updated(
        &self,
        session_id: &str,
        title: Option<&str>,
        entry_type: Option<&str>,
    );

    /// Fire-and-forget embedding for semantic search.
    async fn embed_memory(
        &self,
        event_id: &str,
        workspace_id: &str,
        payload: &serde_json::Value,
    );

    /// Called after a successful ledger write with the payload and title.
    fn on_memory_written(&self, payload: &serde_json::Value, title: &str);

    /// The current session ID.
    fn session_id(&self) -> &str;

    /// The current workspace ID (if known).
    fn workspace_id(&self) -> Option<&str>;
}

/// Memory manager orchestrating compaction and ledger writing.
///
/// # Sequential Ordering
///
/// Compaction **always** runs before ledger writing. This guarantees that
/// `compact.boundary` events precede `memory.ledger` events in the
/// event sequence, which is critical for correct event reconstruction.
///
/// # Fail-Silent
///
/// All errors are caught and logged. The manager never propagates errors
/// to the caller because memory operations are observability, not functionality.
pub struct MemoryManager<D: MemoryManagerDeps> {
    deps: D,
    trigger: CompactionTrigger,
}

impl<D: MemoryManagerDeps> MemoryManager<D> {
    /// Create a new memory manager.
    pub fn new(deps: D, trigger: CompactionTrigger) -> Self {
        Self { deps, trigger }
    }

    /// Called at the end of each agent response cycle.
    ///
    /// Pipeline:
    /// 1. Check compaction trigger → if triggered, execute compaction then reset
    /// 2. If ledger enabled → emit updating, write entry, emit updated
    /// 3. If entry written → call `on_memory_written`, spawn embedding
    ///
    /// All errors are caught and logged (fail-silent).
    pub async fn on_cycle_complete(&mut self, info: CycleInfo) {
        let session_id = self.deps.session_id().to_string();

        // --- Phase 1: Compaction (runs first for sequential ordering) ---
        let compaction_result = self.trigger.should_compact(&CompactionTriggerInput {
            current_token_ratio: info.current_token_ratio,
            recent_event_types: info.recent_event_types.clone(),
            recent_tool_calls: info.recent_tool_calls.clone(),
        });

        if compaction_result.compact {
            info!(
                reason = %compaction_result.reason,
                session_id = %session_id,
                "Compaction triggered by memory manager"
            );
            match self.deps.execute_compaction().await {
                Ok(()) => {
                    self.trigger.reset();
                }
                Err(e) => {
                    warn!(
                        error = %e,
                        session_id = %session_id,
                        "Memory-triggered compaction failed"
                    );
                }
            }
        }

        // --- Phase 2: Ledger writing (runs after compaction) ---
        if !self.deps.is_ledger_enabled() {
            return;
        }

        self.deps.emit_memory_updating(&session_id);

        let opts = LedgerWriteOpts {
            model: info.model.clone(),
            working_directory: info.working_directory.clone(),
        };

        let ledger_result = self.deps.write_ledger_entry(&opts).await;

        if ledger_result.written {
            self.deps.emit_memory_updated(
                &session_id,
                ledger_result.title.as_deref(),
                ledger_result.entry_type.as_deref(),
            );

            if let Some(payload) = &ledger_result.payload {
                self.deps.on_memory_written(
                    payload,
                    ledger_result.title.as_deref().unwrap_or("Untitled"),
                );

                // Fire-and-forget embedding
                if let Some(event_id) = &ledger_result.event_id {
                    let workspace_id = self
                        .deps
                        .workspace_id()
                        .unwrap_or("")
                        .to_string();
                    self.deps
                        .embed_memory(event_id, &workspace_id, payload)
                        .await;
                }
            }
        } else {
            self.deps.emit_memory_updated(&session_id, None, Some("skipped"));
        }
    }

    /// Get a reference to the compaction trigger (for testing/inspection).
    #[must_use]
    pub fn trigger(&self) -> &CompactionTrigger {
        &self.trigger
    }

    /// Get a mutable reference to the compaction trigger.
    pub fn trigger_mut(&mut self) -> &mut CompactionTrigger {
        &mut self.trigger
    }
}

impl<D: MemoryManagerDeps> std::fmt::Debug for MemoryManager<D> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("MemoryManager")
            .field("trigger", &self.trigger)
            .finish_non_exhaustive()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::CompactionTriggerConfig;
    use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
    use std::sync::{Arc, Mutex};

    /// Mock deps that track all calls.
    struct MockDeps {
        session_id: String,
        workspace_id: Option<String>,
        ledger_enabled: bool,
        compaction_should_fail: bool,
        ledger_result: LedgerWriteResult,

        compaction_called: AtomicBool,
        ledger_called: AtomicBool,
        updating_emitted: AtomicBool,
        updated_emitted: AtomicBool,
        updated_entry_type: Mutex<Option<String>>,
        memory_written_called: AtomicBool,
        embed_called: AtomicBool,
        updated_count: AtomicUsize,
    }

    impl MockDeps {
        fn new() -> Self {
            Self {
                session_id: "s1".to_string(),
                workspace_id: Some("w1".to_string()),
                ledger_enabled: true,
                compaction_should_fail: false,
                ledger_result: LedgerWriteResult::skipped("no content"),
                compaction_called: AtomicBool::new(false),
                ledger_called: AtomicBool::new(false),
                updating_emitted: AtomicBool::new(false),
                updated_emitted: AtomicBool::new(false),
                updated_entry_type: Mutex::new(None),
                memory_written_called: AtomicBool::new(false),
                embed_called: AtomicBool::new(false),
                updated_count: AtomicUsize::new(0),
            }
        }

        fn with_ledger_result(mut self, result: LedgerWriteResult) -> Self {
            self.ledger_result = result;
            self
        }

        fn with_ledger_disabled(mut self) -> Self {
            self.ledger_enabled = false;
            self
        }

        fn with_compaction_failure(mut self) -> Self {
            self.compaction_should_fail = true;
            self
        }
    }

    #[async_trait]
    impl MemoryManagerDeps for MockDeps {
        async fn execute_compaction(&self) -> Result<(), MemoryError> {
            self.compaction_called.store(true, Ordering::SeqCst);
            if self.compaction_should_fail {
                Err(MemoryError::Compaction("test failure".to_string()))
            } else {
                Ok(())
            }
        }

        async fn write_ledger_entry(&self, _opts: &LedgerWriteOpts) -> LedgerWriteResult {
            self.ledger_called.store(true, Ordering::SeqCst);
            self.ledger_result.clone()
        }

        fn is_ledger_enabled(&self) -> bool {
            self.ledger_enabled
        }

        fn emit_memory_updating(&self, _session_id: &str) {
            self.updating_emitted.store(true, Ordering::SeqCst);
        }

        fn emit_memory_updated(
            &self,
            _session_id: &str,
            _title: Option<&str>,
            entry_type: Option<&str>,
        ) {
            self.updated_emitted.store(true, Ordering::SeqCst);
            let _ = self.updated_count.fetch_add(1, Ordering::SeqCst);
            if let Some(et) = entry_type {
                *self.updated_entry_type.lock().unwrap() = Some(et.to_string());
            }
        }

        async fn embed_memory(
            &self,
            _event_id: &str,
            _workspace_id: &str,
            _payload: &serde_json::Value,
        ) {
            self.embed_called.store(true, Ordering::SeqCst);
        }

        fn on_memory_written(&self, _payload: &serde_json::Value, _title: &str) {
            self.memory_written_called.store(true, Ordering::SeqCst);
        }

        fn session_id(&self) -> &str {
            &self.session_id
        }

        fn workspace_id(&self) -> Option<&str> {
            self.workspace_id.as_deref()
        }
    }

    fn default_cycle_info(ratio: f64) -> CycleInfo {
        CycleInfo {
            model: "claude-opus-4-6".to_string(),
            working_directory: "/tmp".to_string(),
            current_token_ratio: ratio,
            recent_event_types: Vec::new(),
            recent_tool_calls: Vec::new(),
        }
    }

    fn make_manager(deps: MockDeps) -> MemoryManager<MockDeps> {
        let trigger = CompactionTrigger::new(CompactionTriggerConfig::default());
        MemoryManager::new(deps, trigger)
    }

    // --- No compaction, no ledger ---

    #[tokio::test]
    async fn test_no_compact_ledger_disabled() {
        let deps = Arc::new(MockDeps::new().with_ledger_disabled());
        let mut manager = MemoryManager::new(
            Arc::clone(&deps),
            CompactionTrigger::new(CompactionTriggerConfig::default()),
        );

        manager.on_cycle_complete(default_cycle_info(0.3)).await;

        assert!(!deps.compaction_called.load(Ordering::SeqCst));
        assert!(!deps.ledger_called.load(Ordering::SeqCst));
        assert!(!deps.updating_emitted.load(Ordering::SeqCst));
    }

    // --- No compaction, ledger writes ---

    #[tokio::test]
    async fn test_no_compact_ledger_writes() {
        let deps = Arc::new(MockDeps::new().with_ledger_result(
            LedgerWriteResult::written(
                "Test Title".to_string(),
                "feature".to_string(),
                "evt-1".to_string(),
                serde_json::json!({"key": "val"}),
            ),
        ));
        let mut manager = MemoryManager::new(
            Arc::clone(&deps),
            CompactionTrigger::new(CompactionTriggerConfig::default()),
        );

        manager.on_cycle_complete(default_cycle_info(0.3)).await;

        assert!(!deps.compaction_called.load(Ordering::SeqCst));
        assert!(deps.ledger_called.load(Ordering::SeqCst));
        assert!(deps.updating_emitted.load(Ordering::SeqCst));
        assert!(deps.updated_emitted.load(Ordering::SeqCst));
        assert!(deps.memory_written_called.load(Ordering::SeqCst));
        assert!(deps.embed_called.load(Ordering::SeqCst));
    }

    // --- Compaction triggered, then ledger ---

    #[tokio::test]
    async fn test_compact_then_ledger() {
        let deps = Arc::new(MockDeps::new().with_ledger_result(
            LedgerWriteResult::skipped("no content"),
        ));
        let mut manager = MemoryManager::new(
            Arc::clone(&deps),
            CompactionTrigger::new(CompactionTriggerConfig::default()),
        );

        // Trigger via high token ratio
        manager
            .on_cycle_complete(default_cycle_info(0.80))
            .await;

        assert!(deps.compaction_called.load(Ordering::SeqCst));
        assert!(deps.ledger_called.load(Ordering::SeqCst));
        assert!(deps.updating_emitted.load(Ordering::SeqCst));
    }

    // --- Compaction fails, ledger still runs ---

    #[tokio::test]
    async fn test_compaction_failure_ledger_still_runs() {
        let deps = Arc::new(
            MockDeps::new()
                .with_compaction_failure()
                .with_ledger_result(LedgerWriteResult::skipped("test")),
        );
        let mut manager = MemoryManager::new(
            Arc::clone(&deps),
            CompactionTrigger::new(CompactionTriggerConfig::default()),
        );

        manager
            .on_cycle_complete(default_cycle_info(0.80))
            .await;

        assert!(deps.compaction_called.load(Ordering::SeqCst));
        assert!(deps.ledger_called.load(Ordering::SeqCst));
    }

    // --- Ledger not written → "skipped" ---

    #[tokio::test]
    async fn test_ledger_not_written_emits_skipped() {
        let deps = Arc::new(MockDeps::new());
        let mut manager = MemoryManager::new(
            Arc::clone(&deps),
            CompactionTrigger::new(CompactionTriggerConfig::default()),
        );

        manager.on_cycle_complete(default_cycle_info(0.3)).await;

        assert!(deps.updated_emitted.load(Ordering::SeqCst));
        let entry_type = deps.updated_entry_type.lock().unwrap();
        assert_eq!(entry_type.as_deref(), Some("skipped"));
    }

    // --- Ledger written → on_memory_written called ---

    #[tokio::test]
    async fn test_ledger_written_calls_on_memory_written() {
        let deps = Arc::new(MockDeps::new().with_ledger_result(
            LedgerWriteResult::written(
                "Title".to_string(),
                "bugfix".to_string(),
                "evt-1".to_string(),
                serde_json::json!({}),
            ),
        ));
        let mut manager = MemoryManager::new(
            Arc::clone(&deps),
            CompactionTrigger::new(CompactionTriggerConfig::default()),
        );

        manager.on_cycle_complete(default_cycle_info(0.3)).await;

        assert!(deps.memory_written_called.load(Ordering::SeqCst));
    }

    // --- Ledger written → embed_memory called ---

    #[tokio::test]
    async fn test_ledger_written_calls_embed() {
        let deps = Arc::new(MockDeps::new().with_ledger_result(
            LedgerWriteResult::written(
                "Title".to_string(),
                "feature".to_string(),
                "evt-2".to_string(),
                serde_json::json!({"data": true}),
            ),
        ));
        let mut manager = MemoryManager::new(
            Arc::clone(&deps),
            CompactionTrigger::new(CompactionTriggerConfig::default()),
        );

        manager.on_cycle_complete(default_cycle_info(0.3)).await;

        assert!(deps.embed_called.load(Ordering::SeqCst));
    }

    // --- Compaction resets trigger ---

    #[tokio::test]
    async fn test_compaction_resets_trigger() {
        let deps = Arc::new(MockDeps::new().with_ledger_disabled());
        let mut manager = MemoryManager::new(
            Arc::clone(&deps),
            CompactionTrigger::new(CompactionTriggerConfig::default()),
        );

        // Force high ratio to trigger
        manager
            .on_cycle_complete(default_cycle_info(0.80))
            .await;

        assert_eq!(manager.trigger().turns_since_compaction(), 0);
    }

    // --- Compaction failure doesn't reset trigger ---

    #[tokio::test]
    async fn test_compaction_failure_doesnt_reset() {
        let deps = Arc::new(
            MockDeps::new()
                .with_compaction_failure()
                .with_ledger_disabled(),
        );
        let mut manager = MemoryManager::new(
            Arc::clone(&deps),
            CompactionTrigger::new(CompactionTriggerConfig::default()),
        );

        manager
            .on_cycle_complete(default_cycle_info(0.80))
            .await;

        // Turn counter was incremented by should_compact but NOT reset
        assert_eq!(manager.trigger().turns_since_compaction(), 1);
    }

    // --- Debug impl ---

    #[tokio::test]
    async fn test_debug_impl() {
        let deps = MockDeps::new();
        let manager = make_manager(deps);
        let debug = format!("{manager:?}");
        assert!(debug.contains("MemoryManager"));
    }
}

// Implement MemoryManagerDeps for Arc<T> where T: MemoryManagerDeps
#[async_trait]
impl<T: MemoryManagerDeps> MemoryManagerDeps for Arc<T>
where
    T: Send + Sync,
{
    async fn execute_compaction(&self) -> Result<(), MemoryError> {
        (**self).execute_compaction().await
    }
    async fn write_ledger_entry(&self, opts: &LedgerWriteOpts) -> LedgerWriteResult {
        (**self).write_ledger_entry(opts).await
    }
    fn is_ledger_enabled(&self) -> bool {
        (**self).is_ledger_enabled()
    }
    fn emit_memory_updating(&self, session_id: &str) {
        (**self).emit_memory_updating(session_id);
    }
    fn emit_memory_updated(&self, session_id: &str, title: Option<&str>, entry_type: Option<&str>) {
        (**self).emit_memory_updated(session_id, title, entry_type);
    }
    async fn embed_memory(&self, event_id: &str, workspace_id: &str, payload: &serde_json::Value) {
        (**self).embed_memory(event_id, workspace_id, payload).await;
    }
    fn on_memory_written(&self, payload: &serde_json::Value, title: &str) {
        (**self).on_memory_written(payload, title);
    }
    fn session_id(&self) -> &str {
        (**self).session_id()
    }
    fn workspace_id(&self) -> Option<&str> {
        (**self).workspace_id()
    }
}


