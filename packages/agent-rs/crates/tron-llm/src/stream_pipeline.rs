//! Stream pipeline helpers for LLM provider streaming.
//!
//! Eliminates duplicated SSE→event stream conversion code across providers.
//! All four providers (Anthropic, `OpenAI`, Google, `MiniMax`) use the same
//! pattern: parse SSE lines → deserialize JSON → process through a handler →
//! flatten → box. These helpers encapsulate that boilerplate.

use futures::stream::{self, StreamExt};
use tracing::{error, warn};

use crate::provider::{ProviderResult, StreamEventStream};
use tron_core::events::StreamEvent;
use crate::sse::{SseParserOptions, parse_sse_lines};

/// Convert an HTTP response's SSE byte stream into a typed [`StreamEventStream`].
///
/// Encapsulates the shared pipeline: `bytes_stream()` → `parse_sse_lines()` →
/// `scan(state, deserialize + handler)` → `flat_map` → `map(Ok)` → `Box::pin`.
pub fn sse_to_event_stream<E, S, H>(
    response: reqwest::Response,
    options: &'static SseParserOptions,
    initial_state: S,
    mut handler: H,
) -> StreamEventStream
where
    E: serde::de::DeserializeOwned + Send + 'static,
    S: Send + 'static,
    H: FnMut(&E, &mut S) -> Vec<StreamEvent> + Send + 'static,
{
    let byte_stream = response.bytes_stream();
    let sse_lines = parse_sse_lines(byte_stream, options);

    let event_stream = sse_lines
        .scan(initial_state, move |state, line| {
            let event: E = match serde_json::from_str(&line) {
                Ok(e) => e,
                Err(e) => {
                    warn!(line = %line, error = %e, "Failed to parse SSE event");
                    return std::future::ready(Some(vec![]));
                }
            };
            let events = handler(&event, state);
            std::future::ready(Some(events))
        })
        .flat_map(stream::iter)
        .map(Ok);

    Box::pin(event_stream)
}

/// Wrap a provider's `stream_internal()` result with a [`StreamEvent::Start`] prefix.
///
/// All providers' `stream()` implementations follow the same pattern: log errors,
/// prepend `StreamEvent::Start`, re-box. This eliminates that boilerplate.
pub fn wrap_provider_stream(
    provider_name: &str,
    inner: ProviderResult<StreamEventStream>,
) -> ProviderResult<StreamEventStream> {
    let inner_stream = match inner {
        Ok(s) => s,
        Err(e) => {
            error!(error = %e, provider = %provider_name, "stream failed");
            return Err(e);
        }
    };
    let start_event = stream::once(async { Ok(StreamEvent::Start) });
    Ok(Box::pin(start_event.chain(inner_stream)))
}
