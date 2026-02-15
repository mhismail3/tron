use std::pin::Pin;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::Duration;

use async_trait::async_trait;
use futures::stream;
use futures::Stream;

use tron_core::context::LlmContext;
use tron_core::errors::GatewayError;
use tron_core::messages::{AssistantMessage, StopReason};
use tron_core::provider::{LlmProvider, StreamOptions};
use tron_core::stream::StreamEvent;

/// Pre-programmed responses for deterministic testing without API calls.
pub enum MockResponse {
    /// Yield a sequence of StreamEvents.
    Stream(Vec<StreamEvent>),
    /// Return an error from the stream() call itself.
    Error(GatewayError),
    /// Wait a duration, then yield the inner response.
    Delay(Duration, Box<MockResponse>),
}

impl MockResponse {
    /// Convenience: create a simple text response stream.
    pub fn stream_text(text: &str) -> Self {
        let text = text.to_string();
        Self::Stream(vec![
            StreamEvent::Start,
            StreamEvent::TextStart,
            StreamEvent::TextDelta {
                delta: text.clone(),
            },
            StreamEvent::TextEnd {
                text: text.clone(),
                signature: None,
            },
            StreamEvent::Done {
                message: AssistantMessage::text(&text),
                stop_reason: StopReason::EndTurn,
            },
        ])
    }

    /// Convenience: create a stream that ends with an error event.
    pub fn stream_error(error: GatewayError) -> Self {
        Self::Stream(vec![
            StreamEvent::Start,
            StreamEvent::Error { error },
        ])
    }

    /// Convenience: wrap any response with a delay.
    pub fn delayed(delay: Duration, inner: MockResponse) -> Self {
        Self::Delay(delay, Box::new(inner))
    }
}

/// Mock provider that returns pre-programmed responses in sequence.
pub struct MockProvider {
    responses: Vec<MockResponse>,
    call_count: AtomicUsize,
}

impl MockProvider {
    pub fn new(responses: Vec<MockResponse>) -> Self {
        Self {
            responses,
            call_count: AtomicUsize::new(0),
        }
    }

    pub fn call_count(&self) -> usize {
        self.call_count.load(Ordering::Relaxed)
    }
}

#[async_trait]
impl LlmProvider for MockProvider {
    fn name(&self) -> &str {
        "mock"
    }

    fn model(&self) -> &str {
        "mock-model"
    }

    fn context_window(&self) -> usize {
        200_000
    }

    fn supports_thinking(&self) -> bool {
        true
    }

    fn supports_tools(&self) -> bool {
        true
    }

    async fn stream(
        &self,
        _context: &LlmContext,
        _options: &StreamOptions,
    ) -> Result<Pin<Box<dyn Stream<Item = StreamEvent> + Send>>, GatewayError> {
        let idx = self.call_count.fetch_add(1, Ordering::Relaxed);

        if idx >= self.responses.len() {
            return Err(GatewayError::InvalidRequest(format!(
                "MockProvider: no response configured for call {}",
                idx
            )));
        }

        // SAFETY: We only access each index once due to atomic fetch_add.
        // The Vec is not mutated, we just need a shared reference.
        let response = unsafe {
            let ptr = self.responses.as_ptr().add(idx);
            &*ptr
        };

        resolve_response(response).await
    }
}

/// Resolve a MockResponse, handling Delay by sleeping first.
/// Unrolls nested delays iteratively to avoid recursive async.
async fn resolve_response(
    response: &MockResponse,
) -> Result<Pin<Box<dyn Stream<Item = StreamEvent> + Send>>, GatewayError> {
    let mut current = response;
    loop {
        match current {
            MockResponse::Stream(events) => {
                let events = events.clone();
                return Ok(Box::pin(stream::iter(events)));
            }
            MockResponse::Error(e) => return Err(e.clone()),
            MockResponse::Delay(duration, inner) => {
                tokio::time::sleep(*duration).await;
                current = inner;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio_stream::StreamExt;

    #[tokio::test]
    async fn text_response() {
        let mock = MockProvider::new(vec![MockResponse::stream_text("hello world")]);
        let context = LlmContext::empty();
        let mut stream = mock
            .stream(&context, &StreamOptions::default())
            .await
            .unwrap();

        let mut events = Vec::new();
        while let Some(event) = stream.next().await {
            events.push(event);
        }

        assert_eq!(events.len(), 5); // Start, TextStart, TextDelta, TextEnd, Done
        assert!(matches!(events[0], StreamEvent::Start));
        assert!(matches!(events[1], StreamEvent::TextStart));
        if let StreamEvent::TextDelta { delta } = &events[2] {
            assert_eq!(delta, "hello world");
        } else {
            panic!("expected TextDelta");
        }
        assert!(matches!(events[4], StreamEvent::Done { .. }));
    }

    #[tokio::test]
    async fn error_response() {
        let mock = MockProvider::new(vec![MockResponse::Error(
            GatewayError::AuthenticationFailed("bad".into()),
        )]);
        let context = LlmContext::empty();
        let result = mock.stream(&context, &StreamOptions::default()).await;
        assert!(result.is_err());
    }

    #[tokio::test]
    async fn sequential_responses() {
        let mock = MockProvider::new(vec![
            MockResponse::stream_text("first"),
            MockResponse::stream_text("second"),
        ]);
        let context = LlmContext::empty();

        // First call
        let result1 = mock.stream(&context, &StreamOptions::default()).await;
        assert!(result1.is_ok());
        assert_eq!(mock.call_count(), 1);

        // Second call
        let result2 = mock.stream(&context, &StreamOptions::default()).await;
        assert!(result2.is_ok());
        assert_eq!(mock.call_count(), 2);
    }

    #[tokio::test]
    async fn exhausted_responses() {
        let mock = MockProvider::new(vec![MockResponse::stream_text("only one")]);
        let context = LlmContext::empty();

        let _ = mock.stream(&context, &StreamOptions::default()).await;
        let result = mock.stream(&context, &StreamOptions::default()).await;
        assert!(result.is_err());
    }

    #[test]
    fn provider_properties() {
        let mock = MockProvider::new(vec![]);
        assert_eq!(mock.name(), "mock");
        assert_eq!(mock.model(), "mock-model");
        assert_eq!(mock.context_window(), 200_000);
        assert!(mock.supports_thinking());
        assert!(mock.supports_tools());
    }

    #[tokio::test]
    async fn delayed_response() {
        let mock = MockProvider::new(vec![MockResponse::delayed(
            Duration::from_millis(50),
            MockResponse::stream_text("after delay"),
        )]);
        let context = LlmContext::empty();

        let start = std::time::Instant::now();
        let mut stream = mock
            .stream(&context, &StreamOptions::default())
            .await
            .unwrap();

        let elapsed = start.elapsed();
        assert!(
            elapsed >= Duration::from_millis(40),
            "Delay should have waited ~50ms, got {:?}",
            elapsed
        );

        let mut events = Vec::new();
        while let Some(event) = stream.next().await {
            events.push(event);
        }
        assert_eq!(events.len(), 5);
    }

    #[tokio::test]
    async fn delayed_error() {
        let mock = MockProvider::new(vec![MockResponse::delayed(
            Duration::from_millis(20),
            MockResponse::Error(GatewayError::RateLimited { retry_after: None }),
        )]);
        let context = LlmContext::empty();

        let result = mock.stream(&context, &StreamOptions::default()).await;
        match result {
            Err(GatewayError::RateLimited { .. }) => {} // expected
            Err(other) => panic!("expected RateLimited, got: {other:?}"),
            Ok(_) => panic!("expected error"),
        }
    }
}
