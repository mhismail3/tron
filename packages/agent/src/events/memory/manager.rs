//! Memory manager.
//!
//! Handles ledger writing after each agent turn. Compaction is owned
//! exclusively by `CompactionHandler` in `runtime` (pre-turn).
//!
//! All operations are **fail-silent** — errors are logged but never propagated.
//! Memory errors must never crash a session.

use std::sync::Arc;

use async_trait::async_trait;

use super::types::{LedgerWriteOpts, LedgerWriteResult};

/// Dependencies for the memory manager.
///
/// Implemented by the runtime to provide ledger writing,
/// event emission, and embedding. Uses trait-based dependency injection to
/// avoid circular dependencies.
#[async_trait]
pub trait MemoryManagerDeps: Send + Sync {
    /// Write a ledger entry via subagent.
    async fn write_ledger_entry(&self, opts: &LedgerWriteOpts) -> LedgerWriteResult;

    /// Whether ledger writing is enabled (checked each cycle).
    fn is_ledger_enabled(&self) -> bool;

    /// Emit `memory.updating` event (before ledger write starts).
    fn emit_memory_updating(&self, session_id: &str);

    /// Emit `memory.updated` event (after ledger write completes or skips).
    ///
    /// `event_id` is the persisted `memory.ledger` event ID, passed through to iOS
    /// so the detail sheet can look up the exact entry instead of matching by title.
    fn emit_memory_updated(
        &self,
        session_id: &str,
        title: Option<&str>,
        entry_type: Option<&str>,
        event_id: Option<&str>,
    );

    /// Called after a successful ledger write with the payload and title.
    fn on_memory_written(&self, payload: &serde_json::Value, title: &str);

    /// The current session ID.
    fn session_id(&self) -> &str;

    /// The current workspace ID (if known).
    fn workspace_id(&self) -> Option<&str>;
}

/// Memory manager orchestrating ledger writing.
///
/// # Fail-Silent
///
/// All errors are caught and logged. The manager never propagates errors
/// to the caller because memory operations are observability, not functionality.
pub struct MemoryManager<D: MemoryManagerDeps> {
    deps: D,
}

impl<D: MemoryManagerDeps> MemoryManager<D> {
    /// Create a new memory manager.
    pub fn new(deps: D) -> Self {
        Self { deps }
    }

    /// Called at the end of each agent response cycle.
    ///
    /// Pipeline:
    /// 1. If ledger enabled → emit updating, write entry, emit updated
    /// 2. If entry written → call `on_memory_written`, spawn embedding
    ///
    /// All errors are caught and logged (fail-silent).
    pub async fn on_cycle_complete(&mut self, info: super::types::CycleInfo) {
        let session_id = self.deps.session_id().to_string();

        // Ledger writing
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
                ledger_result.event_id.as_deref(),
            );

            if let Some(payload) = &ledger_result.payload {
                self.deps.on_memory_written(
                    payload,
                    ledger_result.title.as_deref().unwrap_or("Untitled"),
                );
            }
        } else {
            let entry_type = ledger_result.entry_type.as_deref().unwrap_or("skipped");
            let title = if entry_type == "error" {
                ledger_result.reason.as_deref()
            } else {
                None
            };
            self.deps
                .emit_memory_updated(&session_id, title, Some(entry_type), None);
        }
    }
}

impl<D: MemoryManagerDeps> std::fmt::Debug for MemoryManager<D> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("MemoryManager").finish_non_exhaustive()
    }
}

// Implement MemoryManagerDeps for Arc<T> where T: MemoryManagerDeps
#[async_trait]
impl<T: MemoryManagerDeps> MemoryManagerDeps for Arc<T>
where
    T: Send + Sync,
{
    async fn write_ledger_entry(&self, opts: &LedgerWriteOpts) -> LedgerWriteResult {
        (**self).write_ledger_entry(opts).await
    }
    fn is_ledger_enabled(&self) -> bool {
        (**self).is_ledger_enabled()
    }
    fn emit_memory_updating(&self, session_id: &str) {
        (**self).emit_memory_updating(session_id);
    }
    fn emit_memory_updated(
        &self,
        session_id: &str,
        title: Option<&str>,
        entry_type: Option<&str>,
        event_id: Option<&str>,
    ) {
        (**self).emit_memory_updated(session_id, title, entry_type, event_id);
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

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
    use std::sync::{Arc, Mutex};

    /// Mock deps that track all calls.
    struct MockDeps {
        session_id: String,
        workspace_id: Option<String>,
        ledger_enabled: bool,
        ledger_result: LedgerWriteResult,

        ledger_called: AtomicBool,
        updating_emitted: AtomicBool,
        updated_emitted: AtomicBool,
        updated_entry_type: Mutex<Option<String>>,
        updated_title: Mutex<Option<String>>,
        memory_written_called: AtomicBool,
        updated_count: AtomicUsize,
        updated_event_id: Mutex<Option<String>>,
    }

    impl MockDeps {
        fn new() -> Self {
            Self {
                session_id: "s1".to_string(),
                workspace_id: Some("w1".to_string()),
                ledger_enabled: true,
                ledger_result: LedgerWriteResult::skipped("no content"),
                ledger_called: AtomicBool::new(false),
                updating_emitted: AtomicBool::new(false),
                updated_emitted: AtomicBool::new(false),
                updated_entry_type: Mutex::new(None),
                updated_title: Mutex::new(None),
                memory_written_called: AtomicBool::new(false),
                updated_count: AtomicUsize::new(0),
                updated_event_id: Mutex::new(None),
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
    }

    #[async_trait]
    impl MemoryManagerDeps for MockDeps {
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
            title: Option<&str>,
            entry_type: Option<&str>,
            event_id: Option<&str>,
        ) {
            self.updated_emitted.store(true, Ordering::SeqCst);
            let _ = self.updated_count.fetch_add(1, Ordering::SeqCst);
            if let Some(t) = title {
                *self.updated_title.lock().unwrap() = Some(t.to_string());
            }
            if let Some(et) = entry_type {
                *self.updated_entry_type.lock().unwrap() = Some(et.to_string());
            }
            if let Some(eid) = event_id {
                *self.updated_event_id.lock().unwrap() = Some(eid.to_string());
            }
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

    fn default_cycle_info(ratio: f64) -> super::super::types::CycleInfo {
        super::super::types::CycleInfo {
            model: "claude-opus-4-6".to_string(),
            working_directory: "/tmp".to_string(),
            current_token_ratio: ratio,
            recent_event_types: Vec::new(),
            recent_tool_calls: Vec::new(),
        }
    }

    // --- Ledger disabled ---

    #[tokio::test]
    async fn test_ledger_disabled_no_write() {
        let deps = Arc::new(MockDeps::new().with_ledger_disabled());
        let mut manager = MemoryManager::new(Arc::clone(&deps));

        manager.on_cycle_complete(default_cycle_info(0.3)).await;

        assert!(!deps.ledger_called.load(Ordering::SeqCst));
        assert!(!deps.updating_emitted.load(Ordering::SeqCst));
    }

    // --- Ledger writes ---

    #[tokio::test]
    async fn test_no_compact_ledger_writes() {
        let deps = Arc::new(
            MockDeps::new().with_ledger_result(LedgerWriteResult::written(
                "Test Title".to_string(),
                "feature".to_string(),
                "evt-1".to_string(),
                serde_json::json!({"key": "val"}),
            )),
        );
        let mut manager = MemoryManager::new(Arc::clone(&deps));

        manager.on_cycle_complete(default_cycle_info(0.3)).await;

        assert!(deps.ledger_called.load(Ordering::SeqCst));
        assert!(deps.updating_emitted.load(Ordering::SeqCst));
        assert!(deps.updated_emitted.load(Ordering::SeqCst));
        assert!(deps.memory_written_called.load(Ordering::SeqCst));
    }

    // --- High token ratio no longer triggers compaction (owned by CompactionHandler) ---

    #[tokio::test]
    async fn test_high_ratio_ledger_only() {
        let deps =
            Arc::new(MockDeps::new().with_ledger_result(LedgerWriteResult::skipped("no content")));
        let mut manager = MemoryManager::new(Arc::clone(&deps));

        // High token ratio — MemoryManager should NOT compact (only ledger)
        manager.on_cycle_complete(default_cycle_info(0.80)).await;

        assert!(deps.ledger_called.load(Ordering::SeqCst));
        assert!(deps.updating_emitted.load(Ordering::SeqCst));
    }

    // --- Ledger not written → "skipped" ---

    #[tokio::test]
    async fn test_ledger_not_written_emits_skipped() {
        let deps = Arc::new(MockDeps::new());
        let mut manager = MemoryManager::new(Arc::clone(&deps));

        manager.on_cycle_complete(default_cycle_info(0.3)).await;

        assert!(deps.updated_emitted.load(Ordering::SeqCst));
        let entry_type = deps.updated_entry_type.lock().unwrap();
        assert_eq!(entry_type.as_deref(), Some("skipped"));
    }

    // --- Ledger failed → "error" with reason as title ---

    #[tokio::test]
    async fn test_ledger_failed_emits_error_with_title() {
        let deps = Arc::new(
            MockDeps::new()
                .with_ledger_result(LedgerWriteResult::failed("database temporarily busy")),
        );
        let mut manager = MemoryManager::new(Arc::clone(&deps));

        manager.on_cycle_complete(default_cycle_info(0.3)).await;

        assert!(deps.updated_emitted.load(Ordering::SeqCst));
        let entry_type = deps.updated_entry_type.lock().unwrap();
        assert_eq!(entry_type.as_deref(), Some("error"));
        let title = deps.updated_title.lock().unwrap();
        assert_eq!(title.as_deref(), Some("database temporarily busy"));
    }

    // --- Ledger written → on_memory_written called ---

    #[tokio::test]
    async fn test_ledger_written_calls_on_memory_written() {
        let deps = Arc::new(
            MockDeps::new().with_ledger_result(LedgerWriteResult::written(
                "Title".to_string(),
                "bugfix".to_string(),
                "evt-1".to_string(),
                serde_json::json!({}),
            )),
        );
        let mut manager = MemoryManager::new(Arc::clone(&deps));

        manager.on_cycle_complete(default_cycle_info(0.3)).await;

        assert!(deps.memory_written_called.load(Ordering::SeqCst));
    }

    // --- Ledger written → event_id passed through emit_memory_updated ---

    #[tokio::test]
    async fn test_ledger_written_passes_event_id() {
        let deps = Arc::new(
            MockDeps::new().with_ledger_result(LedgerWriteResult::written(
                "Title".to_string(),
                "feature".to_string(),
                "evt-2".to_string(),
                serde_json::json!({"data": true}),
            )),
        );
        let mut manager = MemoryManager::new(Arc::clone(&deps));

        manager.on_cycle_complete(default_cycle_info(0.3)).await;

        let event_id = deps.updated_event_id.lock().unwrap();
        assert_eq!(event_id.as_deref(), Some("evt-2"));
    }

    // --- Debug impl ---

    #[tokio::test]
    async fn test_debug_impl() {
        let deps = MockDeps::new();
        let manager = MemoryManager::new(deps);
        let debug = format!("{manager:?}");
        assert!(debug.contains("MemoryManager"));
    }
}
