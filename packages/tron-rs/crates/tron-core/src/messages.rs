use serde::{Deserialize, Serialize};

use crate::ids::ToolCallId;
use crate::tokens::TokenUsage;

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(tag = "role")]
pub enum Message {
    #[serde(rename = "user")]
    User(UserMessage),
    #[serde(rename = "assistant")]
    Assistant(AssistantMessage),
    #[serde(rename = "tool_result")]
    ToolResult(ToolResultMessage),
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct UserMessage {
    pub content: Vec<UserContent>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct AssistantMessage {
    pub content: Vec<AssistantContent>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub usage: Option<TokenUsage>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub stop_reason: Option<StopReason>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ToolResultMessage {
    pub tool_call_id: ToolCallId,
    pub content: Vec<ToolResultContent>,
}

// --- Content types ---

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum UserContent {
    #[serde(rename = "text")]
    Text { text: String },
    #[serde(rename = "image")]
    Image { mime_type: String, data: String },
    #[serde(rename = "document")]
    Document { mime_type: String, data: String },
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum AssistantContent {
    #[serde(rename = "text")]
    Text { text: String },
    #[serde(rename = "thinking")]
    Thinking {
        text: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        signature: Option<String>,
    },
    #[serde(rename = "tool_call")]
    ToolCall(ToolCallBlock),
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum ToolResultContent {
    #[serde(rename = "text")]
    Text { text: String },
    #[serde(rename = "image")]
    Image { mime_type: String, data: String },
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ToolCallBlock {
    pub id: ToolCallId,
    pub name: String,
    pub arguments: serde_json::Value,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub thought_signature: Option<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum StopReason {
    EndTurn,
    ToolUse,
    MaxTokens,
    StopSequence,
}

// --- Convenience constructors ---

impl Message {
    pub fn user_text(text: impl Into<String>) -> Self {
        Message::User(UserMessage {
            content: vec![UserContent::Text { text: text.into() }],
        })
    }

    pub fn assistant_text(text: impl Into<String>) -> Self {
        Message::Assistant(AssistantMessage {
            content: vec![AssistantContent::Text { text: text.into() }],
            usage: None,
            stop_reason: Some(StopReason::EndTurn),
        })
    }

    pub fn tool_result(tool_call_id: ToolCallId, text: impl Into<String>) -> Self {
        Message::ToolResult(ToolResultMessage {
            tool_call_id,
            content: vec![ToolResultContent::Text { text: text.into() }],
        })
    }
}

impl UserMessage {
    pub fn text(text: impl Into<String>) -> Self {
        Self {
            content: vec![UserContent::Text { text: text.into() }],
        }
    }
}

impl AssistantMessage {
    pub fn text(text: impl Into<String>) -> Self {
        Self {
            content: vec![AssistantContent::Text { text: text.into() }],
            usage: None,
            stop_reason: Some(StopReason::EndTurn),
        }
    }

    pub fn tool_calls(&self) -> Vec<&ToolCallBlock> {
        self.content
            .iter()
            .filter_map(|c| match c {
                AssistantContent::ToolCall(tc) => Some(tc),
                _ => None,
            })
            .collect()
    }

    pub fn text_content(&self) -> String {
        self.content
            .iter()
            .filter_map(|c| match c {
                AssistantContent::Text { text } => Some(text.as_str()),
                _ => None,
            })
            .collect::<Vec<_>>()
            .join("")
    }

    pub fn has_tool_calls(&self) -> bool {
        self.content
            .iter()
            .any(|c| matches!(c, AssistantContent::ToolCall(_)))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn user_text_message() {
        let msg = Message::user_text("hello");
        let json = serde_json::to_value(&msg).unwrap();
        assert_eq!(json["role"], "user");
        assert_eq!(json["content"][0]["type"], "text");
        assert_eq!(json["content"][0]["text"], "hello");
    }

    #[test]
    fn assistant_text_message() {
        let msg = Message::assistant_text("world");
        let json = serde_json::to_value(&msg).unwrap();
        assert_eq!(json["role"], "assistant");
        assert_eq!(json["content"][0]["type"], "text");
        assert_eq!(json["content"][0]["text"], "world");
    }

    #[test]
    fn tool_result_message() {
        let id = ToolCallId::new();
        let msg = Message::tool_result(id.clone(), "result");
        let json = serde_json::to_value(&msg).unwrap();
        assert_eq!(json["role"], "tool_result");
        assert_eq!(json["tool_call_id"], id.as_str());
    }

    #[test]
    fn assistant_tool_calls_extracted() {
        let tc = ToolCallBlock {
            id: ToolCallId::new(),
            name: "Read".into(),
            arguments: serde_json::json!({"path": "/tmp/test"}),
            thought_signature: None,
        };
        let msg = AssistantMessage {
            content: vec![
                AssistantContent::Text { text: "reading file".into() },
                AssistantContent::ToolCall(tc.clone()),
            ],
            usage: None,
            stop_reason: Some(StopReason::ToolUse),
        };
        assert!(msg.has_tool_calls());
        assert_eq!(msg.tool_calls().len(), 1);
        assert_eq!(msg.tool_calls()[0].name, "Read");
        assert_eq!(msg.text_content(), "reading file");
    }

    #[test]
    fn serde_roundtrip_all_variants() {
        let messages = vec![
            Message::user_text("hi"),
            Message::assistant_text("hello"),
            Message::tool_result(ToolCallId::new(), "done"),
            Message::User(UserMessage {
                content: vec![
                    UserContent::Text { text: "look".into() },
                    UserContent::Image { mime_type: "image/png".into(), data: "base64data".into() },
                    UserContent::Document { mime_type: "application/pdf".into(), data: "pdfdata".into() },
                ],
            }),
            Message::Assistant(AssistantMessage {
                content: vec![
                    AssistantContent::Text { text: "thinking...".into() },
                    AssistantContent::Thinking { text: "hmm".into(), signature: Some("sig123".into()) },
                    AssistantContent::ToolCall(ToolCallBlock {
                        id: ToolCallId::new(),
                        name: "Bash".into(),
                        arguments: serde_json::json!({"command": "ls"}),
                        thought_signature: Some("sig456".into()),
                    }),
                ],
                usage: None,
                stop_reason: Some(StopReason::ToolUse),
            }),
        ];

        for msg in &messages {
            let json = serde_json::to_string(msg).unwrap();
            let parsed: Message = serde_json::from_str(&json).unwrap();
            let json2 = serde_json::to_string(&parsed).unwrap();
            assert_eq!(json, json2, "roundtrip failed for {json}");
        }
    }

    #[test]
    fn stop_reason_serialization() {
        assert_eq!(serde_json::to_string(&StopReason::EndTurn).unwrap(), r#""end_turn""#);
        assert_eq!(serde_json::to_string(&StopReason::ToolUse).unwrap(), r#""tool_use""#);
        assert_eq!(serde_json::to_string(&StopReason::MaxTokens).unwrap(), r#""max_tokens""#);
        assert_eq!(serde_json::to_string(&StopReason::StopSequence).unwrap(), r#""stop_sequence""#);
    }
}
