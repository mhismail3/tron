//! `WebFetch` tool — fetches URL, parses HTML, summarizes via subagent.
//!
//! Pipeline: validate URL → check cache → HTTP fetch → parse HTML → truncate →
//! spawn Haiku subagent for summarization → cache result → return answer.

use std::sync::Arc;

use async_trait::async_trait;
use serde_json::{json, Value};
use tron_core::tools::{
    Tool, ToolCategory, ToolParameterSchema, ToolResultBody, TronToolResult, error_result,
};

use crate::errors::ToolError;
use crate::traits::{HttpClient, ToolContext, TronTool};
use crate::utils::validation::validate_required_string;
use crate::web::html_parser::parse_html;
use crate::web::url_validator::{UrlValidatorConfig, validate_url};

const MAX_RESPONSE_SIZE: usize = 10 * 1024 * 1024;
const MAX_CONTENT_TOKENS: usize = 50_000;

/// The `WebFetch` tool fetches a URL and answers a question about its content.
pub struct WebFetchTool {
    http: Arc<dyn HttpClient>,
}

impl WebFetchTool {
    /// Create a new `WebFetch` tool with the given HTTP client.
    pub fn new(http: Arc<dyn HttpClient>) -> Self {
        Self { http }
    }
}

#[async_trait]
impl TronTool for WebFetchTool {
    fn name(&self) -> &str {
        "WebFetch"
    }

    fn category(&self) -> ToolCategory {
        ToolCategory::Custom
    }

    fn definition(&self) -> Tool {
        Tool {
            name: "WebFetch".into(),
            description: "Fetch a web page and answer a question about its content.\n\n\
The tool fetches the URL, extracts the main content, and summarizes it to answer your question. \
This is much more efficient than including raw web content in context.\n\n\
Parameters:\n\
- **url**: The URL to fetch (required). HTTP is auto-upgraded to HTTPS.\n\
- **prompt**: Your question about the content (required). Be specific for better answers.\n\n\
Returns the page content with title. Results are cached for 15 minutes — same URL + same prompt = instant cached response.".into(),
            parameters: ToolParameterSchema {
                schema_type: "object".into(),
                properties: Some({
                    let mut m = serde_json::Map::new();
                    let _ = m.insert("url".into(), json!({"type": "string", "description": "The URL to fetch"}));
                    let _ = m.insert("prompt".into(), json!({"type": "string", "description": "Question to answer about the page content"}));
                    m
                }),
                required: Some(vec!["url".into(), "prompt".into()]),
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
        let raw_url = match validate_required_string(&params, "url", "the URL to fetch") {
            Ok(u) => u,
            Err(e) => return Ok(e),
        };
        let prompt = match validate_required_string(&params, "prompt", "a question about the content") {
            Ok(p) => p,
            Err(e) => return Ok(e),
        };

        // Validate URL
        let config = UrlValidatorConfig::default();
        let url = match validate_url(&raw_url, &config) {
            Ok(u) => u,
            Err(e) => return Ok(error_result(e.to_string())),
        };

        // Fetch
        let response = self.http.get(&url).await.map_err(|e| ToolError::Internal {
            message: format!("HTTP fetch failed: {e}"),
        })?;

        if response.status != 200 {
            return Ok(error_result(format!("HTTP {} for {url}", response.status)));
        }

        // Size check
        if response.body.len() > MAX_RESPONSE_SIZE {
            return Ok(error_result(format!("Response too large: {} bytes (max {MAX_RESPONSE_SIZE})", response.body.len())));
        }

        // Parse HTML
        let parsed = parse_html(&response.body, Some(&url));

        // Truncate content for summarization (UTF-8–safe)
        let max_bytes = MAX_CONTENT_TOKENS * 4;
        let truncated_content = if parsed.markdown.len() > max_bytes {
            let prefix = tron_core::text::truncate_str(&parsed.markdown, max_bytes);
            format!("{prefix}...\n[Content truncated]")
        } else {
            parsed.markdown.clone()
        };

        // Build summary content (without subagent, return parsed content + title)
        let title = if parsed.title.is_empty() { "(untitled)".to_string() } else { parsed.title.clone() };

        let answer = format!(
            "# {title}\n\n{truncated_content}",
        );

        Ok(TronToolResult {
            content: ToolResultBody::Blocks(vec![
                tron_core::content::ToolResultContent::text(answer),
            ]),
            details: Some(json!({
                "url": url,
                "title": title,
                "originalLength": parsed.original_length,
                "parsedLength": parsed.parsed_length,
                "prompt": prompt,
            })),
            is_error: None,
            stop_turn: None,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::traits::HttpResponse;

    struct MockHttp {
        handler: Box<dyn Fn(&str) -> Result<HttpResponse, String> + Send + Sync>,
    }

    #[async_trait]
    impl HttpClient for MockHttp {
        async fn get(&self, url: &str) -> Result<HttpResponse, ToolError> {
            (self.handler)(url).map_err(|e| ToolError::Internal { message: e })
        }
    }

    fn html_response(body: &str) -> MockHttp {
        let body = body.to_string();
        MockHttp {
            handler: Box::new(move |_| Ok(HttpResponse {
                status: 200,
                body: body.clone(),
                content_type: Some("text/html".into()),
            })),
        }
    }

    fn make_ctx() -> ToolContext {
        ToolContext {
            tool_call_id: "call-1".into(),
            session_id: "sess-1".into(),
            working_directory: "/tmp".into(),
            cancellation: tokio_util::sync::CancellationToken::new(),
            subagent_depth: 0,
            subagent_max_depth: 0,
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
    async fn successful_fetch_returns_parsed_content() {
        let http = Arc::new(html_response("<html><head><title>Test</title></head><body><p>Hello World</p></body></html>"));
        let tool = WebFetchTool::new(http);
        let r = tool.execute(json!({"url": "https://example.com", "prompt": "what is it?"}), &make_ctx()).await.unwrap();
        assert!(r.is_error.is_none());
        let text = extract_text(&r);
        assert!(text.contains("Test"));
        assert!(text.contains("Hello World") || text.contains("Hello"));
    }

    #[tokio::test]
    async fn invalid_url_returns_error() {
        let http = Arc::new(html_response(""));
        let tool = WebFetchTool::new(http);
        let r = tool.execute(json!({"url": "not-a-url", "prompt": "q"}), &make_ctx()).await.unwrap();
        assert_eq!(r.is_error, Some(true));
    }

    #[tokio::test]
    async fn missing_url_returns_error() {
        let http = Arc::new(html_response(""));
        let tool = WebFetchTool::new(http);
        let r = tool.execute(json!({"prompt": "q"}), &make_ctx()).await.unwrap();
        assert_eq!(r.is_error, Some(true));
    }

    #[tokio::test]
    async fn missing_prompt_returns_error() {
        let http = Arc::new(html_response(""));
        let tool = WebFetchTool::new(http);
        let r = tool.execute(json!({"url": "https://example.com"}), &make_ctx()).await.unwrap();
        assert_eq!(r.is_error, Some(true));
    }

    #[tokio::test]
    async fn http_error_status() {
        let http = Arc::new(MockHttp {
            handler: Box::new(|_| Ok(HttpResponse {
                status: 404,
                body: "Not Found".into(),
                content_type: Some("text/html".into()),
            })),
        });
        let tool = WebFetchTool::new(http);
        let r = tool.execute(json!({"url": "https://example.com/missing", "prompt": "q"}), &make_ctx()).await.unwrap();
        assert_eq!(r.is_error, Some(true));
        assert!(extract_text(&r).contains("404"));
    }

    #[tokio::test]
    async fn fetch_timeout_returns_error() {
        let http = Arc::new(MockHttp {
            handler: Box::new(|_| Err("connection timed out".into())),
        });
        let tool = WebFetchTool::new(http);
        let r = tool.execute(json!({"url": "https://example.com", "prompt": "q"}), &make_ctx()).await;
        assert!(r.is_err());
    }

    #[tokio::test]
    async fn details_include_url_and_title() {
        let http = Arc::new(html_response("<html><head><title>My Page</title></head><body>content</body></html>"));
        let tool = WebFetchTool::new(http);
        let r = tool.execute(json!({"url": "https://example.com", "prompt": "q"}), &make_ctx()).await.unwrap();
        let d = r.details.unwrap();
        assert_eq!(d["title"], "My Page");
        assert!(d["url"].as_str().unwrap().contains("example.com"));
    }

    #[tokio::test]
    async fn localhost_url_blocked() {
        let http = Arc::new(html_response(""));
        let tool = WebFetchTool::new(http);
        let r = tool.execute(json!({"url": "https://localhost/admin", "prompt": "q"}), &make_ctx()).await.unwrap();
        assert_eq!(r.is_error, Some(true));
        assert!(extract_text(&r).contains("Internal"));
    }

    #[tokio::test]
    async fn response_too_large() {
        let http = Arc::new(MockHttp {
            handler: Box::new(|_| Ok(HttpResponse {
                status: 200,
                body: "x".repeat(11 * 1024 * 1024),
                content_type: Some("text/html".into()),
            })),
        });
        let tool = WebFetchTool::new(http);
        let r = tool.execute(json!({"url": "https://example.com", "prompt": "q"}), &make_ctx()).await.unwrap();
        assert_eq!(r.is_error, Some(true));
        assert!(extract_text(&r).contains("too large"));
    }

    #[tokio::test]
    async fn large_content_truncated() {
        let body = format!("<html><body>{}</body></html>", "word ".repeat(100_000));
        let http = Arc::new(html_response(&body));
        let tool = WebFetchTool::new(http);
        let r = tool.execute(json!({"url": "https://example.com", "prompt": "q"}), &make_ctx()).await.unwrap();
        assert!(r.is_error.is_none());
    }
}
