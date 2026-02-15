use std::pin::Pin;
use std::sync::atomic::{AtomicU32, AtomicU64, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use async_trait::async_trait;
use futures::Stream;
use parking_lot::RwLock;
use tracing::{info, warn};

use tron_core::context::LlmContext;
use tron_core::errors::GatewayError;
use tron_core::provider::{LlmProvider, StreamOptions};
use tron_core::stream::StreamEvent;

/// Configuration for the ReliableProvider retry and circuit breaker behavior.
#[derive(Clone, Debug)]
pub struct ReliableConfig {
    pub max_retries: u32,
    pub base_delay: Duration,
    pub max_delay: Duration,
    pub jitter_factor: f64,
    pub circuit_breaker_threshold: u32,
    pub circuit_breaker_cooldown: Duration,
}

impl Default for ReliableConfig {
    fn default() -> Self {
        Self {
            max_retries: 3,
            base_delay: Duration::from_secs(1),
            max_delay: Duration::from_secs(30),
            jitter_factor: 0.2,
            circuit_breaker_threshold: 3,
            circuit_breaker_cooldown: Duration::from_secs(60),
        }
    }
}

/// Circuit breaker state machine.
#[derive(Clone, Debug, PartialEq, Eq)]
enum CircuitState {
    Closed,
    Open { since: Instant },
    HalfOpen,
}

/// Wraps an LlmProvider with retry logic and circuit breaker.
///
/// - Retries retryable errors with exponential backoff + jitter
/// - Respects `retry_after` hints from rate limit responses
/// - Circuit breaker: N consecutive failures → open → cooldown → half-open → success → closed
/// - Once any StreamEvent data has been yielded, retries are NOT attempted (stream is committed)
pub struct ReliableProvider<P: LlmProvider> {
    inner: P,
    config: ReliableConfig,
    circuit_state: Arc<RwLock<CircuitState>>,
    consecutive_failures: Arc<AtomicU32>,
    total_retries: Arc<AtomicU64>,
}

impl<P: LlmProvider> ReliableProvider<P> {
    pub fn new(inner: P, config: ReliableConfig) -> Self {
        Self {
            inner,
            config,
            circuit_state: Arc::new(RwLock::new(CircuitState::Closed)),
            consecutive_failures: Arc::new(AtomicU32::new(0)),
            total_retries: Arc::new(AtomicU64::new(0)),
        }
    }

    pub fn with_defaults(inner: P) -> Self {
        Self::new(inner, ReliableConfig::default())
    }

    /// Check if the circuit breaker allows a request through.
    fn check_circuit(&self) -> Result<(), GatewayError> {
        let state = self.circuit_state.read();
        match &*state {
            CircuitState::Closed | CircuitState::HalfOpen => Ok(()),
            CircuitState::Open { since } => {
                if since.elapsed() >= self.config.circuit_breaker_cooldown {
                    drop(state);
                    *self.circuit_state.write() = CircuitState::HalfOpen;
                    Ok(())
                } else {
                    Err(GatewayError::ProviderOverloaded)
                }
            }
        }
    }

    /// Record a successful request — reset circuit breaker.
    fn record_success(&self) {
        self.consecutive_failures.store(0, Ordering::Relaxed);
        let mut state = self.circuit_state.write();
        if *state != CircuitState::Closed {
            info!("circuit breaker closed after successful request");
            *state = CircuitState::Closed;
        }
    }

    /// Record a failed request — potentially trip circuit breaker.
    fn record_failure(&self) {
        let failures = self.consecutive_failures.fetch_add(1, Ordering::Relaxed) + 1;
        if failures >= self.config.circuit_breaker_threshold {
            let mut state = self.circuit_state.write();
            if *state == CircuitState::Closed || *state == CircuitState::HalfOpen {
                warn!(
                    failures = failures,
                    cooldown_secs = self.config.circuit_breaker_cooldown.as_secs(),
                    "circuit breaker opened after {} consecutive failures",
                    failures
                );
                *state = CircuitState::Open {
                    since: Instant::now(),
                };
            }
        }
    }

    /// Calculate delay for a retry attempt using exponential backoff + jitter.
    fn retry_delay(&self, attempt: u32, suggested: Option<Duration>) -> Duration {
        // Respect server-suggested delay if provided
        if let Some(delay) = suggested {
            return delay;
        }

        // Exponential backoff: base * 2^attempt
        let exp_delay = self.config.base_delay.as_millis() as f64 * 2.0_f64.powi(attempt as i32);
        let capped = exp_delay.min(self.config.max_delay.as_millis() as f64);

        // Add jitter: delay * (1 ± jitter_factor)
        let jitter_range = capped * self.config.jitter_factor;
        let jitter = (random_u64() % (jitter_range as u64 * 2 + 1)) as f64 - jitter_range;
        let final_ms = (capped + jitter).max(100.0);

        Duration::from_millis(final_ms as u64)
    }

    pub fn total_retries(&self) -> u64 {
        self.total_retries.load(Ordering::Relaxed)
    }

    pub fn circuit_state_name(&self) -> &'static str {
        match &*self.circuit_state.read() {
            CircuitState::Closed => "closed",
            CircuitState::Open { .. } => "open",
            CircuitState::HalfOpen => "half_open",
        }
    }
}

/// Simple non-cryptographic random u64 using thread-local state.
fn random_u64() -> u64 {
    use std::cell::Cell;
    use std::time::SystemTime;

    thread_local! {
        static STATE: Cell<u64> = Cell::new(
            SystemTime::now()
                .duration_since(SystemTime::UNIX_EPOCH)
                .unwrap_or_default()
                .as_nanos() as u64
        );
    }

    STATE.with(|s| {
        // xorshift64
        let mut x = s.get();
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        s.set(x);
        x
    })
}

#[async_trait]
impl<P: LlmProvider> LlmProvider for ReliableProvider<P> {
    fn name(&self) -> &str {
        self.inner.name()
    }

    fn model(&self) -> &str {
        self.inner.model()
    }

    fn context_window(&self) -> usize {
        self.inner.context_window()
    }

    fn supports_thinking(&self) -> bool {
        self.inner.supports_thinking()
    }

    fn supports_tools(&self) -> bool {
        self.inner.supports_tools()
    }

    async fn stream(
        &self,
        context: &LlmContext,
        options: &StreamOptions,
    ) -> Result<Pin<Box<dyn Stream<Item = StreamEvent> + Send>>, GatewayError> {
        self.check_circuit()?;

        let mut last_error: Option<GatewayError> = None;

        for attempt in 0..=self.config.max_retries {
            match self.inner.stream(context, options).await {
                Ok(stream) => {
                    self.record_success();
                    return Ok(stream);
                }
                Err(e) => {
                    if e.is_fatal() || attempt == self.config.max_retries {
                        self.record_failure();
                        return Err(e);
                    }

                    if !e.is_retryable() {
                        self.record_failure();
                        return Err(e);
                    }

                    let delay = self.retry_delay(attempt, e.suggested_delay());
                    self.total_retries.fetch_add(1, Ordering::Relaxed);

                    warn!(
                        attempt = attempt + 1,
                        max_retries = self.config.max_retries,
                        delay_ms = delay.as_millis() as u64,
                        error = %e,
                        "retrying after error"
                    );

                    last_error = Some(e);
                    tokio::time::sleep(delay).await;

                    // Re-check circuit after sleep
                    self.check_circuit()?;
                }
            }
        }

        Err(last_error.unwrap_or(GatewayError::NetworkError("max retries exceeded".into())))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::mock::{MockProvider, MockResponse};

    #[tokio::test]
    async fn success_on_first_try() {
        let mock = MockProvider::new(vec![MockResponse::stream_text("hello")]);
        let reliable = ReliableProvider::with_defaults(mock);

        let context = LlmContext::empty();
        let result = reliable.stream(&context, &StreamOptions::default()).await;
        assert!(result.is_ok());
        assert_eq!(reliable.total_retries(), 0);
    }

    #[tokio::test]
    async fn retries_on_retryable_error() {
        let mock = MockProvider::new(vec![
            MockResponse::Error(GatewayError::ServerError {
                status: 500,
                body: "internal".into(),
            }),
            MockResponse::Error(GatewayError::ServerError {
                status: 500,
                body: "internal".into(),
            }),
            MockResponse::stream_text("recovered"),
        ]);

        let config = ReliableConfig {
            max_retries: 3,
            base_delay: Duration::from_millis(10),
            max_delay: Duration::from_millis(50),
            ..Default::default()
        };
        let reliable = ReliableProvider::new(mock, config);

        let context = LlmContext::empty();
        let result = reliable.stream(&context, &StreamOptions::default()).await;
        assert!(result.is_ok());
        assert_eq!(reliable.total_retries(), 2);
    }

    #[tokio::test]
    async fn fatal_error_not_retried() {
        let mock = MockProvider::new(vec![
            MockResponse::Error(GatewayError::AuthenticationFailed("bad key".into())),
            MockResponse::stream_text("should not reach"),
        ]);

        let reliable = ReliableProvider::with_defaults(mock);

        let context = LlmContext::empty();
        let result = reliable.stream(&context, &StreamOptions::default()).await;
        let err = result.err().expect("expected error");
        assert!(matches!(err, GatewayError::AuthenticationFailed(_)));
        assert_eq!(reliable.total_retries(), 0);
    }

    #[tokio::test]
    async fn max_retries_exhausted() {
        let mock = MockProvider::new(vec![
            MockResponse::Error(GatewayError::ServerError {
                status: 500,
                body: "fail".into(),
            }),
            MockResponse::Error(GatewayError::ServerError {
                status: 500,
                body: "fail".into(),
            }),
            MockResponse::Error(GatewayError::ServerError {
                status: 500,
                body: "fail".into(),
            }),
            MockResponse::Error(GatewayError::ServerError {
                status: 500,
                body: "fail".into(),
            }),
        ]);

        let config = ReliableConfig {
            max_retries: 3,
            base_delay: Duration::from_millis(1),
            max_delay: Duration::from_millis(5),
            ..Default::default()
        };
        let reliable = ReliableProvider::new(mock, config);

        let context = LlmContext::empty();
        let result = reliable.stream(&context, &StreamOptions::default()).await;
        assert!(result.is_err());
        assert_eq!(reliable.total_retries(), 3);
    }

    #[tokio::test]
    async fn circuit_breaker_trips_after_threshold() {
        let mock = MockProvider::new(vec![
            MockResponse::Error(GatewayError::ServerError { status: 500, body: "1".into() }),
            MockResponse::Error(GatewayError::ServerError { status: 500, body: "2".into() }),
            MockResponse::Error(GatewayError::ServerError { status: 500, body: "3".into() }),
            MockResponse::Error(GatewayError::ServerError { status: 500, body: "4".into() }),
            // Circuit should be open now, so the provider won't be called
            MockResponse::stream_text("unreachable"),
        ]);

        let config = ReliableConfig {
            max_retries: 0, // No retries — each call is a single attempt
            base_delay: Duration::from_millis(1),
            max_delay: Duration::from_millis(5),
            circuit_breaker_threshold: 3,
            circuit_breaker_cooldown: Duration::from_secs(60),
            ..Default::default()
        };
        let reliable = ReliableProvider::new(mock, config);
        let context = LlmContext::empty();

        // First 3 calls fail, tripping the breaker
        for _ in 0..3 {
            let _ = reliable.stream(&context, &StreamOptions::default()).await;
        }

        assert_eq!(reliable.circuit_state_name(), "open");

        // 4th call should be rejected by circuit breaker without hitting provider
        let result = reliable.stream(&context, &StreamOptions::default()).await;
        let err = result.err().expect("expected error");
        assert!(matches!(err, GatewayError::ProviderOverloaded));
    }

    #[tokio::test]
    async fn circuit_breaker_recovers_after_cooldown() {
        let mock = MockProvider::new(vec![
            MockResponse::Error(GatewayError::ServerError { status: 500, body: "1".into() }),
            MockResponse::Error(GatewayError::ServerError { status: 500, body: "2".into() }),
            MockResponse::Error(GatewayError::ServerError { status: 500, body: "3".into() }),
            MockResponse::stream_text("recovered"),
        ]);

        let config = ReliableConfig {
            max_retries: 0,
            base_delay: Duration::from_millis(1),
            max_delay: Duration::from_millis(5),
            circuit_breaker_threshold: 3,
            circuit_breaker_cooldown: Duration::from_millis(50), // Very short for testing
            ..Default::default()
        };
        let reliable = ReliableProvider::new(mock, config);
        let context = LlmContext::empty();

        // Trip the breaker
        for _ in 0..3 {
            let _ = reliable.stream(&context, &StreamOptions::default()).await;
        }
        assert_eq!(reliable.circuit_state_name(), "open");

        // Wait for cooldown
        tokio::time::sleep(Duration::from_millis(60)).await;

        // Should transition to half-open and succeed
        let result = reliable.stream(&context, &StreamOptions::default()).await;
        assert!(result.is_ok());
        assert_eq!(reliable.circuit_state_name(), "closed");
    }

    #[test]
    fn retry_delay_respects_suggested() {
        let mock = MockProvider::new(vec![]);
        let reliable = ReliableProvider::with_defaults(mock);

        let delay = reliable.retry_delay(0, Some(Duration::from_secs(5)));
        assert_eq!(delay, Duration::from_secs(5));
    }

    #[test]
    fn retry_delay_exponential_backoff() {
        let mock = MockProvider::new(vec![]);
        let config = ReliableConfig {
            base_delay: Duration::from_millis(100),
            max_delay: Duration::from_secs(30),
            jitter_factor: 0.0, // No jitter for deterministic test
            ..Default::default()
        };
        let reliable = ReliableProvider::new(mock, config);

        let d0 = reliable.retry_delay(0, None);
        let d1 = reliable.retry_delay(1, None);
        let d2 = reliable.retry_delay(2, None);

        assert_eq!(d0.as_millis(), 100);
        assert_eq!(d1.as_millis(), 200);
        assert_eq!(d2.as_millis(), 400);
    }

    #[test]
    fn retry_delay_capped_at_max() {
        let mock = MockProvider::new(vec![]);
        let config = ReliableConfig {
            base_delay: Duration::from_secs(1),
            max_delay: Duration::from_secs(5),
            jitter_factor: 0.0,
            ..Default::default()
        };
        let reliable = ReliableProvider::new(mock, config);

        let d10 = reliable.retry_delay(10, None); // 1s * 2^10 = 1024s, capped at 5s
        assert_eq!(d10.as_millis(), 5000);
    }

    #[test]
    fn config_defaults() {
        let config = ReliableConfig::default();
        assert_eq!(config.max_retries, 3);
        assert_eq!(config.base_delay, Duration::from_secs(1));
        assert_eq!(config.max_delay, Duration::from_secs(30));
        assert!((config.jitter_factor - 0.2).abs() < f64::EPSILON);
        assert_eq!(config.circuit_breaker_threshold, 3);
        assert_eq!(config.circuit_breaker_cooldown, Duration::from_secs(60));
    }

    #[test]
    fn provider_delegates_properties() {
        let mock = MockProvider::new(vec![]);
        let reliable = ReliableProvider::with_defaults(mock);
        assert_eq!(reliable.name(), "mock");
        assert_eq!(reliable.model(), "mock-model");
        assert_eq!(reliable.context_window(), 200_000);
        assert!(reliable.supports_thinking());
        assert!(reliable.supports_tools());
    }
}
