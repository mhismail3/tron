use serde::Deserialize;
use serde_json::Value;

use tron_core::errors::GatewayError;
use tron_core::ids::ToolCallId;
use tron_core::messages::{
    AssistantContent, AssistantMessage, StopReason, ToolCallBlock,
};
use tron_core::stream::StreamEvent;
use tron_core::tokens::TokenUsage;
use tron_core::security::ProviderType;

/// State machine for parsing Anthropic SSE stream events.
pub struct SseParser {
    // Accumulated content blocks
    text_blocks: Vec<TextBlock>,
    thinking_blocks: Vec<ThinkingBlock>,
    tool_blocks: Vec<ToolBlock>,
    // Token tracking
    input_tokens: u32,
    output_tokens: u32,
    cache_read_tokens: u32,
    cache_creation_tokens: u32,
    // Current block tracking
    current_block_idx: Option<usize>,
    current_block_type: Option<String>,
}

struct TextBlock {
    text: String,
}

struct ThinkingBlock {
    text: String,
    signature: Option<String>,
}

struct ToolBlock {
    id: String,
    name: String,
    arguments_json: String,
}

impl Default for SseParser {
    fn default() -> Self {
        Self::new()
    }
}

impl SseParser {
    pub fn new() -> Self {
        Self {
            text_blocks: Vec::new(),
            thinking_blocks: Vec::new(),
            tool_blocks: Vec::new(),
            input_tokens: 0,
            output_tokens: 0,
            cache_read_tokens: 0,
            cache_creation_tokens: 0,
            current_block_idx: None,
            current_block_type: None,
        }
    }

    /// Parse a single SSE event line and return zero or more StreamEvents.
    pub fn parse_event(&mut self, event_type: &str, data: &str) -> Vec<StreamEvent> {
        let mut events = Vec::new();

        match event_type {
            "message_start" => {
                if let Ok(msg) = serde_json::from_str::<MessageStartEvent>(data) {
                    if let Some(usage) = msg.message.usage {
                        self.input_tokens = usage.input_tokens.unwrap_or(0);
                        self.cache_read_tokens = usage.cache_read_input_tokens.unwrap_or(0);
                        self.cache_creation_tokens = usage.cache_creation_input_tokens.unwrap_or(0);
                    }
                }
                events.push(StreamEvent::Start);
            }

            "content_block_start" => {
                if let Ok(block) = serde_json::from_str::<ContentBlockStartEvent>(data) {
                    self.current_block_idx = Some(block.index);
                    match block.content_block.get("type").and_then(|t| t.as_str()) {
                        Some("text") => {
                            self.current_block_type = Some("text".into());
                            self.text_blocks.push(TextBlock {
                                text: String::new(),
                            });
                            events.push(StreamEvent::TextStart);
                        }
                        Some("thinking") => {
                            self.current_block_type = Some("thinking".into());
                            self.thinking_blocks.push(ThinkingBlock {
                                text: String::new(),
                                signature: None,
                            });
                            events.push(StreamEvent::ThinkingStart);
                        }
                        Some("tool_use") => {
                            let id = block.content_block.get("id")
                                .and_then(|v| v.as_str())
                                .unwrap_or("")
                                .to_string();
                            let name = block.content_block.get("name")
                                .and_then(|v| v.as_str())
                                .unwrap_or("")
                                .to_string();
                            self.current_block_type = Some("tool_use".into());
                            self.tool_blocks.push(ToolBlock {
                                id: id.clone(),
                                name: name.clone(),
                                arguments_json: String::new(),
                            });
                            events.push(StreamEvent::ToolCallStart {
                                tool_call_id: ToolCallId::from_raw(&id),
                                name,
                            });
                        }
                        _ => {}
                    }
                }
            }

            "content_block_delta" => {
                if let Ok(delta) = serde_json::from_str::<ContentBlockDeltaEvent>(data) {
                    match delta.delta.get("type").and_then(|t| t.as_str()) {
                        Some("text_delta") => {
                            let text = delta.delta.get("text")
                                .and_then(|t| t.as_str())
                                .unwrap_or("");
                            if let Some(block) = self.text_blocks.last_mut() {
                                block.text.push_str(text);
                            }
                            events.push(StreamEvent::TextDelta { delta: text.to_string() });
                        }
                        Some("thinking_delta") => {
                            let thinking = delta.delta.get("thinking")
                                .and_then(|t| t.as_str())
                                .unwrap_or("");
                            if let Some(block) = self.thinking_blocks.last_mut() {
                                block.text.push_str(thinking);
                            }
                            events.push(StreamEvent::ThinkingDelta { delta: thinking.to_string() });
                        }
                        Some("input_json_delta") => {
                            let partial = delta.delta.get("partial_json")
                                .and_then(|t| t.as_str())
                                .unwrap_or("");
                            if let Some(block) = self.tool_blocks.last_mut() {
                                block.arguments_json.push_str(partial);
                                events.push(StreamEvent::ToolCallDelta {
                                    tool_call_id: ToolCallId::from_raw(&block.id),
                                    arguments_delta: partial.to_string(),
                                });
                            }
                        }
                        Some("signature_delta") => {
                            let sig = delta.delta.get("signature")
                                .and_then(|t| t.as_str())
                                .unwrap_or("");
                            if let Some(block) = self.thinking_blocks.last_mut() {
                                match &mut block.signature {
                                    Some(existing) => existing.push_str(sig),
                                    None => block.signature = Some(sig.to_string()),
                                }
                            }
                        }
                        _ => {}
                    }
                }
            }

            "content_block_stop" => {
                match self.current_block_type.as_deref() {
                    Some("text") => {
                        if let Some(block) = self.text_blocks.last() {
                            events.push(StreamEvent::TextEnd {
                                text: block.text.clone(),
                                signature: None,
                            });
                        }
                    }
                    Some("thinking") => {
                        if let Some(block) = self.thinking_blocks.last() {
                            events.push(StreamEvent::ThinkingEnd {
                                thinking: block.text.clone(),
                                signature: block.signature.clone(),
                            });
                        }
                    }
                    Some("tool_use") => {
                        if let Some(block) = self.tool_blocks.last() {
                            let arguments: Value = serde_json::from_str(&block.arguments_json)
                                .unwrap_or(Value::Object(serde_json::Map::new()));
                            events.push(StreamEvent::ToolCallEnd {
                                tool_call: ToolCallBlock {
                                    id: ToolCallId::from_raw(&block.id),
                                    name: block.name.clone(),
                                    arguments,
                                    thought_signature: None,
                                },
                            });
                        }
                    }
                    _ => {}
                }
                self.current_block_type = None;
                self.current_block_idx = None;
            }

            "message_delta" => {
                if let Ok(delta) = serde_json::from_str::<MessageDeltaEvent>(data) {
                    if let Some(usage) = delta.usage {
                        self.output_tokens = usage.output_tokens.unwrap_or(0);
                    }
                }
            }

            "message_stop" => {
                let message = self.build_assistant_message();
                let stop_reason = self.infer_stop_reason(&message);
                events.push(StreamEvent::Done { message, stop_reason });
            }

            "error" => {
                if let Ok(err) = serde_json::from_str::<ErrorEvent>(data) {
                    let error = classify_error(&err);
                    events.push(StreamEvent::Error { error });
                }
            }

            _ => {} // ping, etc.
        }

        events
    }

    /// Extract accumulated token usage.
    pub fn token_usage(&self) -> TokenUsage {
        TokenUsage {
            input_tokens: self.input_tokens,
            output_tokens: self.output_tokens,
            cache_read_tokens: self.cache_read_tokens,
            cache_creation_tokens: self.cache_creation_tokens,
            cache_creation_5m_tokens: 0,
            cache_creation_1h_tokens: 0,
            provider_type: ProviderType::Anthropic,
        }
    }

    fn build_assistant_message(&self) -> AssistantMessage {
        let mut content = Vec::new();

        // Interleave thinking and text blocks in order
        // For simplicity, thinking comes before text, then tool calls
        for block in &self.thinking_blocks {
            content.push(AssistantContent::Thinking {
                text: block.text.clone(),
                signature: block.signature.clone(),
            });
        }
        for block in &self.text_blocks {
            content.push(AssistantContent::Text { text: block.text.clone() });
        }
        for block in &self.tool_blocks {
            let arguments: Value = serde_json::from_str(&block.arguments_json)
                .unwrap_or(Value::Object(serde_json::Map::new()));
            content.push(AssistantContent::ToolCall(ToolCallBlock {
                id: ToolCallId::from_raw(&block.id),
                name: block.name.clone(),
                arguments,
                thought_signature: None,
            }));
        }

        AssistantMessage {
            content,
            usage: Some(self.token_usage()),
            stop_reason: None,
        }
    }

    fn infer_stop_reason(&self, message: &AssistantMessage) -> StopReason {
        if message.has_tool_calls() {
            StopReason::ToolUse
        } else {
            StopReason::EndTurn
        }
    }
}

fn classify_error(err: &ErrorEvent) -> GatewayError {
    match err.error.error_type.as_str() {
        "overloaded_error" => GatewayError::ProviderOverloaded,
        "rate_limit_error" => GatewayError::RateLimited { retry_after: None },
        "authentication_error" => GatewayError::AuthenticationFailed(err.error.message.clone()),
        "invalid_request_error" => {
            if err.error.message.contains("context window") || err.error.message.contains("too many tokens") {
                GatewayError::ContextWindowExceeded { limit: 200_000, actual: 0 }
            } else {
                GatewayError::InvalidRequest(err.error.message.clone())
            }
        }
        _ => GatewayError::ServerError { status: 500, body: err.error.message.clone() },
    }
}

/// Parse raw SSE text into (event_type, data) pairs.
pub fn parse_sse_lines(raw: &str) -> Vec<(String, String)> {
    let mut events = Vec::new();
    let mut current_event = String::new();
    let mut current_data = String::new();

    for line in raw.lines() {
        if let Some(event) = line.strip_prefix("event: ") {
            current_event = event.to_string();
        } else if let Some(data) = line.strip_prefix("data: ") {
            current_data = data.to_string();
        } else if line.is_empty() && !current_event.is_empty() {
            events.push((current_event.clone(), current_data.clone()));
            current_event.clear();
            current_data.clear();
        }
    }

    // Handle trailing event without blank line
    if !current_event.is_empty() {
        events.push((current_event, current_data));
    }

    events
}

// --- Deserialization types for Anthropic SSE events ---

#[derive(Deserialize)]
struct MessageStartEvent {
    message: MessageStartPayload,
}

#[derive(Deserialize)]
struct MessageStartPayload {
    usage: Option<UsagePayload>,
}

#[derive(Deserialize)]
struct UsagePayload {
    input_tokens: Option<u32>,
    output_tokens: Option<u32>,
    cache_read_input_tokens: Option<u32>,
    cache_creation_input_tokens: Option<u32>,
}

#[derive(Deserialize)]
struct ContentBlockStartEvent {
    index: usize,
    content_block: Value,
}

#[derive(Deserialize)]
struct ContentBlockDeltaEvent {
    delta: Value,
}

#[derive(Deserialize)]
struct MessageDeltaEvent {
    usage: Option<UsagePayload>,
}

#[derive(Deserialize)]
struct ErrorEvent {
    error: ErrorPayload,
}

#[derive(Deserialize)]
struct ErrorPayload {
    #[serde(rename = "type")]
    error_type: String,
    message: String,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_simple_text_stream() {
        let mut parser = SseParser::new();

        // message_start
        let events = parser.parse_event(
            "message_start",
            r#"{"type":"message_start","message":{"id":"msg_1","type":"message","role":"assistant","content":[],"model":"claude-sonnet-4-5-20250929","usage":{"input_tokens":100,"output_tokens":0,"cache_read_input_tokens":50}}}"#,
        );
        assert_eq!(events.len(), 1);
        assert!(matches!(events[0], StreamEvent::Start));

        // content_block_start (text)
        let events = parser.parse_event(
            "content_block_start",
            r#"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
        );
        assert_eq!(events.len(), 1);
        assert!(matches!(events[0], StreamEvent::TextStart));

        // content_block_delta
        let events = parser.parse_event(
            "content_block_delta",
            r#"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}"#,
        );
        assert_eq!(events.len(), 1);
        assert!(matches!(events[0], StreamEvent::TextDelta { .. }));

        let events = parser.parse_event(
            "content_block_delta",
            r#"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":" world!"}}"#,
        );
        assert_eq!(events.len(), 1);

        // content_block_stop
        let events = parser.parse_event("content_block_stop", r#"{"type":"content_block_stop","index":0}"#);
        assert_eq!(events.len(), 1);
        if let StreamEvent::TextEnd { text, .. } = &events[0] {
            assert_eq!(text, "Hello world!");
        } else {
            panic!("expected TextEnd");
        }

        // message_delta (output tokens)
        let events = parser.parse_event(
            "message_delta",
            r#"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":25}}"#,
        );
        assert!(events.is_empty());

        // message_stop
        let events = parser.parse_event("message_stop", r#"{"type":"message_stop"}"#);
        assert_eq!(events.len(), 1);
        if let StreamEvent::Done { message, stop_reason } = &events[0] {
            assert_eq!(message.text_content(), "Hello world!");
            assert_eq!(*stop_reason, StopReason::EndTurn);
            let usage = message.usage.as_ref().unwrap();
            assert_eq!(usage.input_tokens, 100);
            assert_eq!(usage.output_tokens, 25);
            assert_eq!(usage.cache_read_tokens, 50);
        } else {
            panic!("expected Done");
        }
    }

    #[test]
    fn parse_tool_use_stream() {
        let mut parser = SseParser::new();

        parser.parse_event("message_start", r#"{"type":"message_start","message":{"usage":{"input_tokens":200}}}"#);

        // Tool call start
        let events = parser.parse_event(
            "content_block_start",
            r#"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_abc","name":"Read"}}"#,
        );
        assert_eq!(events.len(), 1);
        if let StreamEvent::ToolCallStart { name, .. } = &events[0] {
            assert_eq!(name, "Read");
        } else {
            panic!("expected ToolCallStart");
        }

        // Tool call delta
        parser.parse_event(
            "content_block_delta",
            r#"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"file_path\""}}"#,
        );
        parser.parse_event(
            "content_block_delta",
            r#"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":":\"/tmp/test\"}"}}"#,
        );

        // Tool call stop
        let events = parser.parse_event("content_block_stop", r#"{"type":"content_block_stop","index":0}"#);
        assert_eq!(events.len(), 1);
        if let StreamEvent::ToolCallEnd { tool_call } = &events[0] {
            assert_eq!(tool_call.name, "Read");
            assert_eq!(tool_call.arguments["file_path"], "/tmp/test");
        } else {
            panic!("expected ToolCallEnd");
        }

        // message_stop → stop_reason should be ToolUse
        let events = parser.parse_event("message_stop", r#"{"type":"message_stop"}"#);
        if let StreamEvent::Done { stop_reason, .. } = &events[0] {
            assert_eq!(*stop_reason, StopReason::ToolUse);
        }
    }

    #[test]
    fn parse_thinking_stream() {
        let mut parser = SseParser::new();
        parser.parse_event("message_start", r#"{"type":"message_start","message":{"usage":{"input_tokens":50}}}"#);

        // Thinking block
        parser.parse_event(
            "content_block_start",
            r#"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#,
        );
        parser.parse_event(
            "content_block_delta",
            r#"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Let me think..."}}"#,
        );
        parser.parse_event(
            "content_block_delta",
            r#"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"sig_xyz"}}"#,
        );

        let events = parser.parse_event("content_block_stop", r#"{"type":"content_block_stop","index":0}"#);
        if let StreamEvent::ThinkingEnd { thinking, signature } = &events[0] {
            assert_eq!(thinking, "Let me think...");
            assert_eq!(signature.as_deref(), Some("sig_xyz"));
        } else {
            panic!("expected ThinkingEnd");
        }
    }

    #[test]
    fn parse_error_event() {
        let mut parser = SseParser::new();
        let events = parser.parse_event(
            "error",
            r#"{"type":"error","error":{"type":"overloaded_error","message":"server busy"}}"#,
        );
        assert_eq!(events.len(), 1);
        if let StreamEvent::Error { error } = &events[0] {
            assert!(error.is_retryable());
        } else {
            panic!("expected Error");
        }
    }

    #[test]
    fn parse_rate_limit_error() {
        let mut parser = SseParser::new();
        let events = parser.parse_event(
            "error",
            r#"{"type":"error","error":{"type":"rate_limit_error","message":"too many requests"}}"#,
        );
        assert!(matches!(&events[0], StreamEvent::Error { error } if error.is_retryable()));
    }

    #[test]
    fn parse_auth_error() {
        let mut parser = SseParser::new();
        let events = parser.parse_event(
            "error",
            r#"{"type":"error","error":{"type":"authentication_error","message":"invalid key"}}"#,
        );
        assert!(matches!(&events[0], StreamEvent::Error { error } if error.is_fatal()));
    }

    #[test]
    fn parse_sse_lines_basic() {
        let raw = "event: message_start\ndata: {\"hello\":true}\n\nevent: message_stop\ndata: {}\n\n";
        let events = parse_sse_lines(raw);
        assert_eq!(events.len(), 2);
        assert_eq!(events[0].0, "message_start");
        assert_eq!(events[1].0, "message_stop");
    }

    #[test]
    fn token_usage_extraction() {
        let mut parser = SseParser::new();
        parser.parse_event(
            "message_start",
            r#"{"type":"message_start","message":{"usage":{"input_tokens":500,"cache_read_input_tokens":200,"cache_creation_input_tokens":100}}}"#,
        );
        parser.parse_event(
            "message_delta",
            r#"{"type":"message_delta","usage":{"output_tokens":300}}"#,
        );

        let usage = parser.token_usage();
        assert_eq!(usage.input_tokens, 500);
        assert_eq!(usage.output_tokens, 300);
        assert_eq!(usage.cache_read_tokens, 200);
        assert_eq!(usage.cache_creation_tokens, 100);
    }
}
