//! `AskUserQuestion` tool — interactive user prompting.
//!
//! Presents questions with options to the user. This is an interactive,
//! turn-stopping tool: execution returns immediately and the user's answer
//! arrives as the next prompt.

use async_trait::async_trait;
use serde_json::{json, Value};
use tron_core::tools::{
    Tool, ToolCategory, ToolParameterSchema, ToolResultBody, TronToolResult, error_result,
};

use std::fmt::Write;

use crate::errors::ToolError;
use crate::traits::{ToolContext, TronTool};
use crate::utils::validation::get_optional_string;

const MAX_QUESTIONS: usize = 5;
const MIN_OPTIONS: usize = 2;

/// The `AskUserQuestion` tool presents interactive questions to the user.
pub struct AskUserQuestionTool;

impl AskUserQuestionTool {
    /// Create a new `AskUserQuestion` tool.
    pub fn new() -> Self {
        Self
    }
}

impl Default for AskUserQuestionTool {
    fn default() -> Self {
        Self::new()
    }
}

#[async_trait]
impl TronTool for AskUserQuestionTool {
    fn name(&self) -> &str {
        "AskUserQuestion"
    }

    fn category(&self) -> ToolCategory {
        ToolCategory::Custom
    }

    fn is_interactive(&self) -> bool {
        true
    }

    fn stops_turn(&self) -> bool {
        true
    }

    fn definition(&self) -> Tool {
        Tool {
            name: "AskUserQuestion".into(),
            description: "Present questions with options to the user.".into(),
            parameters: ToolParameterSchema {
                schema_type: "object".into(),
                properties: Some({
                    let mut m = serde_json::Map::new();
                    let _ = m.insert("questions".into(), json!({
                        "type": "array",
                        "description": "Array of questions (1-5) with options",
                        "items": {
                            "type": "object",
                            "properties": {
                                "id": {"type": "string"},
                                "question": {"type": "string"},
                                "options": {"type": "array", "items": {"type": "string"}},
                                "mode": {"type": "string", "enum": ["single", "multi"]}
                            }
                        }
                    }));
                    let _ = m.insert("context".into(), json!({"type": "string", "description": "Additional context for the questions"}));
                    m
                }),
                required: Some(vec!["questions".into()]),
                description: None,
                extra: serde_json::Map::new(),
            },
        }
    }

    async fn execute(
        &self,
        params: Value,
        _ctx: &ToolContext,
    ) -> Result<TronToolResult, ToolError> {
        let Some(questions) = params.get("questions").and_then(Value::as_array) else {
            return Ok(error_result("Missing required parameter: questions"));
        };

        if questions.is_empty() {
            return Ok(error_result("At least one question is required"));
        }

        if questions.len() > MAX_QUESTIONS {
            return Ok(error_result(format!("Maximum {MAX_QUESTIONS} questions allowed")));
        }

        // Validate each question has enough options
        for (i, q) in questions.iter().enumerate() {
            let options = q.get("options").and_then(Value::as_array);
            if let Some(opts) = options {
                if opts.len() < MIN_OPTIONS {
                    return Ok(error_result(format!("Question {} must have at least {MIN_OPTIONS} options", i + 1)));
                }
            }
        }

        let context = get_optional_string(&params, "context");

        // Format summary
        let mut summary = String::new();
        for (i, q) in questions.iter().enumerate() {
            let text = q.get("question").and_then(Value::as_str).unwrap_or("(no question)");
            let mode = q.get("mode").and_then(Value::as_str).unwrap_or("single");
            let _ = writeln!(summary, "Q{}: {text} [{mode}]", i + 1);
        }

        if let Some(ctx) = &context {
            let _ = write!(summary, "\nContext: {ctx}");
        }

        Ok(TronToolResult {
            content: ToolResultBody::Blocks(vec![
                tron_core::content::ToolResultContent::text(summary),
            ]),
            details: Some(json!({
                "questionCount": questions.len(),
                "context": context,
            })),
            is_error: None,
            stop_turn: Some(true),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_ctx() -> ToolContext {
        ToolContext {
            tool_call_id: "call-1".into(),
            session_id: "sess-1".into(),
            working_directory: "/tmp".into(),
            cancellation: tokio_util::sync::CancellationToken::new(),
        }
    }

    fn extract_text(result: &TronToolResult) -> String {
        match &result.content {
            ToolResultBody::Text(t) => t.clone(),
            ToolResultBody::Blocks(blocks) => blocks.iter().filter_map(|b| match b {
                tron_core::content::ToolResultContent::Text { text } => Some(text.as_str()),
                _ => None,
            }).collect::<Vec<_>>().join(""),
        }
    }

    #[tokio::test]
    async fn valid_questions_returns_stop_turn() {
        let tool = AskUserQuestionTool::new();
        let r = tool.execute(json!({
            "questions": [{"question": "Pick one", "options": ["A", "B"]}]
        }), &make_ctx()).await.unwrap();
        assert_eq!(r.stop_turn, Some(true));
        assert!(r.is_error.is_none());
    }

    #[tokio::test]
    async fn is_interactive_returns_true() {
        let tool = AskUserQuestionTool::new();
        assert!(tool.is_interactive());
    }

    #[tokio::test]
    async fn stops_turn_returns_true() {
        let tool = AskUserQuestionTool::new();
        assert!(tool.stops_turn());
    }

    #[tokio::test]
    async fn one_question_two_options() {
        let tool = AskUserQuestionTool::new();
        let r = tool.execute(json!({
            "questions": [{"question": "Choose", "options": ["X", "Y"]}]
        }), &make_ctx()).await.unwrap();
        assert!(r.is_error.is_none());
    }

    #[tokio::test]
    async fn max_questions() {
        let questions: Vec<Value> = (1..=5).map(|i| {
            json!({"question": format!("Q{i}"), "options": ["A", "B"]})
        }).collect();
        let tool = AskUserQuestionTool::new();
        let r = tool.execute(json!({"questions": questions}), &make_ctx()).await.unwrap();
        assert!(r.is_error.is_none());
    }

    #[tokio::test]
    async fn zero_questions_error() {
        let tool = AskUserQuestionTool::new();
        let r = tool.execute(json!({"questions": []}), &make_ctx()).await.unwrap();
        assert_eq!(r.is_error, Some(true));
    }

    #[tokio::test]
    async fn too_many_questions_error() {
        let questions: Vec<Value> = (1..=6).map(|i| {
            json!({"question": format!("Q{i}"), "options": ["A", "B"]})
        }).collect();
        let tool = AskUserQuestionTool::new();
        let r = tool.execute(json!({"questions": questions}), &make_ctx()).await.unwrap();
        assert_eq!(r.is_error, Some(true));
    }

    #[tokio::test]
    async fn too_few_options_error() {
        let tool = AskUserQuestionTool::new();
        let r = tool.execute(json!({
            "questions": [{"question": "Q", "options": ["only one"]}]
        }), &make_ctx()).await.unwrap();
        assert_eq!(r.is_error, Some(true));
    }

    #[tokio::test]
    async fn mode_single_and_multi() {
        let tool = AskUserQuestionTool::new();
        let r = tool.execute(json!({
            "questions": [
                {"question": "Pick", "options": ["A", "B"], "mode": "single"},
                {"question": "Select", "options": ["X", "Y"], "mode": "multi"}
            ]
        }), &make_ctx()).await.unwrap();
        assert!(r.is_error.is_none());
        let text = extract_text(&r);
        assert!(text.contains("[single]"));
        assert!(text.contains("[multi]"));
    }

    #[tokio::test]
    async fn context_included() {
        let tool = AskUserQuestionTool::new();
        let r = tool.execute(json!({
            "questions": [{"question": "Q", "options": ["A", "B"]}],
            "context": "some context"
        }), &make_ctx()).await.unwrap();
        let text = extract_text(&r);
        assert!(text.contains("some context"));
    }

    #[tokio::test]
    async fn missing_questions_error() {
        let tool = AskUserQuestionTool::new();
        let r = tool.execute(json!({}), &make_ctx()).await.unwrap();
        assert_eq!(r.is_error, Some(true));
    }

    #[tokio::test]
    async fn result_content_formatted() {
        let tool = AskUserQuestionTool::new();
        let r = tool.execute(json!({
            "questions": [{"question": "Choose a color", "options": ["Red", "Blue"]}]
        }), &make_ctx()).await.unwrap();
        let text = extract_text(&r);
        assert!(text.contains("Choose a color"));
    }
}
