use async_trait::async_trait;
use std::time::Instant;
use tron_core::tools::{ContentType, ExecutionMode, Tool, ToolContext, ToolError, ToolResult};

const BRAVE_SEARCH_URL: &str = "https://api.search.brave.com/res/v1/web/search";

pub struct WebSearchTool {
    client: reqwest::Client,
    api_key: Option<String>,
}

impl Default for WebSearchTool {
    fn default() -> Self {
        Self::new()
    }
}

impl WebSearchTool {
    pub fn new() -> Self {
        let api_key = std::env::var("BRAVE_SEARCH_API_KEY").ok();
        let client = reqwest::Client::builder()
            .timeout(std::time::Duration::from_secs(15))
            .user_agent("Tron/1.0")
            .build()
            .unwrap_or_default();
        Self { client, api_key }
    }

    pub fn with_api_key(api_key: String) -> Self {
        let client = reqwest::Client::builder()
            .timeout(std::time::Duration::from_secs(15))
            .user_agent("Tron/1.0")
            .build()
            .unwrap_or_default();
        Self {
            client,
            api_key: Some(api_key),
        }
    }
}

#[async_trait]
impl Tool for WebSearchTool {
    fn name(&self) -> &str {
        "WebSearch"
    }

    fn description(&self) -> &str {
        "Search the web for information"
    }

    fn parameters_schema(&self) -> serde_json::Value {
        serde_json::json!({
            "type": "object",
            "required": ["query"],
            "properties": {
                "query": {
                    "type": "string",
                    "description": "The search query"
                },
                "count": {
                    "type": "integer",
                    "description": "Number of results (default: 5, max: 20)"
                }
            }
        })
    }

    fn execution_mode(&self) -> ExecutionMode {
        ExecutionMode::Concurrent
    }

    async fn execute(
        &self,
        args: serde_json::Value,
        _ctx: &ToolContext,
    ) -> Result<ToolResult, ToolError> {
        let start = Instant::now();

        let query = args["query"]
            .as_str()
            .ok_or_else(|| ToolError::InvalidArguments("query is required".into()))?;

        let api_key = self.api_key.as_deref().ok_or_else(|| {
            ToolError::ExecutionFailed(
                "BRAVE_SEARCH_API_KEY not set. Web search requires an API key.".into(),
            )
        })?;

        let count = args["count"].as_u64().unwrap_or(5).min(20);

        let response = self
            .client
            .get(BRAVE_SEARCH_URL)
            .header("X-Subscription-Token", api_key)
            .header("Accept", "application/json")
            .query(&[("q", query), ("count", &count.to_string())])
            .send()
            .await
            .map_err(|e| ToolError::ExecutionFailed(format!("Search request failed: {e}")))?;

        let status = response.status();
        if !status.is_success() {
            let body = response.text().await.unwrap_or_default();
            return Ok(ToolResult {
                content: format!("Search failed: HTTP {status}: {body}"),
                is_error: true,
                content_type: ContentType::Text,
                duration: start.elapsed(),
            });
        }

        let body: serde_json::Value = response
            .json()
            .await
            .map_err(|e| ToolError::ExecutionFailed(format!("Failed to parse response: {e}")))?;

        let results = format_search_results(&body);

        Ok(ToolResult {
            content: results,
            is_error: false,
            content_type: ContentType::Text,
            duration: start.elapsed(),
        })
    }
}

fn format_search_results(body: &serde_json::Value) -> String {
    let mut output = String::new();

    if let Some(results) = body["web"]["results"].as_array() {
        for (i, result) in results.iter().enumerate() {
            let title = result["title"].as_str().unwrap_or("(untitled)");
            let url = result["url"].as_str().unwrap_or("");
            let description = result["description"].as_str().unwrap_or("");

            output.push_str(&format!("{}. [{}]({})\n", i + 1, title, url));
            if !description.is_empty() {
                output.push_str(&format!("   {description}\n"));
            }
            output.push('\n');
        }
    }

    if output.is_empty() {
        output = "No search results found.".to_string();
    }

    output
}

#[cfg(test)]
mod tests {
    use super::*;
    use tron_core::ids::{AgentId, SessionId};
    use tokio_util::sync::CancellationToken;

    fn test_ctx() -> ToolContext {
        ToolContext {
            session_id: SessionId::new(),
            working_directory: std::env::temp_dir(),
            agent_id: AgentId::new(),
            parent_agent_id: None,
            abort_signal: CancellationToken::new(),
        }
    }

    #[test]
    fn tool_metadata() {
        let tool = WebSearchTool::new();
        assert_eq!(tool.name(), "WebSearch");
        assert_eq!(tool.execution_mode(), ExecutionMode::Concurrent);

        let schema = tool.parameters_schema();
        let required = schema["required"].as_array().unwrap();
        assert!(required.iter().any(|v| v == "query"));
    }

    #[tokio::test]
    async fn missing_query() {
        let tool = WebSearchTool::with_api_key("test".into());
        let result = tool.execute(serde_json::json!({}), &test_ctx()).await;
        assert!(result.is_err());
    }

    #[tokio::test]
    async fn missing_api_key() {
        let tool = WebSearchTool {
            client: reqwest::Client::new(),
            api_key: None,
        };
        let result = tool
            .execute(serde_json::json!({"query": "test"}), &test_ctx())
            .await;
        assert!(result.is_err());
    }

    #[test]
    fn format_results_empty() {
        let body = serde_json::json!({"web": {"results": []}});
        assert_eq!(format_search_results(&body), "No search results found.");
    }

    #[test]
    fn format_results_with_data() {
        let body = serde_json::json!({
            "web": {
                "results": [
                    {"title": "Rust Lang", "url": "https://rust-lang.org", "description": "A systems programming language"},
                    {"title": "Crates.io", "url": "https://crates.io", "description": "Rust package registry"}
                ]
            }
        });
        let output = format_search_results(&body);
        assert!(output.contains("Rust Lang"));
        assert!(output.contains("https://rust-lang.org"));
        assert!(output.contains("Crates.io"));
    }
}
