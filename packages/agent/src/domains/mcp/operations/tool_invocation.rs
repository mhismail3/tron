//! MCP workflow operations.
use super::{InProcessFunctionHandler, async_trait, mcp_result_to_tron_result};
use crate::domains::mcp::Deps;
use crate::engine::Invocation;
use serde_json::Value;
use serde_json::json;

pub(crate) struct McpToolFunctionHandler {
    pub(crate) server: String,
    pub(crate) tool: String,
    pub(crate) deps: Deps,
}

#[async_trait]
impl InProcessFunctionHandler for McpToolFunctionHandler {
    async fn invoke(&self, invocation: Invocation) -> Result<Value, crate::engine::EngineError> {
        let router = self.deps.mcp_router.as_ref().ok_or_else(|| {
            crate::engine::EngineError::HandlerFailed(
                "MCP is not configured on this server".to_owned(),
            )
        })?;
        let mut guard = router.write().await;
        let result = guard
            .call(&self.server, &self.tool, invocation.payload)
            .await
            .map_err(|error| crate::engine::EngineError::DomainFailure {
                domain: "mcp".to_owned(),
                code: "MCP_TOOL_ERROR".to_owned(),
                message: error.to_string(),
                details: Some(json!({
                    "server": self.server,
                    "tool": self.tool,
                })),
            })?;
        let tron_result = mcp_result_to_tron_result(&result, &self.server, &self.tool);
        serde_json::to_value(tron_result).map_err(|error| {
            crate::engine::EngineError::HandlerFailed(format!(
                "failed to serialize MCP capability result: {error}"
            ))
        })
    }
}

#[cfg(test)]
mod tests {
    use crate::domains::mcp::operations::classify_mcp_tool;
    use crate::engine::{EffectClass, RiskLevel};

    #[test]
    fn classifier_marks_obvious_reads_as_low_risk_pure_reads() {
        let classification = classify_mcp_tool("list_projects", "List project metadata");
        assert_eq!(classification.effect_class, EffectClass::PureRead);
        assert_eq!(classification.risk_level, RiskLevel::Low);
        assert_eq!(classification.authority_scope, "mcp.read");
        assert!(!classification.approval_required);
        assert!(classification.confidence >= 0.6);
    }

    #[test]
    fn classifier_marks_mutation_words_as_approval_required_side_effects() {
        let classification = classify_mcp_tool("send_email", "Send a message to a recipient");
        assert_eq!(classification.effect_class, EffectClass::ExternalSideEffect);
        assert_eq!(classification.risk_level, RiskLevel::Medium);
        assert_eq!(classification.authority_scope, "mcp.write");
        assert!(classification.approval_required);
        assert_eq!(
            classification.reason,
            "name_or_description_implies_external_mutation"
        );
    }

    #[test]
    fn classifier_defaults_unknown_tools_to_conservative_side_effects() {
        let classification = classify_mcp_tool("frobnicate", "Perform the server operation");
        assert_eq!(classification.effect_class, EffectClass::ExternalSideEffect);
        assert_eq!(classification.risk_level, RiskLevel::Medium);
        assert_eq!(classification.authority_scope, "mcp.write");
        assert!(classification.approval_required);
        assert_eq!(
            classification.reason,
            "unknown_mcp_tool_defaults_to_safe_external_side_effect"
        );
    }
}
