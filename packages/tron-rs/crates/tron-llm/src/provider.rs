use std::pin::Pin;
use std::sync::Arc;
use std::time::{Duration, Instant};

use async_trait::async_trait;
use futures::{Future, Stream};
use reqwest::Client;
use secrecy::ExposeSecret;
use tokio::sync::RwLock;
use tracing::instrument;

use tron_core::context::LlmContext;
use tron_core::errors::GatewayError;
use tron_core::provider::{LlmProvider, StreamOptions};
use tron_core::security::AuthMethod;
use tron_core::stream::StreamEvent;

use crate::auth;
use crate::converter;
use crate::models::{self, ClaudeModelInfo};
use crate::sse::{self, SseParser};

const API_URL: &str = "https://api.anthropic.com/v1/messages";
const CONNECT_TIMEOUT: Duration = Duration::from_secs(30);
const SSE_IDLE_TIMEOUT: Duration = Duration::from_secs(90);

pub struct AnthropicProvider {
    client: Client,
    auth: Arc<RwLock<AuthMethod>>,
    model_info: &'static ClaudeModelInfo,
    last_api_call: Arc<RwLock<Option<Instant>>>,
}

impl AnthropicProvider {
    pub fn new(auth: AuthMethod, model_name: Option<&str>) -> Self {
        let model_info = model_name
            .and_then(models::find_model)
            .unwrap_or_else(models::default_model);

        Self {
            client: Client::builder()
                .connect_timeout(CONNECT_TIMEOUT)
                .build()
                .expect("failed to build HTTP client"),
            auth: Arc::new(RwLock::new(auth)),
            model_info,
            last_api_call: Arc::new(RwLock::new(None)),
        }
    }

    fn is_oauth(&self, auth: &AuthMethod) -> bool {
        matches!(auth, AuthMethod::OAuth(_))
    }

    async fn build_request(
        &self,
        context: &LlmContext,
        options: &StreamOptions,
    ) -> Result<reqwest::RequestBuilder, GatewayError> {
        let auth = self.auth.read().await;
        let is_oauth = self.is_oauth(&auth);

        let body = converter::build_request_body(context, options, self.model_info.name, is_oauth);

        let mut req = self.client.post(API_URL);

        match &*auth {
            AuthMethod::OAuth(tokens) => {
                req = req.header(
                    "Authorization",
                    format!("Bearer {}", tokens.access_token.expose_secret()),
                );
                req = req.header(
                    "anthropic-beta",
                    auth::oauth_beta_headers(self.model_info.requires_thinking_beta_headers),
                );
                req = req.header("anthropic-dangerous-direct-browser-access", "true");
            }
            AuthMethod::ApiKey(key) => {
                req = req.header("x-api-key", key.0.expose_secret());
                req = req.header("anthropic-version", "2023-06-01");
            }
        }

        req = req.header("accept", "application/json");
        req = req.header("content-type", "application/json");
        req = req.json(&body);

        Ok(req)
    }

    /// Check if we're in a cache-cold state (>5min since last API call).
    pub async fn is_cache_cold(&self) -> bool {
        let last = self.last_api_call.read().await;
        match *last {
            Some(instant) => instant.elapsed().as_secs() > 300,
            None => true,
        }
    }

    /// Get the current auth method.
    pub async fn auth_method(&self) -> AuthMethod {
        self.auth.read().await.clone()
    }

    /// Refresh OAuth tokens if needed.
    pub async fn ensure_fresh_tokens(&self) -> Result<(), GatewayError> {
        let auth = self.auth.read().await;
        if let AuthMethod::OAuth(tokens) = &*auth {
            if auth::needs_refresh(tokens) {
                drop(auth);
                let mut auth = self.auth.write().await;
                // Double-check after acquiring write lock
                if let AuthMethod::OAuth(tokens) = &*auth {
                    if auth::needs_refresh(tokens) {
                        let new_tokens = auth::refresh_token(&tokens.refresh_token)
                            .await
                            .map_err(|e| GatewayError::AuthenticationFailed(e.to_string()))?;
                        *auth = AuthMethod::OAuth(new_tokens);
                    }
                }
            }
        }
        Ok(())
    }
}

#[async_trait]
impl LlmProvider for AnthropicProvider {
    fn name(&self) -> &str {
        "anthropic"
    }

    fn model(&self) -> &str {
        self.model_info.name
    }

    fn context_window(&self) -> usize {
        self.model_info.context_window
    }

    fn supports_thinking(&self) -> bool {
        self.model_info.supports_thinking
    }

    fn supports_tools(&self) -> bool {
        true
    }

    #[instrument(skip(self, context, options), fields(model = %self.model_info.name))]
    async fn stream(
        &self,
        context: &LlmContext,
        options: &StreamOptions,
    ) -> Result<Pin<Box<dyn Stream<Item = StreamEvent> + Send>>, GatewayError> {
        self.ensure_fresh_tokens().await?;

        let req = self.build_request(context, options).await?;

        let resp = req
            .send()
            .await
            .map_err(|e| GatewayError::NetworkError(e.to_string()))?;

        // Update last API call time
        *self.last_api_call.write().await = Some(Instant::now());

        if !resp.status().is_success() {
            let status = resp.status().as_u16();
            let body = resp.text().await.unwrap_or_default();
            return Err(GatewayError::from_status(status, body));
        }

        let byte_stream = resp.bytes_stream();
        let stream = SseStream::new(byte_stream);

        Ok(Box::pin(stream))
    }
}

/// Wraps a byte stream from reqwest and yields StreamEvents.
/// Includes an idle timeout — if no data arrives within `idle_duration`, emits an error.
struct SseStream {
    inner: Pin<Box<dyn Stream<Item = Result<bytes::Bytes, reqwest::Error>> + Send>>,
    parser: SseParser,
    buffer: String,
    pending: Vec<StreamEvent>,
    idle_deadline: Pin<Box<tokio::time::Sleep>>,
    idle_duration: Duration,
}

impl SseStream {
    fn new(
        byte_stream: impl Stream<Item = Result<bytes::Bytes, reqwest::Error>>
            + Send
            + 'static,
    ) -> Self {
        Self::with_idle_timeout(byte_stream, SSE_IDLE_TIMEOUT)
    }

    fn with_idle_timeout(
        byte_stream: impl Stream<Item = Result<bytes::Bytes, reqwest::Error>>
            + Send
            + 'static,
        idle_timeout: Duration,
    ) -> Self {
        Self {
            inner: Box::pin(byte_stream),
            parser: SseParser::new(),
            buffer: String::new(),
            pending: Vec::new(),
            idle_deadline: Box::pin(tokio::time::sleep(idle_timeout)),
            idle_duration: idle_timeout,
        }
    }
}

impl Stream for SseStream {
    type Item = StreamEvent;

    fn poll_next(
        mut self: Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
    ) -> std::task::Poll<Option<Self::Item>> {
        // Return pending events first
        if !self.pending.is_empty() {
            return std::task::Poll::Ready(Some(self.pending.remove(0)));
        }

        loop {
            match self.inner.as_mut().poll_next(cx) {
                std::task::Poll::Ready(Some(Ok(bytes))) => {
                    // Data received — reset idle timer
                    let new_deadline = tokio::time::Instant::now() + self.idle_duration;
                    self.idle_deadline.as_mut().reset(new_deadline);

                    let text = String::from_utf8_lossy(&bytes);
                    self.buffer.push_str(&text);

                    // Process complete SSE events from the buffer
                    while let Some(pos) = self.buffer.find("\n\n") {
                        let chunk = self.buffer[..pos + 2].to_string();
                        self.buffer = self.buffer[pos + 2..].to_string();

                        let sse_events = sse::parse_sse_lines(&chunk);
                        for (event_type, data) in sse_events {
                            let stream_events = self.parser.parse_event(&event_type, &data);
                            self.pending.extend(stream_events);
                        }
                    }

                    if !self.pending.is_empty() {
                        return std::task::Poll::Ready(Some(self.pending.remove(0)));
                    }
                }
                std::task::Poll::Ready(Some(Err(e))) => {
                    return std::task::Poll::Ready(Some(StreamEvent::Error {
                        error: GatewayError::StreamInterrupted(e.to_string()),
                    }));
                }
                std::task::Poll::Ready(None) => {
                    // Stream ended — process remaining buffer
                    if !self.buffer.is_empty() {
                        let remaining = std::mem::take(&mut self.buffer);
                        let sse_events = sse::parse_sse_lines(&remaining);
                        for (event_type, data) in sse_events {
                            let stream_events = self.parser.parse_event(&event_type, &data);
                            self.pending.extend(stream_events);
                        }
                        if !self.pending.is_empty() {
                            return std::task::Poll::Ready(Some(self.pending.remove(0)));
                        }
                    }
                    return std::task::Poll::Ready(None);
                }
                std::task::Poll::Pending => {
                    // No data available — check idle timeout
                    if self.idle_deadline.as_mut().poll(cx).is_ready() {
                        return std::task::Poll::Ready(Some(StreamEvent::Error {
                            error: GatewayError::StreamInterrupted(format!(
                                "idle timeout after {}s",
                                self.idle_duration.as_secs()
                            )),
                        }));
                    }
                    return std::task::Poll::Pending;
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use futures::StreamExt;
    use secrecy::SecretString;
    use tron_core::security::ApiKey;

    #[test]
    fn provider_properties() {
        let auth = AuthMethod::ApiKey(ApiKey(SecretString::from("test-key")));
        let provider = AnthropicProvider::new(auth, Some("claude-opus-4-6"));
        assert_eq!(provider.name(), "anthropic");
        assert_eq!(provider.model(), "claude-opus-4-6");
        assert_eq!(provider.context_window(), 200_000);
        assert!(provider.supports_thinking());
        assert!(provider.supports_tools());
    }

    #[test]
    fn default_model_used_when_none() {
        let auth = AuthMethod::ApiKey(ApiKey(SecretString::from("test-key")));
        let provider = AnthropicProvider::new(auth, None);
        assert_eq!(provider.model(), "claude-sonnet-4-5-20250929");
    }

    #[tokio::test]
    async fn cache_cold_initially() {
        let auth = AuthMethod::ApiKey(ApiKey(SecretString::from("test-key")));
        let provider = AnthropicProvider::new(auth, None);
        assert!(provider.is_cache_cold().await);
    }

    #[tokio::test]
    async fn sse_stream_idle_timeout_fires_when_no_data() {
        tokio::time::pause();

        let byte_stream = futures::stream::pending::<Result<bytes::Bytes, reqwest::Error>>();
        let mut stream = Box::pin(SseStream::with_idle_timeout(
            byte_stream,
            Duration::from_secs(5),
        ));

        // Advance time past the idle timeout
        tokio::time::advance(Duration::from_secs(6)).await;

        let event = stream.next().await;
        assert!(
            matches!(&event, Some(StreamEvent::Error { error: GatewayError::StreamInterrupted(msg) }) if msg.contains("idle timeout")),
            "expected idle timeout error, got: {event:?}"
        );
    }

    #[tokio::test]
    async fn sse_stream_idle_timeout_resets_on_data() {
        tokio::time::pause();

        // Create a channel-based stream so we can control when data arrives
        let (tx, rx) = tokio::sync::mpsc::channel::<Result<bytes::Bytes, reqwest::Error>>(16);
        let rx_stream = tokio_stream::wrappers::ReceiverStream::new(rx);
        let mut stream = Box::pin(SseStream::with_idle_timeout(
            rx_stream,
            Duration::from_secs(5),
        ));

        // Send some data before the timeout
        tx.send(Ok(bytes::Bytes::from("data: ping\n\n")))
            .await
            .unwrap();

        // Consume the event (resets the idle timer)
        let _event = stream.next().await;

        // Advance 4s (less than the 5s timeout from the reset point)
        tokio::time::advance(Duration::from_secs(4)).await;

        // Send more data — timer resets again
        tx.send(Ok(bytes::Bytes::from("data: pong\n\n")))
            .await
            .unwrap();
        let _event = stream.next().await;

        // Drop sender to end the stream cleanly
        drop(tx);
        let event = stream.next().await;
        // Should be None (stream ended), NOT an idle timeout error
        assert!(event.is_none(), "expected stream end, got: {event:?}");
    }

    #[test]
    fn connect_timeout_constant() {
        assert_eq!(CONNECT_TIMEOUT, Duration::from_secs(30));
    }

    #[test]
    fn idle_timeout_constant() {
        assert_eq!(SSE_IDLE_TIMEOUT, Duration::from_secs(90));
    }
}
