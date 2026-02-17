//! # SSE Parser
//!
//! Shared Server-Sent Events parser for LLM provider streams.
//!
//! All three providers (Anthropic, `OpenAI`, Google) use HTTP SSE for streaming
//! responses. This module provides a generic parser that handles:
//! - Line buffering from chunked responses
//! - `data: ` prefix extraction
//! - `[DONE]` marker filtering
//! - Remaining buffer processing (configurable per provider)

use bytes::{Bytes, BytesMut};
use futures::Stream;
use tokio_stream::StreamExt;
use tracing::warn;

/// Options for the SSE parser.
#[derive(Clone, Debug)]
pub struct SseParserOptions {
    /// Whether to process remaining buffer content after the stream ends.
    /// Default: `true` (Google needs this; `OpenAI` uses explicit `[DONE]`).
    pub process_remaining_buffer: bool,
}

impl Default for SseParserOptions {
    fn default() -> Self {
        Self {
            process_remaining_buffer: true,
        }
    }
}

/// Parse SSE lines from a byte stream and yield JSON data strings.
///
/// This is an async generator (implemented as a stream) that:
/// 1. Buffers incoming bytes
/// 2. Splits on newlines
/// 3. Extracts the `data: ` payload from SSE lines
/// 4. Skips `[DONE]` markers and empty data
/// 5. Returns raw JSON strings for provider-specific parsing
pub fn parse_sse_lines<S>(
    byte_stream: S,
    options: &SseParserOptions,
) -> impl Stream<Item = String> + Send + '_
where
    S: Stream<Item = Result<Bytes, reqwest::Error>> + Send + Unpin + 'static,
{
    let process_remaining = options.process_remaining_buffer;

    futures::stream::unfold(
        (byte_stream, BytesMut::with_capacity(8192), false),
        move |(mut stream, mut buffer, done)| async move {
            if done {
                return None;
            }

            loop {
                // Check buffer for a complete line (\n)
                if let Some(newline_pos) = buffer.iter().position(|&b| b == b'\n') {
                    // Split the line bytes out of the buffer (zero-copy split)
                    let mut line_bytes = buffer.split_to(newline_pos + 1);
                    // Remove trailing \n
                    line_bytes.truncate(line_bytes.len() - 1);
                    // Remove trailing \r if present
                    if line_bytes.last() == Some(&b'\r') {
                        line_bytes.truncate(line_bytes.len() - 1);
                    }

                    // Convert to &str only for the final line
                    let line = match std::str::from_utf8(&line_bytes) {
                        Ok(s) => s,
                        Err(_) => continue, // skip invalid UTF-8 lines
                    };

                    if let Some(data) = extract_sse_data(line) {
                        return Some((data, (stream, buffer, false)));
                    }
                    continue;
                }

                // Read next chunk — append raw bytes, no conversion
                match stream.next().await {
                    Some(Ok(chunk)) => {
                        buffer.extend_from_slice(&chunk);
                    }
                    Some(Err(e)) => {
                        warn!("SSE stream read error: {e}");
                        return None;
                    }
                    None => {
                        // Stream ended — process remaining buffer if configured
                        if process_remaining && !buffer.is_empty() {
                            let line = match std::str::from_utf8(&buffer) {
                                Ok(s) => s.trim(),
                                Err(_) => return None,
                            };
                            if let Some(data) = extract_sse_data(line) {
                                buffer.clear();
                                return Some((data, (stream, buffer, true)));
                            }
                        }
                        return None;
                    }
                }
            }
        },
    )
}

/// Extract data payload from an SSE line.
///
/// Returns `Some(data)` for valid data lines, `None` for comments,
/// empty lines, and `[DONE]` markers.
fn extract_sse_data(line: &str) -> Option<String> {
    let trimmed = line.trim();

    // Skip empty lines and comments
    if trimmed.is_empty() || trimmed.starts_with(':') {
        return None;
    }

    // Extract "data: " payload
    let data = trimmed.strip_prefix("data: ").or_else(|| trimmed.strip_prefix("data:"))?;

    let data = data.trim();

    // Skip [DONE] marker
    if data == "[DONE]" {
        return None;
    }

    // Skip empty data
    if data.is_empty() {
        return None;
    }

    Some(data.to_string())
}

/// Safely parse JSON from an SSE data string.
///
/// Returns `None` on parse failure with a warning log.
pub fn parse_sse_data<T: serde::de::DeserializeOwned>(data: &str, provider: &str) -> Option<T> {
    match serde_json::from_str(data) {
        Ok(parsed) => Some(parsed),
        Err(e) => {
            warn!(
                provider = provider,
                error = %e,
                data_preview = tron_core::text::truncate_str(data, 100),
                "Failed to parse SSE data"
            );
            None
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    // ── extract_sse_data ─────────────────────────────────────────────────

    #[test]
    fn extract_data_line() {
        assert_eq!(
            extract_sse_data("data: {\"type\":\"message\"}"),
            Some("{\"type\":\"message\"}".into())
        );
    }

    #[test]
    fn extract_data_line_no_space() {
        assert_eq!(
            extract_sse_data("data:{\"type\":\"message\"}"),
            Some("{\"type\":\"message\"}".into())
        );
    }

    #[test]
    fn extract_skips_done_marker() {
        assert_eq!(extract_sse_data("data: [DONE]"), None);
    }

    #[test]
    fn extract_skips_empty_data() {
        assert_eq!(extract_sse_data("data: "), None);
        assert_eq!(extract_sse_data("data:"), None);
    }

    #[test]
    fn extract_skips_empty_line() {
        assert_eq!(extract_sse_data(""), None);
        assert_eq!(extract_sse_data("   "), None);
    }

    #[test]
    fn extract_skips_comment() {
        assert_eq!(extract_sse_data(": this is a comment"), None);
    }

    #[test]
    fn extract_skips_non_data_field() {
        assert_eq!(extract_sse_data("event: message"), None);
        assert_eq!(extract_sse_data("id: 123"), None);
    }

    #[test]
    fn extract_preserves_json_with_spaces() {
        let data = extract_sse_data("data: { \"key\": \"value\" }");
        assert_eq!(data, Some("{ \"key\": \"value\" }".into()));
    }

    // ── parse_sse_data ───────────────────────────────────────────────────

    #[test]
    fn parse_valid_json() {
        let result: Option<serde_json::Value> =
            parse_sse_data("{\"type\":\"text\"}", "test");
        assert!(result.is_some());
        assert_eq!(result.unwrap()["type"], "text");
    }

    #[test]
    fn parse_invalid_json_returns_none() {
        let result: Option<serde_json::Value> =
            parse_sse_data("not json at all", "test");
        assert!(result.is_none());
    }

    // ── parse_sse_lines (integration) ────────────────────────────────────

    #[tokio::test]
    async fn parse_lines_single_chunk_single_event() {
        let chunks = vec![Ok(Bytes::from("data: {\"type\":\"hello\"}\n\n"))];
        let stream = futures::stream::iter(chunks);
        let options = SseParserOptions::default();

        let results: Vec<String> = parse_sse_lines(stream, &options).collect().await;
        assert_eq!(results.len(), 1);
        assert_eq!(results[0], "{\"type\":\"hello\"}");
    }

    #[tokio::test]
    async fn parse_lines_multiple_events_in_one_chunk() {
        let chunks = vec![Ok(Bytes::from(
            "data: {\"a\":1}\n\ndata: {\"b\":2}\n\n",
        ))];
        let stream = futures::stream::iter(chunks);
        let options = SseParserOptions::default();

        let results: Vec<String> = parse_sse_lines(stream, &options).collect().await;
        assert_eq!(results.len(), 2);
        assert_eq!(results[0], "{\"a\":1}");
        assert_eq!(results[1], "{\"b\":2}");
    }

    #[tokio::test]
    async fn parse_lines_split_across_chunks() {
        let chunks = vec![
            Ok(Bytes::from("data: {\"par")),
            Ok(Bytes::from("tial\":true}\n\n")),
        ];
        let stream = futures::stream::iter(chunks);
        let options = SseParserOptions::default();

        let results: Vec<String> = parse_sse_lines(stream, &options).collect().await;
        assert_eq!(results.len(), 1);
        assert_eq!(results[0], "{\"partial\":true}");
    }

    #[tokio::test]
    async fn parse_lines_filters_done_marker() {
        let chunks = vec![Ok(Bytes::from(
            "data: {\"ok\":true}\n\ndata: [DONE]\n\n",
        ))];
        let stream = futures::stream::iter(chunks);
        let options = SseParserOptions::default();

        let results: Vec<String> = parse_sse_lines(stream, &options).collect().await;
        assert_eq!(results.len(), 1);
        assert_eq!(results[0], "{\"ok\":true}");
    }

    #[tokio::test]
    async fn parse_lines_skips_comments_and_empty() {
        let chunks = vec![Ok(Bytes::from(
            ": comment\n\ndata: {\"v\":1}\n\nevent: ping\n\n",
        ))];
        let stream = futures::stream::iter(chunks);
        let options = SseParserOptions::default();

        let results: Vec<String> = parse_sse_lines(stream, &options).collect().await;
        assert_eq!(results.len(), 1);
        assert_eq!(results[0], "{\"v\":1}");
    }

    #[tokio::test]
    async fn parse_lines_remaining_buffer_enabled() {
        let chunks = vec![Ok(Bytes::from("data: {\"trailing\":true}"))];
        let stream = futures::stream::iter(chunks);
        let options = SseParserOptions {
            process_remaining_buffer: true,
        };

        let results: Vec<String> = parse_sse_lines(stream, &options).collect().await;
        assert_eq!(results.len(), 1);
        assert_eq!(results[0], "{\"trailing\":true}");
    }

    #[tokio::test]
    async fn parse_lines_remaining_buffer_disabled() {
        let chunks = vec![Ok(Bytes::from("data: {\"trailing\":true}"))];
        let stream = futures::stream::iter(chunks);
        let options = SseParserOptions {
            process_remaining_buffer: false,
        };

        let results: Vec<String> = parse_sse_lines(stream, &options).collect().await;
        assert_eq!(results.len(), 0);
    }

    #[tokio::test]
    async fn parse_lines_empty_stream() {
        let chunks: Vec<Result<Bytes, reqwest::Error>> = vec![];
        let stream = futures::stream::iter(chunks);
        let options = SseParserOptions::default();

        let results: Vec<String> = parse_sse_lines(stream, &options).collect().await;
        assert!(results.is_empty());
    }

    #[tokio::test]
    async fn parse_lines_handles_carriage_returns() {
        let chunks = vec![Ok(Bytes::from("data: {\"cr\":true}\r\n\r\n"))];
        let stream = futures::stream::iter(chunks);
        let options = SseParserOptions::default();

        let results: Vec<String> = parse_sse_lines(stream, &options).collect().await;
        assert_eq!(results.len(), 1);
        assert_eq!(results[0], "{\"cr\":true}");
    }

    // ── SseParserOptions ─────────────────────────────────────────────────

    #[test]
    fn default_options() {
        let opts = SseParserOptions::default();
        assert!(opts.process_remaining_buffer);
    }
}
