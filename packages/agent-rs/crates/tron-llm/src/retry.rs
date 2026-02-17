//! # Stream Retry
//!
//! Wraps a provider's stream method with exponential backoff retry logic.
//!
//! **Key constraint**: Retries are only possible if no data has been yielded yet.
//! Once the first [`StreamEvent`] is emitted to the caller, the stream cannot be
//! restarted (the caller may have already acted on the events).
//!
//! The retry wrapper:
//! 1. Calls the stream factory
//! 2. If it fails before yielding any data, waits with backoff and retries
//! 3. Emits [`StreamEvent::Retry`] events before each retry wait
//! 4. Respects cancellation via `CancellationToken`
//!
//! [`StreamEvent`]: tron_core::StreamEvent

use std::future::Future;
use std::pin::Pin;

use futures::Stream;
use tokio_util::sync::CancellationToken;
use tron_core::events::{RetryErrorInfo, StreamEvent};
use tron_core::retry::RetryConfig;

use crate::provider::{ProviderError, StreamEventStream};

/// Configuration for stream retry behavior.
#[derive(Clone, Debug)]
pub struct StreamRetryConfig {
    /// Base retry config (max retries, backoff, jitter).
    pub retry: RetryConfig,
    /// Whether to emit [`StreamEvent::Retry`] events before each retry.
    pub emit_retry_events: bool,
    /// Cancellation token for aborting retries.
    pub cancel_token: Option<CancellationToken>,
}

impl Default for StreamRetryConfig {
    fn default() -> Self {
        Self {
            retry: RetryConfig::default(),
            emit_retry_events: true,
            cancel_token: None,
        }
    }
}

/// Type alias for the stream factory function.
///
/// Called on each retry attempt to create a new stream.
pub type StreamFactory = Box<
    dyn Fn() -> Pin<
            Box<
                dyn Future<
                        Output = Result<
                            Pin<Box<dyn Stream<Item = Result<StreamEvent, ProviderError>> + Send>>,
                            ProviderError,
                        >,
                    > + Send,
            >,
        > + Send,
>;

/// Wrap a stream factory with retry logic.
///
/// Returns a new stream that transparently retries on failure. The retry
/// is only attempted if no events have been yielded yet — once data starts
/// flowing, errors are passed through to the caller.
///
/// # Arguments
///
/// * `factory` - Creates a new stream on each attempt.
/// * `config` - Retry configuration.
pub fn with_provider_retry(
    factory: StreamFactory,
    config: StreamRetryConfig,
) -> Pin<Box<dyn Stream<Item = Result<StreamEvent, ProviderError>> + Send>> {
    use futures::StreamExt;

    type Item = Result<StreamEvent, ProviderError>;

    #[allow(unused_assignments)] // has_yielded is read in the Err branch after Ok sets it
    Box::pin(async_stream::stream! {
        let max_retries = config.retry.max_retries;
        let mut attempt = 0u32;
        let mut has_yielded = false;

        loop {
            let stream_result: Result<StreamEventStream, ProviderError> = factory().await;
            match stream_result {
                Ok(inner) => {
                    let mut inner = std::pin::pin!(inner);
                    while let Some(item) = StreamExt::next(&mut inner).await {
                        has_yielded = true;
                        let v: Item = item;
                        yield v;
                    }
                    // Stream completed normally
                    break;
                }
                Err(err) => {
                    if has_yielded {
                        let v: Item = Err(err);
                        yield v;
                        break;
                    }

                    if !err.is_retryable() || attempt >= max_retries {
                        let v: Item = Err(err);
                        yield v;
                        break;
                    }

                    // Check cancellation
                    if let Some(ref token) = config.cancel_token {
                        if token.is_cancelled() {
                            let v: Item = Err(ProviderError::Cancelled);
                            yield v;
                            break;
                        }
                    }

                    attempt += 1;
                    let backoff_ms = tron_core::retry::calculate_backoff_delay(
                        attempt,
                        config.retry.base_delay_ms,
                        config.retry.max_delay_ms,
                        config.retry.jitter_factor,
                    );
                    // Respect Retry-After header if available (use the larger value)
                    let delay_ms = err.retry_after_ms().map_or(backoff_ms, |ra| backoff_ms.max(ra));

                    // Record retry metric
                    metrics::counter!("provider_retries_total", "category" => err.category().to_string()).increment(1);

                    // Emit retry event
                    if config.emit_retry_events {
                        let v: Item = Ok(StreamEvent::Retry {
                            attempt,
                            max_retries,
                            delay_ms,
                            error: RetryErrorInfo {
                                category: err.category().to_string(),
                                message: err.to_string(),
                                is_retryable: true,
                            },
                        });
                        yield v;
                    }

                    // Wait with cancellation support
                    if let Some(ref token) = config.cancel_token {
                        tokio::select! {
                            () = tokio::time::sleep(std::time::Duration::from_millis(delay_ms)) => {}
                            () = token.cancelled() => {
                                let v: Item = Err(ProviderError::Cancelled);
                                yield v;
                                break;
                            }
                        }
                    } else {
                        tokio::time::sleep(std::time::Duration::from_millis(delay_ms)).await;
                    }
                }
            }
        }
    })
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use futures::StreamExt;
    use std::sync::atomic::{AtomicU32, Ordering};
    use std::sync::Arc;
    use tron_core::events::AssistantMessage;

    fn success_factory() -> StreamFactory {
        Box::new(|| {
            Box::pin(async {
                let stream = futures::stream::iter(vec![
                    Ok(StreamEvent::Start),
                    Ok(StreamEvent::Done {
                        message: AssistantMessage {
                            content: vec![],
                            token_usage: None,
                        },
                        stop_reason: "end_turn".to_string(),
                    }),
                ]);
                Ok(
                    Box::pin(stream)
                        as Pin<
                            Box<dyn Stream<Item = Result<StreamEvent, ProviderError>> + Send>,
                        >,
                )
            })
        })
    }

    fn failing_factory(
        fail_count: u32,
        attempt_counter: Arc<AtomicU32>,
    ) -> StreamFactory {
        Box::new(move || {
            let counter = attempt_counter.clone();
            let fail_count = fail_count;
            Box::pin(async move {
                let current = counter.fetch_add(1, Ordering::SeqCst);
                if current < fail_count {
                    Err(ProviderError::Api {
                        status: 500,
                        message: "Server error".to_string(),
                        code: None,
                        retryable: true,
                    })
                } else {
                    let stream = futures::stream::iter(vec![
                        Ok(StreamEvent::Start),
                        Ok(StreamEvent::Done {
                            message: AssistantMessage {
                                content: vec![],
                                token_usage: None,
                            },
                            stop_reason: "end_turn".to_string(),
                        }),
                    ]);
                    Ok(
                        Box::pin(stream)
                            as Pin<
                                Box<
                                    dyn Stream<Item = Result<StreamEvent, ProviderError>>
                                        + Send,
                                >,
                            >,
                    )
                }
            })
        })
    }

    fn non_retryable_factory() -> StreamFactory {
        Box::new(|| {
            Box::pin(async {
                Err(ProviderError::Auth {
                    message: "Invalid API key".to_string(),
                })
            })
        })
    }

    fn quick_retry_config() -> StreamRetryConfig {
        StreamRetryConfig {
            retry: RetryConfig {
                max_retries: 3,
                base_delay_ms: 1, // 1ms for tests
                max_delay_ms: 10,
                jitter_factor: 0.0,
            },
            emit_retry_events: true,
            cancel_token: None,
        }
    }

    #[tokio::test]
    async fn retry_success_no_retries() {
        let stream = with_provider_retry(success_factory(), quick_retry_config());
        let events: Vec<_> = stream.collect().await;

        assert_eq!(events.len(), 2);
        assert!(matches!(events[0], Ok(StreamEvent::Start)));
        assert!(matches!(events[1], Ok(StreamEvent::Done { .. })));
    }

    #[tokio::test]
    async fn retry_succeeds_after_failures() {
        let counter = Arc::new(AtomicU32::new(0));
        let factory = failing_factory(2, counter.clone());
        let stream = with_provider_retry(factory, quick_retry_config());
        let events: Vec<_> = stream.collect().await;

        // 2 retry events + Start + Done
        let retry_events: Vec<_> = events
            .iter()
            .filter(|e| matches!(e, Ok(StreamEvent::Retry { .. })))
            .collect();
        assert_eq!(retry_events.len(), 2);

        let done_events: Vec<_> = events
            .iter()
            .filter(|e| matches!(e, Ok(StreamEvent::Done { .. })))
            .collect();
        assert_eq!(done_events.len(), 1);

        assert_eq!(counter.load(Ordering::SeqCst), 3); // 2 failures + 1 success
    }

    #[tokio::test]
    async fn retry_exhausted() {
        let counter = Arc::new(AtomicU32::new(0));
        let factory = failing_factory(10, counter.clone()); // Always fails
        let config = StreamRetryConfig {
            retry: RetryConfig {
                max_retries: 2,
                base_delay_ms: 1,
                max_delay_ms: 10,
                jitter_factor: 0.0,
            },
            emit_retry_events: true,
            cancel_token: None,
        };

        let stream = with_provider_retry(factory, config);
        let events: Vec<_> = stream.collect().await;

        // 2 retry events + 1 final error
        let retry_count = events
            .iter()
            .filter(|e| matches!(e, Ok(StreamEvent::Retry { .. })))
            .count();
        assert_eq!(retry_count, 2);

        let last = events.last().unwrap();
        assert!(last.is_err());
    }

    #[tokio::test]
    async fn retry_non_retryable_error() {
        let stream = with_provider_retry(non_retryable_factory(), quick_retry_config());
        let events: Vec<_> = stream.collect().await;

        // Should fail immediately, no retry events
        assert_eq!(events.len(), 1);
        assert!(events[0].is_err());
    }

    #[tokio::test]
    async fn retry_no_events_when_disabled() {
        let counter = Arc::new(AtomicU32::new(0));
        let factory = failing_factory(1, counter);
        let config = StreamRetryConfig {
            retry: RetryConfig {
                max_retries: 3,
                base_delay_ms: 1,
                max_delay_ms: 10,
                jitter_factor: 0.0,
            },
            emit_retry_events: false,
            cancel_token: None,
        };

        let stream = with_provider_retry(factory, config);
        let events: Vec<_> = stream.collect().await;

        let retry_count = events
            .iter()
            .filter(|e| matches!(e, Ok(StreamEvent::Retry { .. })))
            .count();
        assert_eq!(retry_count, 0);
    }

    #[tokio::test]
    async fn retry_cancellation() {
        let token = CancellationToken::new();
        let cancel_token = token.clone();

        let counter = Arc::new(AtomicU32::new(0));
        let factory = failing_factory(10, counter);
        let config = StreamRetryConfig {
            retry: RetryConfig {
                max_retries: 5,
                base_delay_ms: 100,
                max_delay_ms: 1000,
                jitter_factor: 0.0,
            },
            emit_retry_events: true,
            cancel_token: Some(token),
        };

        // Cancel after first retry event
        let stream = with_provider_retry(factory, config);
        tokio::pin!(stream);

        // Get first retry event
        let first = stream.next().await;
        assert!(matches!(first, Some(Ok(StreamEvent::Retry { .. }))));

        // Cancel
        cancel_token.cancel();

        // Next should be cancelled
        let remaining: Vec<_> = stream.collect().await;
        let has_cancel = remaining.iter().any(|e| {
            matches!(e, Err(ProviderError::Cancelled))
        });
        assert!(has_cancel);
    }

    #[tokio::test]
    async fn retry_event_contains_attempt_info() {
        let counter = Arc::new(AtomicU32::new(0));
        let factory = failing_factory(1, counter);
        let stream = with_provider_retry(factory, quick_retry_config());
        let events: Vec<_> = stream.collect().await;

        let retry_event = events.iter().find(|e| matches!(e, Ok(StreamEvent::Retry { .. })));
        if let Some(Ok(StreamEvent::Retry {
            attempt,
            max_retries,
            error,
            ..
        })) = retry_event
        {
            assert_eq!(*attempt, 1);
            assert_eq!(*max_retries, 3);
            assert!(error.is_retryable);
            assert_eq!(error.category, "api");
        } else {
            panic!("Expected retry event");
        }
    }

    #[tokio::test]
    async fn retry_respects_retry_after_ms() {
        // Factory that fails once with RateLimited (retry_after_ms = 50ms)
        let counter = Arc::new(AtomicU32::new(0));
        let counter_clone = counter.clone();
        let factory: StreamFactory = Box::new(move || {
            let counter = counter_clone.clone();
            Box::pin(async move {
                let current = counter.fetch_add(1, Ordering::SeqCst);
                if current == 0 {
                    Err(ProviderError::RateLimited {
                        retry_after_ms: 50,
                        message: "Rate limited".into(),
                    })
                } else {
                    let stream = futures::stream::iter(vec![
                        Ok(StreamEvent::Start),
                        Ok(StreamEvent::Done {
                            message: AssistantMessage {
                                content: vec![],
                                token_usage: None,
                            },
                            stop_reason: "end_turn".to_string(),
                        }),
                    ]);
                    Ok(
                        Box::pin(stream)
                            as Pin<
                                Box<
                                    dyn Stream<Item = Result<StreamEvent, ProviderError>>
                                        + Send,
                                >,
                            >,
                    )
                }
            })
        });

        let config = StreamRetryConfig {
            retry: RetryConfig {
                max_retries: 3,
                base_delay_ms: 1, // 1ms base — retry_after_ms (50) should dominate
                max_delay_ms: 100,
                jitter_factor: 0.0,
            },
            emit_retry_events: true,
            cancel_token: None,
        };

        let start = tokio::time::Instant::now();
        let stream = with_provider_retry(factory, config);
        let events: Vec<_> = stream.collect().await;
        let elapsed = start.elapsed();

        // Should have retried once, then succeeded
        assert_eq!(counter.load(Ordering::SeqCst), 2);
        // Delay should be at least 50ms (from retry_after_ms)
        assert!(elapsed.as_millis() >= 50, "expected >=50ms, got {}ms", elapsed.as_millis());

        // Verify retry event has rate_limit category
        let retry_event = events.iter().find(|e| matches!(e, Ok(StreamEvent::Retry { .. })));
        if let Some(Ok(StreamEvent::Retry { delay_ms, error, .. })) = retry_event {
            assert!(*delay_ms >= 50);
            assert_eq!(error.category, "rate_limit");
        } else {
            panic!("Expected retry event");
        }

        // Should have Start + Done
        let done_count = events.iter().filter(|e| matches!(e, Ok(StreamEvent::Done { .. }))).count();
        assert_eq!(done_count, 1);
    }
}
