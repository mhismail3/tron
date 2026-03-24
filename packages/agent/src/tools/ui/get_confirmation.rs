//! `GetConfirmation` tool — permission gate for dangerous or irreversible actions.
//!
//! Presents an approve/deny confirmation to the user with action description,
//! reason, and risk level. Interactive and turn-stopping: execution returns
//! immediately and the user's decision arrives as the next prompt.

use async_trait::async_trait;
use serde_json::{Value, json};
use crate::core::tools::{Tool, ToolCategory, ToolResultBody, TronToolResult, error_result};

use crate::tools::errors::ToolError;
use crate::tools::traits::{ToolContext, TronTool};
use crate::tools::utils::schema::ToolSchemaBuilder;
use crate::tools::utils::validation::validate_required_string;

const VALID_RISK_LEVELS: &[&str] = &["low", "medium", "high"];

/// The `GetConfirmation` tool requests user approval for dangerous actions.
pub struct GetConfirmationTool;

impl GetConfirmationTool {
    /// Create a new `GetConfirmation` tool.
    pub fn new() -> Self {
        Self
    }
}

impl Default for GetConfirmationTool {
    fn default() -> Self {
        Self::new()
    }
}

#[async_trait]
impl TronTool for GetConfirmationTool {
    fn name(&self) -> &str {
        "GetConfirmation"
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
            "GetConfirmation",
            "Request user approval before performing a dangerous, irreversible, or externally-visible action.\n\n\
             Use this tool when you need to:\n\
             - Delete files outside of scratch/temp directories\n\
             - Send emails, messages, or make external API calls\n\
             - Deploy code or restart services\n\
             - Modify system configuration\n\
             - Install packages or tools on the host\n\
             - Any action that cannot be easily undone\n\n\
             The user will see the action description, your reason for needing approval, and a risk level badge. \
             They can approve or deny, optionally with a note.\n\n\
             IMPORTANT: When using this tool, do NOT output any text response after calling it. \
             The confirmation request should be the FINAL action in your response.",
        )
        .required_property("action", json!({
            "type": "string",
            "description": "What you want to do (e.g., 'Install ffmpeg via brew', 'Delete ~/old-project/')"
        }))
        .required_property("reason", json!({
            "type": "string",
            "description": "Why this action requires approval"
        }))
        .required_property("riskLevel", json!({
            "type": "string",
            "enum": ["low", "medium", "high"],
            "description": "Risk level: low (installing a package), medium (modifying config), high (deploying, sending external comms)"
        }))
        .build()
    }

    async fn execute(
        &self,
        params: Value,
        _ctx: &ToolContext,
    ) -> Result<TronToolResult, ToolError> {
        let action = match validate_required_string(&params, "action", "action description") {
            Ok(a) => a,
            Err(e) => return Ok(e),
        };

        let reason = match validate_required_string(&params, "reason", "reason for approval") {
            Ok(r) => r,
            Err(e) => return Ok(e),
        };

        let risk_level = match validate_required_string(&params, "riskLevel", "risk level") {
            Ok(r) => r,
            Err(e) => return Ok(e),
        };

        if !VALID_RISK_LEVELS.contains(&risk_level.as_str()) {
            return Ok(error_result(format!(
                "Invalid riskLevel '{}'. Must be one of: low, medium, high",
                risk_level
            )));
        }

        let summary = format!(
            "Requesting confirmation:\n  Action: {action}\n  Reason: {reason}\n  Risk: {risk_level}"
        );

        Ok(TronToolResult {
            content: ToolResultBody::Blocks(vec![crate::core::content::ToolResultContent::text(
                &summary,
            )]),
            details: Some(json!({
                "action": action,
                "reason": reason,
                "riskLevel": risk_level,
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

    #[test]
    fn tool_metadata() {
        let tool = GetConfirmationTool::new();
        assert_eq!(tool.name(), "GetConfirmation");
        assert!(tool.is_interactive());
        assert!(tool.stops_turn());
    }

    #[test]
    fn schema_has_required_fields() {
        let tool = GetConfirmationTool::new();
        let def = tool.definition();
        let required = def.parameters.required.unwrap();
        assert!(required.contains(&"action".to_string()));
        assert!(required.contains(&"reason".to_string()));
        assert!(required.contains(&"riskLevel".to_string()));
    }

    #[test]
    fn schema_risk_level_enum() {
        let tool = GetConfirmationTool::new();
        let def = tool.definition();
        let props = def.parameters.properties.unwrap();
        let risk = &props["riskLevel"];
        let variants = risk["enum"].as_array().unwrap();
        assert_eq!(variants.len(), 3);
        assert!(variants.contains(&json!("low")));
        assert!(variants.contains(&json!("medium")));
        assert!(variants.contains(&json!("high")));
    }

    #[tokio::test]
    async fn valid_confirmation_returns_stop_turn() {
        let tool = GetConfirmationTool::new();
        let r = tool
            .execute(
                json!({
                    "action": "Install ffmpeg via brew",
                    "reason": "Needed for video processing task",
                    "riskLevel": "low"
                }),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert_eq!(r.stop_turn, Some(true));
        assert!(r.is_error.is_none());
    }

    #[tokio::test]
    async fn summary_contains_action_and_risk() {
        let tool = GetConfirmationTool::new();
        let r = tool
            .execute(
                json!({
                    "action": "Delete ~/old-project/",
                    "reason": "User requested cleanup",
                    "riskLevel": "high"
                }),
                &make_ctx(),
            )
            .await
            .unwrap();
        let text = extract_text(&r);
        assert!(text.contains("Delete ~/old-project/"), "missing action: {text}");
        assert!(text.contains("high"), "missing risk level: {text}");
    }

    #[tokio::test]
    async fn missing_action_returns_error() {
        let tool = GetConfirmationTool::new();
        let r = tool
            .execute(
                json!({
                    "reason": "test",
                    "riskLevel": "low"
                }),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert_eq!(r.is_error, Some(true));
    }

    #[tokio::test]
    async fn missing_reason_returns_error() {
        let tool = GetConfirmationTool::new();
        let r = tool
            .execute(
                json!({
                    "action": "test",
                    "riskLevel": "low"
                }),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert_eq!(r.is_error, Some(true));
    }

    #[tokio::test]
    async fn missing_risk_level_returns_error() {
        let tool = GetConfirmationTool::new();
        let r = tool
            .execute(
                json!({
                    "action": "test",
                    "reason": "test"
                }),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert_eq!(r.is_error, Some(true));
    }

    #[tokio::test]
    async fn invalid_risk_level_returns_error() {
        let tool = GetConfirmationTool::new();
        let r = tool
            .execute(
                json!({
                    "action": "test",
                    "reason": "test",
                    "riskLevel": "extreme"
                }),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert_eq!(r.is_error, Some(true));
        let text = extract_text(&r);
        assert!(text.contains("Invalid riskLevel"), "expected validation error: {text}");
    }

    #[tokio::test]
    async fn details_contain_structured_data() {
        let tool = GetConfirmationTool::new();
        let r = tool
            .execute(
                json!({
                    "action": "Deploy to prod",
                    "reason": "Release v2.0",
                    "riskLevel": "high"
                }),
                &make_ctx(),
            )
            .await
            .unwrap();
        let details = r.details.unwrap();
        assert_eq!(details["action"], "Deploy to prod");
        assert_eq!(details["reason"], "Release v2.0");
        assert_eq!(details["riskLevel"], "high");
    }

    #[tokio::test]
    async fn all_risk_levels_accepted() {
        let tool = GetConfirmationTool::new();
        for level in ["low", "medium", "high"] {
            let r = tool
                .execute(
                    json!({
                        "action": "test",
                        "reason": "test",
                        "riskLevel": level
                    }),
                    &make_ctx(),
                )
                .await
                .unwrap();
            assert!(r.is_error.is_none(), "risk level '{level}' should be valid");
        }
    }

    #[tokio::test]
    async fn empty_params_returns_error() {
        let tool = GetConfirmationTool::new();
        let r = tool.execute(json!({}), &make_ctx()).await.unwrap();
        assert_eq!(r.is_error, Some(true));
    }
}
