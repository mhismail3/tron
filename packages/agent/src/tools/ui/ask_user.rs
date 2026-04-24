//! `AskUserQuestion` tool — interactive user prompting.
//!
//! Presents questions with options to the user. This is an interactive,
//! turn-stopping tool: execution returns immediately and the user's answer
//! arrives as the next prompt.

use crate::core::tools::{Tool, ToolCategory, ToolResultBody, TronToolResult, error_result};
use async_trait::async_trait;
use serde_json::{Value, json};

use crate::tools::errors::ToolError;
use crate::tools::traits::{ToolContext, TronTool};
use crate::tools::utils::schema::ToolSchemaBuilder;
use crate::tools::utils::validation::get_optional_string;

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
        ToolSchemaBuilder::new(
            "AskUserQuestion",
            "Ask the user interactive questions with multiple choice options.\n\n\
Use this tool when you need to:\n\
- Get user preferences or choices\n\
- Clarify requirements before proceeding\n\
- Present options for the user to select from\n\
- Get approval for a plan or action\n\n\
The user will see a question sheet with selectable options. Questions can be single-select \
(choose one) or multi-select (choose multiple). You can also allow free-form \"Other\" input.\n\n\
Rules:\n\
- Maximum 5 questions per call\n\
- Each question must have at least 2 options\n\
- Question IDs must be unique within the call\n\n\
IMPORTANT: When using this tool, do NOT output any text response after calling it. \
The question tool should be the FINAL action in your response.",
        )
        .required_property("questions", json!({
            "type": "array",
            "description": "Array of questions (1-5) with options",
            "items": {
                "type": "object",
                "properties": {
                    "id": {"type": "string"},
                    "question": {"type": "string"},
                    "options": {
                        "type": "array",
                        "items": {
                            "type": "object",
                            "properties": {
                                "label": {"type": "string", "description": "Display text for this option"},
                                "value": {"type": "string", "description": "Optional value (defaults to label)"},
                                "description": {"type": "string", "description": "Optional explanation of this option"}
                            },
                            "required": ["label"]
                        }
                    },
                    "mode": {"type": "string", "enum": ["single", "multi"]},
                    "allowOther": {"type": "boolean", "description": "Whether to allow a free-text 'Other' option"},
                    "otherPlaceholder": {"type": "string", "description": "Placeholder text for the Other input"}
                }
            }
        }))
        .property("context", json!({"type": "string", "description": "Additional context for the questions"}))
        .build()
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
            return Ok(error_result(format!(
                "Maximum {MAX_QUESTIONS} questions allowed"
            )));
        }

        // Validate each question has enough options and all have labels
        for (i, q) in questions.iter().enumerate() {
            let options = q.get("options").and_then(Value::as_array);
            if let Some(opts) = options {
                if opts.len() < MIN_OPTIONS {
                    return Ok(error_result(format!(
                        "Question {} must have at least {MIN_OPTIONS} options",
                        i + 1
                    )));
                }
                // Validate that object options have a "label" field
                for (j, opt) in opts.iter().enumerate() {
                    if opt.is_object() && opt.get("label").and_then(Value::as_str).is_none() {
                        return Ok(error_result(format!(
                            "Question {} option {} is missing required 'label' field",
                            i + 1,
                            j + 1
                        )));
                    }
                }
            }
        }

        let context = get_optional_string(&params, "context");

        // Slim acknowledgement — the LLM already sees the full questions+options
        // in its own tool_use args. Echoing them here was pure redundancy and
        // the upstream source of memory-retain transcript pollution.
        let summary = format!(
            "Posted {} question(s) to user. Awaiting response.",
            questions.len()
        );

        Ok(TronToolResult {
            content: ToolResultBody::Blocks(vec![crate::core::content::ToolResultContent::text(
                summary,
            )]),
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
    use crate::tools::testutil::{extract_text, make_ctx};

    #[tokio::test]
    async fn valid_questions_returns_stop_turn() {
        let tool = AskUserQuestionTool::new();
        let r = tool
            .execute(
                json!({
                    "questions": [{"question": "Pick one", "options": ["A", "B"]}]
                }),
                &make_ctx(),
            )
            .await
            .unwrap();
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
        let r = tool
            .execute(
                json!({
                    "questions": [{"question": "Choose", "options": ["X", "Y"]}]
                }),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert!(r.is_error.is_none());
    }

    #[tokio::test]
    async fn max_questions() {
        let questions: Vec<Value> = (1..=5)
            .map(|i| json!({"question": format!("Q{i}"), "options": ["A", "B"]}))
            .collect();
        let tool = AskUserQuestionTool::new();
        let r = tool
            .execute(json!({"questions": questions}), &make_ctx())
            .await
            .unwrap();
        assert!(r.is_error.is_none());
    }

    #[tokio::test]
    async fn zero_questions_error() {
        let tool = AskUserQuestionTool::new();
        let r = tool
            .execute(json!({"questions": []}), &make_ctx())
            .await
            .unwrap();
        assert_eq!(r.is_error, Some(true));
    }

    #[tokio::test]
    async fn too_many_questions_error() {
        let questions: Vec<Value> = (1..=6)
            .map(|i| json!({"question": format!("Q{i}"), "options": ["A", "B"]}))
            .collect();
        let tool = AskUserQuestionTool::new();
        let r = tool
            .execute(json!({"questions": questions}), &make_ctx())
            .await
            .unwrap();
        assert_eq!(r.is_error, Some(true));
    }

    #[tokio::test]
    async fn too_few_options_error() {
        let tool = AskUserQuestionTool::new();
        let r = tool
            .execute(
                json!({
                    "questions": [{"question": "Q", "options": ["only one"]}]
                }),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert_eq!(r.is_error, Some(true));
    }

    #[tokio::test]
    async fn missing_questions_error() {
        let tool = AskUserQuestionTool::new();
        let r = tool.execute(json!({}), &make_ctx()).await.unwrap();
        assert_eq!(r.is_error, Some(true));
    }

    // ── Slim-result invariants (memory-retain pollution fix) ──
    //
    // The tool result text is intentionally minimal: just an acknowledgement
    // and the question count. Full question/option/context data stays in the
    // LLM's own `tool_use` args and in `details` JSON — echoing it here
    // polluted memory auto-retain transcripts.

    #[tokio::test]
    async fn result_is_slim_acknowledgement() {
        let tool = AskUserQuestionTool::new();
        let r = tool
            .execute(
                json!({
                    "questions": [{"question": "Pick one", "options": [{"label": "A"}, {"label": "B"}]}]
                }),
                &make_ctx(),
            )
            .await
            .unwrap();
        let text = extract_text(&r);
        assert_eq!(text, "Posted 1 question(s) to user. Awaiting response.");
    }

    #[tokio::test]
    async fn result_contains_question_count() {
        let tool = AskUserQuestionTool::new();
        let questions: Vec<Value> = (1..=3)
            .map(
                |i| json!({"question": format!("Q{i}"), "options": [{"label":"A"}, {"label":"B"}]}),
            )
            .collect();
        let r = tool
            .execute(json!({"questions": questions}), &make_ctx())
            .await
            .unwrap();
        let text = extract_text(&r);
        assert!(text.contains("3"), "expected count in text: {text}");
    }

    #[tokio::test]
    async fn result_does_not_leak_question_text() {
        let tool = AskUserQuestionTool::new();
        let r = tool
            .execute(
                json!({
                    "questions": [{"question": "What's your favorite color?", "options": [{"label":"A"},{"label":"B"}]}]
                }),
                &make_ctx(),
            )
            .await
            .unwrap();
        let text = extract_text(&r);
        assert!(
            !text.contains("favorite color"),
            "question text leaked: {text}"
        );
    }

    #[tokio::test]
    async fn result_does_not_leak_option_labels() {
        let tool = AskUserQuestionTool::new();
        let r = tool
            .execute(
                json!({
                    "questions": [{"question": "Pick", "options": [{"label": "Crimson"}, {"label": "Cerulean"}]}]
                }),
                &make_ctx(),
            )
            .await
            .unwrap();
        let text = extract_text(&r);
        assert!(!text.contains("Crimson"), "option label leaked: {text}");
        assert!(!text.contains("Cerulean"), "option label leaked: {text}");
    }

    #[tokio::test]
    async fn result_does_not_leak_context() {
        let tool = AskUserQuestionTool::new();
        let r = tool
            .execute(
                json!({
                    "questions": [{"question": "Q", "options": [{"label":"A"},{"label":"B"}]}],
                    "context": "ratification gate - should we proceed?"
                }),
                &make_ctx(),
            )
            .await
            .unwrap();
        let text = extract_text(&r);
        assert!(!text.contains("ratification"), "context leaked: {text}");
    }

    #[tokio::test]
    async fn details_preserve_question_count() {
        let tool = AskUserQuestionTool::new();
        let r = tool
            .execute(
                json!({
                    "questions": [
                        {"question": "Q1", "options": [{"label":"A"},{"label":"B"}]},
                        {"question": "Q2", "options": [{"label":"X"},{"label":"Y"}]}
                    ]
                }),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert_eq!(
            r.details
                .as_ref()
                .and_then(|d| d.get("questionCount"))
                .and_then(Value::as_u64),
            Some(2)
        );
    }

    #[tokio::test]
    async fn details_preserve_context_value() {
        let tool = AskUserQuestionTool::new();
        let r = tool
            .execute(
                json!({
                    "questions": [{"question": "Q", "options": [{"label":"A"},{"label":"B"}]}],
                    "context": "keep for retrieval"
                }),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert_eq!(
            r.details
                .as_ref()
                .and_then(|d| d.get("context"))
                .and_then(Value::as_str),
            Some("keep for retrieval")
        );
    }

    // ── Object options tests ──

    #[tokio::test]
    async fn object_options_accepted() {
        let tool = AskUserQuestionTool::new();
        let r = tool
            .execute(
                json!({
                    "questions": [{"question": "Pick", "options": [{"label": "A"}, {"label": "B"}]}]
                }),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert!(r.is_error.is_none());
    }

    #[tokio::test]
    async fn object_options_with_description() {
        let tool = AskUserQuestionTool::new();
        let r = tool.execute(json!({
            "questions": [{"question": "Pick", "options": [{"label": "A", "description": "desc"}, {"label": "B"}]}]
        }), &make_ctx()).await.unwrap();
        assert!(r.is_error.is_none());
    }

    #[tokio::test]
    async fn options_missing_label_error() {
        let tool = AskUserQuestionTool::new();
        let r = tool
            .execute(
                json!({
                    "questions": [{"question": "Pick", "options": [{"value": "x"}, {"label": "B"}]}]
                }),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert_eq!(r.is_error, Some(true));
    }

    #[test]
    fn schema_has_object_options() {
        let tool = AskUserQuestionTool::new();
        let def = tool.definition();
        let props = def.parameters.properties.unwrap();
        let questions = &props["questions"];
        let items = &questions["items"];
        let options_items = &items["properties"]["options"]["items"];
        assert_eq!(options_items["type"], "object");
        assert!(options_items["properties"]["label"].is_object());
    }

    #[test]
    fn schema_has_allow_other() {
        let tool = AskUserQuestionTool::new();
        let def = tool.definition();
        let props = def.parameters.properties.unwrap();
        let questions = &props["questions"];
        let items = &questions["items"];
        assert_eq!(items["properties"]["allowOther"]["type"], "boolean");
    }

    #[tokio::test]
    async fn string_options_accepted_without_error() {
        // Bare-string options are accepted (MIN_OPTIONS is about count, not shape).
        // Prior version also asserted they didn't leak into the slim text — now
        // implicit since the slim text contains no option data at all.
        let tool = AskUserQuestionTool::new();
        let r = tool
            .execute(
                json!({
                    "questions": [{"question": "Pick", "options": ["A", "B"]}]
                }),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert!(r.is_error.is_none());
    }
}
