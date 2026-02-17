//! Provider health tracking — rolling-window error rate monitoring.
//!
//! Tracks per-provider request outcomes in a fixed-size ring buffer.
//! When the error rate exceeds a threshold, logs a warning and sets a
//! `provider_degraded` gauge metric. This is observability-only — it never
//! blocks requests (single-provider mode).

use std::collections::HashMap;
use std::sync::Mutex;

use tracing::warn;

/// Default window size for tracking recent requests.
const DEFAULT_WINDOW_SIZE: usize = 10;

/// Default error rate threshold (50%) to mark a provider as degraded.
const DEFAULT_DEGRADED_THRESHOLD: f64 = 0.5;

/// Per-provider health tracker.
///
/// Thread-safe (interior `Mutex`). Create one at server startup and share
/// via `Arc<ProviderHealthTracker>`.
pub struct ProviderHealthTracker {
    inner: Mutex<Inner>,
    window_size: usize,
    threshold: f64,
}

struct Inner {
    /// Per-provider ring buffers: `true` = success, `false` = failure.
    providers: HashMap<String, ProviderWindow>,
}

struct ProviderWindow {
    outcomes: Vec<bool>,
    cursor: usize,
    total: usize,
}

impl ProviderWindow {
    fn new(size: usize) -> Self {
        Self {
            outcomes: vec![true; size],
            cursor: 0,
            total: 0,
        }
    }

    fn record(&mut self, success: bool) {
        self.outcomes[self.cursor] = success;
        self.cursor = (self.cursor + 1) % self.outcomes.len();
        self.total += 1;
    }

    #[allow(clippy::cast_precision_loss)] // window_size is tiny (≤100), no precision loss
    fn error_rate(&self) -> f64 {
        if self.total == 0 {
            return 0.0;
        }
        let count = self.outcomes.len().min(self.total);
        let failures = self.outcomes[..count]
            .iter()
            .filter(|&&ok| !ok)
            .count();
        failures as f64 / count as f64
    }
}

impl ProviderHealthTracker {
    /// Create a new tracker with default settings.
    pub fn new() -> Self {
        Self {
            inner: Mutex::new(Inner {
                providers: HashMap::new(),
            }),
            window_size: DEFAULT_WINDOW_SIZE,
            threshold: DEFAULT_DEGRADED_THRESHOLD,
        }
    }

    /// Create a tracker with custom window size and threshold.
    pub fn with_config(window_size: usize, threshold: f64) -> Self {
        Self {
            inner: Mutex::new(Inner {
                providers: HashMap::new(),
            }),
            window_size: window_size.max(1),
            threshold: threshold.clamp(0.0, 1.0),
        }
    }

    /// Record a successful request for a provider.
    pub fn record_success(&self, provider: &str) {
        self.record(provider, true);
    }

    /// Record a failed request for a provider.
    pub fn record_failure(&self, provider: &str) {
        self.record(provider, false);
    }

    /// Check if a provider is currently degraded (error rate above threshold).
    pub fn is_degraded(&self, provider: &str) -> bool {
        let inner = self.inner.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        inner
            .providers
            .get(provider)
            .is_some_and(|w| w.total >= 2 && w.error_rate() > self.threshold)
    }

    /// Get the current error rate for a provider (0.0–1.0).
    pub fn error_rate(&self, provider: &str) -> f64 {
        let inner = self.inner.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        inner
            .providers
            .get(provider)
            .map_or(0.0, ProviderWindow::error_rate)
    }

    fn record(&self, provider: &str, success: bool) {
        let mut inner = self.inner.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        let window = inner
            .providers
            .entry(provider.to_string())
            .or_insert_with(|| ProviderWindow::new(self.window_size));
        window.record(success);

        let rate = window.error_rate();
        let degraded = window.total >= 2 && rate > self.threshold;

        // Update gauge metric
        let gauge_val = if degraded { 1.0 } else { 0.0 };
        metrics::gauge!("provider_degraded", "provider" => provider.to_string()).set(gauge_val);

        if degraded && !success {
            warn!(
                provider,
                error_rate = format!("{:.0}%", rate * 100.0),
                window = self.window_size,
                "provider degraded — high error rate"
            );
        }
    }
}

impl std::fmt::Debug for ProviderHealthTracker {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ProviderHealthTracker")
            .field("window_size", &self.window_size)
            .field("threshold", &self.threshold)
            .finish_non_exhaustive()
    }
}

impl Default for ProviderHealthTracker {
    fn default() -> Self {
        Self::new()
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn new_provider_not_degraded() {
        let tracker = ProviderHealthTracker::new();
        assert!(!tracker.is_degraded("anthropic"));
        assert!((tracker.error_rate("anthropic") - 0.0).abs() < f64::EPSILON);
    }

    #[test]
    fn all_successes_not_degraded() {
        let tracker = ProviderHealthTracker::new();
        for _ in 0..10 {
            tracker.record_success("anthropic");
        }
        assert!(!tracker.is_degraded("anthropic"));
        assert!((tracker.error_rate("anthropic") - 0.0).abs() < f64::EPSILON);
    }

    #[test]
    fn all_failures_degraded() {
        let tracker = ProviderHealthTracker::new();
        for _ in 0..10 {
            tracker.record_failure("anthropic");
        }
        assert!(tracker.is_degraded("anthropic"));
        assert!((tracker.error_rate("anthropic") - 1.0).abs() < f64::EPSILON);
    }

    #[test]
    fn mixed_below_threshold_not_degraded() {
        let tracker = ProviderHealthTracker::with_config(10, 0.5);
        // 4 failures, 6 successes = 40% error rate < 50%
        for _ in 0..4 {
            tracker.record_failure("openai");
        }
        for _ in 0..6 {
            tracker.record_success("openai");
        }
        assert!(!tracker.is_degraded("openai"));
    }

    #[test]
    fn mixed_above_threshold_degraded() {
        let tracker = ProviderHealthTracker::with_config(10, 0.5);
        // 6 failures, 4 successes = 60% error rate > 50%
        for _ in 0..6 {
            tracker.record_failure("google");
        }
        for _ in 0..4 {
            tracker.record_success("google");
        }
        assert!(tracker.is_degraded("google"));
    }

    #[test]
    fn rolling_window_recovers() {
        let tracker = ProviderHealthTracker::with_config(4, 0.5);
        // Fill with failures → degraded
        for _ in 0..4 {
            tracker.record_failure("anthropic");
        }
        assert!(tracker.is_degraded("anthropic"));

        // Record successes to push failures out of window
        for _ in 0..4 {
            tracker.record_success("anthropic");
        }
        assert!(!tracker.is_degraded("anthropic"));
    }

    #[test]
    fn single_failure_not_degraded() {
        let tracker = ProviderHealthTracker::new();
        tracker.record_failure("anthropic");
        // total=1, need at least 2 for degraded check
        assert!(!tracker.is_degraded("anthropic"));
    }

    #[test]
    fn independent_providers() {
        let tracker = ProviderHealthTracker::with_config(4, 0.5);
        for _ in 0..4 {
            tracker.record_failure("anthropic");
        }
        for _ in 0..4 {
            tracker.record_success("openai");
        }
        assert!(tracker.is_degraded("anthropic"));
        assert!(!tracker.is_degraded("openai"));
    }

    #[test]
    fn error_rate_accuracy() {
        let tracker = ProviderHealthTracker::with_config(4, 0.5);
        tracker.record_success("p");
        tracker.record_failure("p");
        tracker.record_success("p");
        tracker.record_failure("p");
        // Window: [S, F, S, F] → 50% error rate
        assert!((tracker.error_rate("p") - 0.5).abs() < f64::EPSILON);
    }

    #[test]
    fn is_send_sync() {
        fn assert_send_sync<T: Send + Sync>() {}
        assert_send_sync::<ProviderHealthTracker>();
    }
}
