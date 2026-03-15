//! `SearchContacts` tool — read-only contact lookup via iOS Contacts framework.

use std::sync::Arc;

use async_trait::async_trait;
use serde_json::{Value, json};
use crate::core::tools::{Tool, ToolCategory, ToolResultBody, TronToolResult};

use crate::tools::errors::ToolError;
use crate::tools::traits::{DeviceDelegate, ToolContext, TronTool};
use crate::tools::utils::schema::ToolSchemaBuilder;
use crate::tools::utils::validation::validate_required_string;

/// Read-only contact lookup via iOS Contacts framework.
pub struct SearchContactsTool {
    delegate: Arc<dyn DeviceDelegate>,
}

impl SearchContactsTool {
    /// Create a new contacts search tool with the given device delegate.
    pub fn new(delegate: Arc<dyn DeviceDelegate>) -> Self {
        Self { delegate }
    }
}

#[async_trait]
impl TronTool for SearchContactsTool {
    fn name(&self) -> &str {
        "SearchContacts"
    }

    fn category(&self) -> ToolCategory {
        ToolCategory::Custom
    }

    fn is_interactive(&self) -> bool {
        true
    }

    fn definition(&self) -> Tool {
        ToolSchemaBuilder::new(
            "SearchContacts",
            "Search the user's contacts on their iOS device.\n\n\
             Returns matching contacts with name, phone numbers, emails, and organization. \
             Read-only — no contacts are modified. Requires contacts permission on the device.",
        )
        .required_property(
            "query",
            json!({"type": "string", "description": "Search query (name, organization)"}),
        )
        .property(
            "limit",
            json!({"type": "number", "description": "Maximum results to return (default 10, max 50)"}),
        )
        .build()
    }

    async fn execute(&self, params: Value, ctx: &ToolContext) -> Result<TronToolResult, ToolError> {
        let query = match validate_required_string(&params, "query", "search query") {
            Ok(q) => q,
            Err(e) => return Ok(e),
        };

        let limit = params
            .get("limit")
            .and_then(serde_json::Value::as_u64)
            .unwrap_or(10)
            .min(50);

        let result = self
            .delegate
            .device_request(
                &ctx.session_id,
                "contacts.search",
                json!({"query": query, "limit": limit}),
            )
            .await?;

        // Include data in content so the LLM can see it (details is metadata-only)
        let content = serde_json::to_string_pretty(&result).unwrap_or_default();

        Ok(TronToolResult {
            content: ToolResultBody::Blocks(vec![crate::core::content::ToolResultContent::text(
                &content,
            )]),
            details: Some(json!({
                "query": query,
            })),
            is_error: None,
            stop_turn: None,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::tools::testutil::{extract_text, make_ctx};
    use std::sync::Mutex;

    struct MockDeviceDelegate {
        last_session_id: Mutex<Option<String>>,
        last_params: Mutex<Option<Value>>,
        response: Value,
    }

    impl MockDeviceDelegate {
        fn with_response(response: Value) -> Self {
            Self {
                last_session_id: Mutex::new(None),
                last_params: Mutex::new(None),
                response,
            }
        }
    }

    #[async_trait]
    impl DeviceDelegate for MockDeviceDelegate {
        async fn device_request(
            &self,
            session_id: &str,
            _method: &str,
            params: Value,
        ) -> Result<Value, ToolError> {
            *self.last_session_id.lock().unwrap() = Some(session_id.to_string());
            *self.last_params.lock().unwrap() = Some(params);
            Ok(self.response.clone())
        }
    }

    #[tokio::test]
    async fn search_contacts() {
        let delegate = Arc::new(MockDeviceDelegate::with_response(json!([
            {"givenName": "John", "familyName": "Smith", "phones": [{"label": "mobile", "number": "+1234567890"}]}
        ])));
        let tool = SearchContactsTool::new(delegate);
        let r = tool
            .execute(json!({"query": "John"}), &make_ctx())
            .await
            .unwrap();
        let text = extract_text(&r);
        assert!(text.contains("John"), "should contain contact data: {text}");
    }

    #[tokio::test]
    async fn no_results() {
        let delegate = Arc::new(MockDeviceDelegate::with_response(json!([])));
        let tool = SearchContactsTool::new(delegate);
        let r = tool
            .execute(json!({"query": "Nobody"}), &make_ctx())
            .await
            .unwrap();
        assert!(
            extract_text(&r).contains("[]"),
            "empty array for no results"
        );
    }

    #[tokio::test]
    async fn missing_query_error() {
        let delegate = Arc::new(MockDeviceDelegate::with_response(json!([])));
        let tool = SearchContactsTool::new(delegate);
        let r = tool.execute(json!({}), &make_ctx()).await.unwrap();
        assert_eq!(r.is_error, Some(true));
    }

    #[tokio::test]
    async fn limit_capped_at_50() {
        let delegate = Arc::new(MockDeviceDelegate::with_response(json!([])));
        let tool = SearchContactsTool::new(delegate.clone());
        let _ = tool
            .execute(json!({"query": "test", "limit": 100}), &make_ctx())
            .await
            .unwrap();
        assert_eq!(
            *delegate.last_session_id.lock().unwrap(),
            Some("sess-1".into())
        );
        let params = delegate.last_params.lock().unwrap().clone().unwrap();
        assert_eq!(params["limit"], 50);
    }

    #[tokio::test]
    async fn tool_metadata() {
        let delegate = Arc::new(MockDeviceDelegate::with_response(json!([])));
        let tool = SearchContactsTool::new(delegate);
        assert_eq!(tool.name(), "SearchContacts");
        assert!(tool.is_interactive());
    }
}
