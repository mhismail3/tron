//! Converts [`Context`] messages to Gemini API format.
//!
//! Handles text, images, PDFs, capability invocations (with `thoughtSignature`), and capability results.
//! Sanitizes JSON schemas by removing unsupported properties (`additionalProperties`, `$schema`).

use crate::domains::model::providers::id_remapping::{
    IdFormat, build_invocation_id_mapping, remap_invocation_id,
};
use crate::shared::protocol::content::{AssistantContent, UserContent};
use crate::shared::protocol::messages::{
    CapabilityResultMessageContent, Context, Message, UserMessageContent,
};
use crate::shared::protocol::model_capabilities::ModelCapability;

use super::types::{
    FunctionCallData, FunctionDeclaration, FunctionResponseData, GeminiContent, GeminiPart,
    GeminiTool, InlineDataContent, TOOL_RESULT_MAX_LENGTH,
};

/// Placeholder thought signature for historical function calls from other providers.
///
/// When a capability invocation doesn't have a thought signature (e.g., it came from Anthropic
/// or `OpenAI`), this placeholder is used to satisfy the Gemini 3 validator.
const SKIP_THOUGHT_SIGNATURE: &str = "skip_thought_signature_validator";

/// Collect all capability invocation IDs from assistant messages for cross-provider remapping.
fn collect_invocation_ids(messages: &[Message]) -> Vec<String> {
    messages
        .iter()
        .filter_map(|m| match m {
            Message::Assistant { content, .. } => {
                let ids: Vec<String> = content
                    .iter()
                    .filter_map(|c| match c {
                        AssistantContent::CapabilityInvocation { id, .. } => Some(id.clone()),
                        _ => None,
                    })
                    .collect();
                if ids.is_empty() { None } else { Some(ids) }
            }
            _ => None,
        })
        .flatten()
        .collect()
}

/// Convert context messages to Gemini API content format.
///
/// Builds a capability invocation ID mapping for cross-provider remapping, then converts
/// each message to `GeminiContent` with appropriate parts.
pub fn convert_messages(context: &Context) -> Vec<GeminiContent> {
    let messages = &context.messages;
    if messages.is_empty() {
        return vec![];
    }

    let all_invocation_ids = collect_invocation_ids(messages);
    let id_refs: Vec<&str> = all_invocation_ids.iter().map(String::as_str).collect();
    let id_mapping = build_invocation_id_mapping(&id_refs, IdFormat::OpenAi);

    let mut contents = Vec::new();

    for message in messages.iter() {
        match message {
            Message::User { content, .. } => {
                let parts = convert_user_content(content);
                if !parts.is_empty() {
                    contents.push(GeminiContent {
                        role: "user".into(),
                        parts,
                    });
                }
            }
            Message::Assistant { content, .. } => {
                let mut parts = Vec::new();

                for block in content {
                    match block {
                        AssistantContent::Text { text } => {
                            if !text.is_empty() {
                                parts.push(GeminiPart::Text {
                                    text: text.clone(),
                                    thought: None,
                                    thought_signature: None,
                                });
                            }
                        }
                        AssistantContent::CapabilityInvocation {
                            name,
                            arguments,
                            thought_signature,
                            ..
                        } => {
                            let args = serde_json::Value::Object(arguments.clone());

                            let thought_sig = thought_signature
                                .clone()
                                .unwrap_or_else(|| SKIP_THOUGHT_SIGNATURE.to_string());

                            parts.push(GeminiPart::FunctionCall {
                                function_call: FunctionCallData {
                                    name: name.clone(),
                                    args,
                                },
                                thought_signature: Some(thought_sig),
                            });
                        }
                        AssistantContent::Thinking { .. } => {
                            // Thinking blocks are not sent back to Gemini
                        }
                    }
                }

                if !parts.is_empty() {
                    contents.push(GeminiContent {
                        role: "model".into(),
                        parts,
                    });
                }
            }
            Message::CapabilityResult {
                invocation_id,
                content,
                ..
            } => {
                let remapped_id = remap_invocation_id(invocation_id, &id_mapping);
                let result_text = extract_capability_result_text(content);
                let truncated = truncate_capability_result(&result_text);

                contents.push(GeminiContent {
                    role: "user".into(),
                    parts: vec![GeminiPart::FunctionResponse {
                        function_response: FunctionResponseData {
                            name: "capability_result".into(),
                            response: serde_json::json!({
                                "result": truncated,
                                "invocation_id": remapped_id,
                            }),
                        },
                    }],
                });
            }
        }
    }

    contents
}

/// Extract text from capability result message content.
fn extract_capability_result_text(content: &CapabilityResultMessageContent) -> String {
    match content {
        CapabilityResultMessageContent::Text(text) => text.clone(),
        CapabilityResultMessageContent::Blocks(blocks) => blocks
            .iter()
            .filter_map(|b| match b {
                crate::shared::protocol::content::CapabilityResultContent::Text { text } => {
                    Some(text.as_str())
                }
                crate::shared::protocol::content::CapabilityResultContent::Image { .. } => None,
            })
            .collect::<Vec<_>>()
            .join("\n"),
    }
}

/// Convert user message content to Gemini parts.
fn convert_user_content(content: &UserMessageContent) -> Vec<GeminiPart> {
    match content {
        UserMessageContent::Text(text) => {
            if text.is_empty() {
                vec![]
            } else {
                vec![GeminiPart::Text {
                    text: text.clone(),
                    thought: None,
                    thought_signature: None,
                }]
            }
        }
        UserMessageContent::Blocks(blocks) => blocks
            .iter()
            .filter_map(|block| match block {
                UserContent::Text { text } => Some(GeminiPart::Text {
                    text: text.clone(),
                    thought: None,
                    thought_signature: None,
                }),
                UserContent::Image { data, mime_type } => Some(GeminiPart::InlineData {
                    inline_data: InlineDataContent {
                        mime_type: mime_type.clone(),
                        data: data.clone(),
                    },
                }),
                UserContent::Document {
                    data,
                    mime_type,
                    extracted_text,
                    ..
                } => {
                    if mime_type == "application/pdf" {
                        Some(GeminiPart::InlineData {
                            inline_data: InlineDataContent {
                                mime_type: "application/pdf".into(),
                                data: data.clone(),
                            },
                        })
                    } else if let Some(text) = extracted_text {
                        Some(GeminiPart::Text {
                            text: text.clone(),
                            thought: None,
                            thought_signature: None,
                        })
                    } else {
                        None
                    }
                }
            })
            .collect(),
    }
}

/// Convert capabilities to Gemini API format.
///
/// Returns a single-element array with all function declarations.
pub fn convert_tools(capabilities: &[ModelCapability]) -> Vec<GeminiTool> {
    let declarations: Vec<FunctionDeclaration> = capabilities
        .iter()
        .map(|tool| {
            let schema = serde_json::to_value(&tool.parameters).unwrap_or_default();
            let params = sanitize_schema_for_gemini(&schema);

            FunctionDeclaration {
                name: tool.name.clone(),
                description: tool.description.clone(),
                parameters: params,
            }
        })
        .collect();

    if declarations.is_empty() {
        return vec![];
    }

    vec![GeminiTool {
        function_declarations: declarations,
    }]
}

/// Sanitize a JSON schema for the Gemini API.
///
/// Removes unsupported properties:
/// - `additionalProperties` — Gemini doesn't support it
/// - `$schema` — not needed for API calls
pub fn sanitize_schema_for_gemini(schema: &serde_json::Value) -> serde_json::Value {
    match schema {
        serde_json::Value::Object(map) => {
            let mut cleaned = serde_json::Map::new();
            for (key, value) in map {
                if key == "additionalProperties" || key == "$schema" {
                    continue;
                }
                let _ = cleaned.insert(key.clone(), sanitize_schema_for_gemini(value));
            }
            serde_json::Value::Object(cleaned)
        }
        serde_json::Value::Array(arr) => {
            serde_json::Value::Array(arr.iter().map(sanitize_schema_for_gemini).collect())
        }
        other => other.clone(),
    }
}

/// Truncate capability result content if it exceeds the max length.
fn truncate_capability_result(content: &str) -> String {
    if content.len() <= TOOL_RESULT_MAX_LENGTH {
        content.to_string()
    } else {
        let truncated =
            crate::shared::foundation::text::truncate_str(content, TOOL_RESULT_MAX_LENGTH);
        format!("{truncated}\n\n[Content truncated — {TOOL_RESULT_MAX_LENGTH} char limit]")
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
#[allow(unused_results)]
mod tests {
    use super::*;
    use crate::shared::protocol::content::AssistantContent;
    use crate::shared::protocol::messages::UserMessageContent;
    use serde_json::Map;

    fn ctx(messages: Vec<Message>) -> Context {
        Context {
            messages: messages.into(),
            system_prompt: None,
            capabilities: None,
            working_directory: None,
            agent_state_context: None,
            server_origin: None,
        }
    }

    // ── convert_messages ─────────────────────────────────────────────

    #[test]
    fn empty_messages_returns_empty() {
        assert!(convert_messages(&ctx(vec![])).is_empty());
    }

    #[test]
    fn converts_user_text_message() {
        let context = ctx(vec![Message::user("hello")]);
        let contents = convert_messages(&context);
        assert_eq!(contents.len(), 1);
        assert_eq!(contents[0].role, "user");
        match &contents[0].parts[0] {
            GeminiPart::Text { text, .. } => assert_eq!(text, "hello"),
            _ => panic!("Expected text part"),
        }
    }

    #[test]
    fn converts_user_blocks_message() {
        let context = ctx(vec![Message::User {
            content: UserMessageContent::Blocks(vec![UserContent::text("hello")]),
            timestamp: None,
        }]);
        let contents = convert_messages(&context);
        assert_eq!(contents.len(), 1);
        assert_eq!(contents[0].role, "user");
    }

    #[test]
    fn converts_assistant_text() {
        let context = ctx(vec![Message::assistant("response")]);
        let contents = convert_messages(&context);
        assert_eq!(contents.len(), 1);
        assert_eq!(contents[0].role, "model");
    }

    #[test]
    fn converts_assistant_capability_invocations_with_thought_signature() {
        let mut args = Map::new();
        args.insert("command".into(), serde_json::json!("ls"));
        let context = ctx(vec![Message::Assistant {
            content: vec![AssistantContent::CapabilityInvocation {
                id: "call_123".into(),
                name: "execute".into(),
                arguments: args,
                thought_signature: Some("sig-abc".into()),
            }],
            usage: None,
            cost: None,
            stop_reason: None,
            thinking: None,
        }]);
        let contents = convert_messages(&context);
        assert_eq!(contents.len(), 1);
        match &contents[0].parts[0] {
            GeminiPart::FunctionCall {
                function_call,
                thought_signature,
            } => {
                assert_eq!(function_call.name, "execute");
                assert_eq!(thought_signature.as_deref(), Some("sig-abc"));
            }
            _ => panic!("Expected function call part"),
        }
    }

    #[test]
    fn capability_invocation_without_signature_uses_placeholder() {
        let context = ctx(vec![Message::Assistant {
            content: vec![AssistantContent::CapabilityInvocation {
                id: "toolu_123".into(),
                name: "inspect".into(),
                arguments: Map::new(),
                thought_signature: None,
            }],
            usage: None,
            cost: None,
            stop_reason: None,
            thinking: None,
        }]);
        let contents = convert_messages(&context);
        match &contents[0].parts[0] {
            GeminiPart::FunctionCall {
                thought_signature, ..
            } => {
                assert_eq!(thought_signature.as_deref(), Some(SKIP_THOUGHT_SIGNATURE));
            }
            _ => panic!("Expected function call"),
        }
    }

    #[test]
    fn converts_capability_result() {
        let context = ctx(vec![Message::CapabilityResult {
            invocation_id: "call_abc".into(),
            content: CapabilityResultMessageContent::Text("result text".into()),
            is_error: None,
        }]);
        let contents = convert_messages(&context);
        assert_eq!(contents.len(), 1);
        assert_eq!(contents[0].role, "user");
        match &contents[0].parts[0] {
            GeminiPart::FunctionResponse {
                function_response, ..
            } => {
                assert_eq!(function_response.name, "capability_result");
            }
            _ => panic!("Expected function response"),
        }
    }

    #[test]
    fn converts_image_content() {
        let context = ctx(vec![Message::User {
            content: UserMessageContent::Blocks(vec![UserContent::image(
                "base64data",
                "image/png",
            )]),
            timestamp: None,
        }]);
        let contents = convert_messages(&context);
        match &contents[0].parts[0] {
            GeminiPart::InlineData { inline_data } => {
                assert_eq!(inline_data.mime_type, "image/png");
                assert_eq!(inline_data.data, "base64data");
            }
            _ => panic!("Expected inline data"),
        }
    }

    #[test]
    fn converts_pdf_document() {
        let context = ctx(vec![Message::User {
            content: UserMessageContent::Blocks(vec![UserContent::Document {
                data: "pdfdata".into(),
                mime_type: "application/pdf".into(),
                file_name: None,
                extracted_text: None,
            }]),
            timestamp: None,
        }]);
        let contents = convert_messages(&context);
        match &contents[0].parts[0] {
            GeminiPart::InlineData { inline_data } => {
                assert_eq!(inline_data.mime_type, "application/pdf");
            }
            _ => panic!("Expected inline data for PDF"),
        }
    }

    // ── convert_tools ────────────────────────────────────────────────

    #[test]
    fn converts_tools_to_gemini_format() {
        let mut props = serde_json::Map::new();
        props.insert("command".into(), serde_json::json!({"type": "string"}));
        let capabilities = vec![ModelCapability {
            name: "execute".into(),
            description: "Run a command".into(),
            parameters: crate::shared::protocol::model_capabilities::CapabilityParameterSchema {
                schema_type: "object".into(),
                properties: Some(props),
                required: Some(vec!["command".into()]),
                description: None,
                extra: serde_json::Map::new(),
            },
        }];
        let gemini_tools = convert_tools(&capabilities);
        assert_eq!(gemini_tools.len(), 1);
        assert_eq!(gemini_tools[0].function_declarations.len(), 1);
        assert_eq!(gemini_tools[0].function_declarations[0].name, "execute");
    }

    #[test]
    fn empty_tools_returns_empty() {
        let capabilities: Vec<ModelCapability> = vec![];
        assert!(convert_tools(&capabilities).is_empty());
    }

    // ── sanitize_schema ──────────────────────────────────────────────

    #[test]
    fn sanitize_removes_additional_properties() {
        let schema = serde_json::json!({
            "type": "object",
            "properties": {"x": {"type": "string"}},
            "additionalProperties": false,
        });
        let sanitized = sanitize_schema_for_gemini(&schema);
        assert!(sanitized.get("additionalProperties").is_none());
        assert_eq!(sanitized["type"], "object");
    }

    #[test]
    fn sanitize_removes_dollar_schema() {
        let schema = serde_json::json!({
            "$schema": "http://json-schema.org/draft-07/schema#",
            "type": "object",
        });
        let sanitized = sanitize_schema_for_gemini(&schema);
        assert!(sanitized.get("$schema").is_none());
    }

    #[test]
    fn sanitize_recurses_into_nested_objects() {
        let schema = serde_json::json!({
            "type": "object",
            "properties": {
                "nested": {
                    "type": "object",
                    "additionalProperties": true,
                }
            }
        });
        let sanitized = sanitize_schema_for_gemini(&schema);
        assert!(
            sanitized["properties"]["nested"]
                .get("additionalProperties")
                .is_none()
        );
    }

    // ── truncate_capability_result ─────────────────────────────────────────

    #[test]
    fn short_result_not_truncated() {
        let result = truncate_capability_result("short");
        assert_eq!(result, "short");
    }

    #[test]
    fn long_result_truncated() {
        let long_text = "x".repeat(TOOL_RESULT_MAX_LENGTH + 100);
        let result = truncate_capability_result(&long_text);
        assert!(result.len() < long_text.len());
        assert!(result.contains("[Content truncated"));
    }
}
