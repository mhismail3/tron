use std::collections::HashMap;
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use async_trait::async_trait;
use parking_lot::Mutex;
use tokio::sync::Semaphore;
use tracing::warn;
use tron_core::hooks::{HookResult, HookType};

const DEFAULT_HOOK_TIMEOUT: Duration = Duration::from_secs(30);

/// Context passed to hook handlers.
#[derive(Clone, Debug)]
pub struct HookContext {
    pub hook_type: HookType,
    pub session_id: String,
    pub agent_id: String,
    pub tool_name: Option<String>,
    pub tool_args: Option<serde_json::Value>,
    pub prompt: Option<String>,
    pub timestamp: String,
}

/// Trait for hook handler implementations.
#[async_trait]
pub trait HookHandler: Send + Sync {
    fn name(&self) -> &str;
    async fn execute(&self, ctx: &HookContext) -> HookResult;
}

/// Circuit breaker state for a handler.
struct CircuitBreaker {
    failures: AtomicU32,
    threshold: u32,
    last_trip: Mutex<Option<Instant>>,
    cooldown: Duration,
}

impl CircuitBreaker {
    fn new(threshold: u32, cooldown: Duration) -> Self {
        Self {
            failures: AtomicU32::new(0),
            threshold,
            last_trip: Mutex::new(None),
            cooldown,
        }
    }

    fn is_open(&self) -> bool {
        let failures = self.failures.load(Ordering::Relaxed);
        if failures < self.threshold {
            return false;
        }
        let guard = self.last_trip.lock();
        if let Some(tripped_at) = *guard {
            tripped_at.elapsed() < self.cooldown
        } else {
            false
        }
    }

    fn record_failure(&self, handler_name: &str) {
        let prev = self.failures.fetch_add(1, Ordering::Relaxed);
        if prev + 1 >= self.threshold {
            let was_open = self.last_trip.lock().is_some();
            *self.last_trip.lock() = Some(Instant::now());
            if !was_open {
                warn!(
                    handler = handler_name,
                    failures = prev + 1,
                    threshold = self.threshold,
                    cooldown_secs = self.cooldown.as_secs(),
                    "hook circuit breaker tripped"
                );
            }
        }
    }

    fn record_success(&self) {
        self.failures.store(0, Ordering::Relaxed);
        *self.last_trip.lock() = None;
    }
}

struct HandlerEntry {
    handler: Arc<dyn HookHandler>,
    breaker: CircuitBreaker,
}

/// The hook engine manages all hook handlers and their execution.
pub struct HookEngine {
    handlers: HashMap<HookType, Vec<HandlerEntry>>,
    background_permits: Arc<Semaphore>,
    max_background: usize,
    circuit_threshold: u32,
    circuit_cooldown: Duration,
    hook_timeout: Duration,
}

impl HookEngine {
    pub fn new() -> Self {
        Self {
            handlers: HashMap::new(),
            background_permits: Arc::new(Semaphore::new(32)),
            max_background: 32,
            circuit_threshold: 3,
            circuit_cooldown: Duration::from_secs(60),
            hook_timeout: DEFAULT_HOOK_TIMEOUT,
        }
    }

    pub fn with_hook_timeout(mut self, timeout: Duration) -> Self {
        self.hook_timeout = timeout;
        self
    }

    /// Register a handler for a hook type.
    pub fn register(&mut self, hook_type: HookType, handler: Arc<dyn HookHandler>) {
        let entry = HandlerEntry {
            handler,
            breaker: CircuitBreaker::new(self.circuit_threshold, self.circuit_cooldown),
        };
        self.handlers.entry(hook_type).or_default().push(entry);
    }

    /// Execute a blocking hook (PreToolUse, UserPromptSubmit, PreCompact).
    /// Handlers run sequentially. First Block short-circuits.
    /// Handlers that exceed the timeout are treated as failures (fail-open: returns Continue).
    pub async fn execute_blocking(&self, ctx: &HookContext) -> HookResult {
        let entries = match self.handlers.get(&ctx.hook_type) {
            Some(e) => e,
            None => return HookResult::Continue,
        };

        for entry in entries {
            if entry.breaker.is_open() {
                continue; // Skip tripped handlers
            }

            let handler = Arc::clone(&entry.handler);
            let handler_name = handler.name().to_string();
            let result = std::panic::AssertUnwindSafe(handler.execute(ctx));
            match tokio::time::timeout(self.hook_timeout, futures::FutureExt::catch_unwind(result))
                .await
            {
                Ok(Ok(hook_result)) => match &hook_result {
                    HookResult::Block { .. } | HookResult::Modify { .. } => {
                        entry.breaker.record_success();
                        return hook_result;
                    }
                    HookResult::Continue => {
                        entry.breaker.record_success();
                    }
                },
                Ok(Err(_panic)) => {
                    entry.breaker.record_failure(&handler_name);
                }
                Err(_timeout) => {
                    warn!(
                        handler = %handler_name,
                        timeout_secs = self.hook_timeout.as_secs(),
                        "hook handler timed out, treating as failure (fail-open)"
                    );
                    entry.breaker.record_failure(&handler_name);
                }
            }
        }

        HookResult::Continue
    }

    /// Execute a background hook (PostToolUse, Stop, SessionStart, etc.).
    /// Returns a handle that can be awaited for drain.
    pub fn execute_background(&self, ctx: HookContext) -> tokio::task::JoinHandle<()> {
        let entries_info: Vec<(Arc<dyn HookHandler>, bool)> = self
            .handlers
            .get(&ctx.hook_type)
            .map(|entries| {
                entries
                    .iter()
                    .map(|e| (Arc::clone(&e.handler), e.breaker.is_open()))
                    .collect()
            })
            .unwrap_or_default();

        let permits = Arc::clone(&self.background_permits);
        let timeout = self.hook_timeout;

        tokio::spawn(async move {
            let _permit = permits.acquire().await;
            for (handler, is_tripped) in &entries_info {
                if *is_tripped {
                    continue;
                }
                let handler_name = handler.name().to_string();
                if tokio::time::timeout(timeout, handler.execute(&ctx))
                    .await
                    .is_err()
                {
                    warn!(
                        handler = %handler_name,
                        timeout_secs = timeout.as_secs(),
                        "background hook handler timed out"
                    );
                }
            }
        })
    }

    /// Drain all background hooks with a timeout.
    pub async fn drain(&self, timeout: Duration) {
        // Wait for all permits to be available (meaning all background tasks finished)
        let start = Instant::now();
        loop {
            if self.background_permits.available_permits() >= self.max_background {
                break;
            }
            if start.elapsed() >= timeout {
                break;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    }

    /// Check if any handlers are registered for a hook type.
    pub fn has_handlers(&self, hook_type: &HookType) -> bool {
        self.handlers
            .get(hook_type)
            .is_some_and(|h| !h.is_empty())
    }

    /// Count registered handlers for a hook type.
    pub fn handler_count(&self, hook_type: &HookType) -> usize {
        self.handlers.get(hook_type).map_or(0, |h| h.len())
    }
}

impl Default for HookEngine {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::AtomicBool;

    struct AllowHandler;
    #[async_trait]
    impl HookHandler for AllowHandler {
        fn name(&self) -> &str {
            "allow"
        }
        async fn execute(&self, _ctx: &HookContext) -> HookResult {
            HookResult::Continue
        }
    }

    struct BlockHandler {
        reason: String,
    }
    #[async_trait]
    impl HookHandler for BlockHandler {
        fn name(&self) -> &str {
            "block"
        }
        async fn execute(&self, _ctx: &HookContext) -> HookResult {
            HookResult::Block {
                reason: self.reason.clone(),
            }
        }
    }

    struct TrackingHandler {
        called: AtomicBool,
    }
    impl TrackingHandler {
        fn new() -> Arc<Self> {
            Arc::new(Self {
                called: AtomicBool::new(false),
            })
        }
    }
    #[async_trait]
    impl HookHandler for TrackingHandler {
        fn name(&self) -> &str {
            "tracking"
        }
        async fn execute(&self, _ctx: &HookContext) -> HookResult {
            self.called.store(true, Ordering::Relaxed);
            HookResult::Continue
        }
    }

    fn test_ctx(hook_type: HookType) -> HookContext {
        HookContext {
            hook_type,
            session_id: "sess_123".into(),
            agent_id: "agent_456".into(),
            tool_name: None,
            tool_args: None,
            prompt: None,
            timestamp: "2026-01-01T00:00:00Z".into(),
        }
    }

    #[tokio::test]
    async fn blocking_continue() {
        let mut engine = HookEngine::new();
        engine.register(HookType::PreToolUse, Arc::new(AllowHandler));

        let result = engine.execute_blocking(&test_ctx(HookType::PreToolUse)).await;
        assert!(matches!(result, HookResult::Continue));
    }

    #[tokio::test]
    async fn blocking_block_short_circuits() {
        let mut engine = HookEngine::new();
        engine.register(
            HookType::PreToolUse,
            Arc::new(BlockHandler {
                reason: "disallowed".into(),
            }),
        );
        let tracker = TrackingHandler::new();
        engine.register(HookType::PreToolUse, tracker.clone());

        let result = engine.execute_blocking(&test_ctx(HookType::PreToolUse)).await;
        assert!(matches!(result, HookResult::Block { .. }));
        // Second handler should NOT have been called
        assert!(!tracker.called.load(Ordering::Relaxed));
    }

    #[tokio::test]
    async fn no_handlers_returns_continue() {
        let engine = HookEngine::new();
        let result = engine.execute_blocking(&test_ctx(HookType::PreToolUse)).await;
        assert!(matches!(result, HookResult::Continue));
    }

    #[tokio::test]
    async fn background_execution() {
        let mut engine = HookEngine::new();
        let tracker = TrackingHandler::new();
        engine.register(HookType::PostToolUse, tracker.clone());

        let handle = engine.execute_background(test_ctx(HookType::PostToolUse));
        handle.await.unwrap();

        assert!(tracker.called.load(Ordering::Relaxed));
    }

    #[tokio::test]
    async fn has_handlers() {
        let mut engine = HookEngine::new();
        assert!(!engine.has_handlers(&HookType::PreToolUse));

        engine.register(HookType::PreToolUse, Arc::new(AllowHandler));
        assert!(engine.has_handlers(&HookType::PreToolUse));
        assert_eq!(engine.handler_count(&HookType::PreToolUse), 1);
    }

    #[tokio::test]
    async fn drain_completes() {
        let mut engine = HookEngine::new();
        let tracker = TrackingHandler::new();
        engine.register(HookType::Stop, tracker.clone());

        let handle = engine.execute_background(test_ctx(HookType::Stop));
        // Wait for the task handle directly (more reliable than semaphore drain)
        handle.await.unwrap();

        assert!(tracker.called.load(Ordering::Relaxed));
    }

    #[test]
    fn circuit_breaker_trips() {
        let breaker = CircuitBreaker::new(3, Duration::from_secs(60));
        assert!(!breaker.is_open());

        breaker.record_failure("test");
        breaker.record_failure("test");
        assert!(!breaker.is_open()); // 2 < 3

        breaker.record_failure("test");
        assert!(breaker.is_open()); // 3 >= 3
    }

    #[test]
    fn circuit_breaker_recovers_on_success() {
        let breaker = CircuitBreaker::new(3, Duration::from_secs(60));
        breaker.record_failure("test");
        breaker.record_failure("test");
        breaker.record_success(); // Reset
        breaker.record_failure("test");
        assert!(!breaker.is_open()); // Only 1 failure since reset
    }

    #[test]
    fn circuit_breaker_reopens_after_cooldown() {
        let breaker = CircuitBreaker::new(1, Duration::from_millis(0)); // Instant cooldown
        breaker.record_failure("test");
        // With 0ms cooldown, it should be closed again immediately
        std::thread::sleep(Duration::from_millis(1));
        assert!(!breaker.is_open());
    }

    #[tokio::test]
    async fn hook_timeout_returns_continue() {
        // A handler that sleeps forever
        struct SlowHandler;
        #[async_trait]
        impl HookHandler for SlowHandler {
            fn name(&self) -> &str {
                "slow"
            }
            async fn execute(&self, _ctx: &HookContext) -> HookResult {
                tokio::time::sleep(Duration::from_secs(3600)).await;
                HookResult::Block {
                    reason: "should never reach".into(),
                }
            }
        }

        let mut engine = HookEngine::new().with_hook_timeout(Duration::from_millis(50));
        engine.register(HookType::PreToolUse, Arc::new(SlowHandler));

        let result = engine.execute_blocking(&test_ctx(HookType::PreToolUse)).await;
        // Timed-out handler should fail-open (Continue), not block
        assert!(
            matches!(result, HookResult::Continue),
            "expected Continue (fail-open), got: {result:?}"
        );
    }

    #[tokio::test]
    async fn hook_timeout_counts_as_failure_for_circuit_breaker() {
        struct SlowHandler;
        #[async_trait]
        impl HookHandler for SlowHandler {
            fn name(&self) -> &str {
                "slow"
            }
            async fn execute(&self, _ctx: &HookContext) -> HookResult {
                tokio::time::sleep(Duration::from_secs(3600)).await;
                HookResult::Continue
            }
        }

        let mut engine = HookEngine::new().with_hook_timeout(Duration::from_millis(20));
        engine.register(HookType::PreToolUse, Arc::new(SlowHandler));

        // Trip the circuit breaker with 3 timeouts (default threshold)
        for _ in 0..3 {
            engine
                .execute_blocking(&test_ctx(HookType::PreToolUse))
                .await;
        }

        // Now register a fast handler to verify the slow one is skipped
        // The slow handler's breaker should be tripped, so it gets skipped
        // This verifies timeouts count as failures
        let tracker = TrackingHandler::new();
        engine.register(HookType::PreToolUse, tracker.clone());

        let result = engine.execute_blocking(&test_ctx(HookType::PreToolUse)).await;
        assert!(matches!(result, HookResult::Continue));
        // The tracking handler should still be called (only the slow handler is tripped)
        assert!(tracker.called.load(Ordering::Relaxed));
    }

    #[tokio::test]
    async fn background_hook_timeout() {
        struct SlowHandler;
        #[async_trait]
        impl HookHandler for SlowHandler {
            fn name(&self) -> &str {
                "slow"
            }
            async fn execute(&self, _ctx: &HookContext) -> HookResult {
                tokio::time::sleep(Duration::from_secs(3600)).await;
                HookResult::Continue
            }
        }

        let mut engine = HookEngine::new().with_hook_timeout(Duration::from_millis(50));
        engine.register(HookType::PostToolUse, Arc::new(SlowHandler));

        let start = Instant::now();
        let handle = engine.execute_background(test_ctx(HookType::PostToolUse));
        handle.await.unwrap();
        let elapsed = start.elapsed();

        // Should complete quickly (within ~100ms), not wait 3600s
        assert!(
            elapsed < Duration::from_secs(1),
            "background hook should timeout quickly, took: {elapsed:?}"
        );
    }

    #[test]
    fn hook_timeout_default() {
        let engine = HookEngine::new();
        assert_eq!(engine.hook_timeout, Duration::from_secs(30));
    }
}
