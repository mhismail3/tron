//! `WebFetch` tool — fetches URL, parses HTML, summarizes via subagent.
//!
//! Pipeline: validate URL → check cache → HTTP fetch → parse HTML → truncate →
//! spawn Haiku subagent for summarization → cache result → return answer.

use std::sync::Arc;

use async_trait::async_trait;
use parking_lot::Mutex;
use serde_json::{json, Value};
use tron_core::tools::{
    Tool, ToolCategory, ToolParameterSchema, ToolResultBody, TronToolResult, error_result,
};

use crate::errors::ToolError;
use crate::traits::{ContentSummarizer, HttpClient, ToolContext, TronTool};
use crate::utils::validation::validate_required_string;
use crate::web::cache::{CachedResult, WebCache, WebCacheConfig};
use crate::web::html_parser::parse_html;
use crate::web::url_validator::{UrlValidatorConfig, validate_url};

const MAX_RESPONSE_SIZE: usize = 10 * 1024 * 1024;
const MAX_CONTENT_TOKENS: usize = 50_000;

/// The `WebFetch` tool fetches a URL and answers a question about its content.
pub struct WebFetchTool {
    http: Arc<dyn HttpClient>,
    summarizer: Option<Arc<dyn ContentSummarizer>>,
    cache: Mutex<WebCache>,
}

impl WebFetchTool {
    /// Create a new `WebFetch` tool with the given HTTP client (no summarizer).
    pub fn new(http: Arc<dyn HttpClient>) -> Self {
        Self {
            http,
            summarizer: None,
            cache: Mutex::new(WebCache::new(WebCacheConfig::default())),
        }
    }

    /// Create a `WebFetch` tool with an LLM summarizer for concise answers.
    pub fn new_with_summarizer(
        http: Arc<dyn HttpClient>,
        summarizer: Arc<dyn ContentSummarizer>,
    ) -> Self {
        Self {
            http,
            summarizer: Some(summarizer),
            cache: Mutex::new(WebCache::new(WebCacheConfig::default())),
        }
    }
}

/// Build the task prompt sent to the summarizer subagent.
fn build_summarizer_task(prompt: &str, title: &str, content: &str) -> String {
    format!(
        "Answer this question about the following web page content.\n\n\
         **Question**: {prompt}\n\
         **Page Title**: {title}\n\n\
         **Content**:\n\
         {content}\n\n\
         Instructions:\n\
         - Answer the question concisely based on the content provided\n\
         - If the content doesn't contain the answer, say so clearly\n\
         - Do not make up information not present in the content"
    )
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
        ctx: &ToolContext,
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

        // Check cache
        {
            let mut cache = self.cache.lock();
            if let Some(cached) = cache.get(&url, &prompt) {
                let cached = cached.clone();
                return Ok(TronToolResult {
                    content: ToolResultBody::Blocks(vec![
                        tron_core::content::ToolResultContent::text(&cached.answer),
                    ]),
                    details: Some(json!({
                        "url": cached.url,
                        "title": cached.title,
                        "prompt": prompt,
                        "fromCache": true,
                        "subagentSessionId": cached.subagent_session_id,
                    })),
                    is_error: None,
                    stop_turn: None,
                });
            }
        }

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

        let title = if parsed.title.is_empty() { "(untitled)".to_string() } else { parsed.title.clone() };

        // Summarize via subagent (or fall back to raw content)
        let (answer, subagent_session_id) = if let Some(ref summarizer) = self.summarizer {
            let task = build_summarizer_task(&prompt, &title, &truncated_content);
            match summarizer.summarize(&task, &ctx.session_id).await {
                Ok(result) => (result.answer, result.session_id),
                Err(_) => {
                    // Graceful fallback to raw content on summarizer failure
                    (format!("# {title}\n\n{truncated_content}"), String::new())
                }
            }
        } else {
            (format!("# {title}\n\n{truncated_content}"), String::new())
        };

        // Cache the result
        self.cache.lock().set(&url, &prompt, CachedResult {
            answer: answer.clone(),
            url: url.clone(),
            title: title.clone(),
            subagent_session_id: subagent_session_id.clone(),
        });

        Ok(TronToolResult {
            content: ToolResultBody::Blocks(vec![
                tron_core::content::ToolResultContent::text(&answer),
            ]),
            details: Some(json!({
                "url": url,
                "title": title,
                "originalLength": parsed.original_length,
                "parsedLength": parsed.parsed_length,
                "prompt": prompt,
                "fromCache": false,
                "subagentSessionId": subagent_session_id,
            })),
            is_error: None,
            stop_turn: None,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::traits::{HttpResponse, SummarizerResult};
    use std::sync::atomic::{AtomicUsize, Ordering};

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

    struct MockSummarizer {
        answer: String,
        call_count: AtomicUsize,
    }

    impl MockSummarizer {
        fn new(answer: &str) -> Self {
            Self {
                answer: answer.into(),
                call_count: AtomicUsize::new(0),
            }
        }

        fn calls(&self) -> usize {
            self.call_count.load(Ordering::Relaxed)
        }
    }

    #[async_trait]
    impl ContentSummarizer for MockSummarizer {
        async fn summarize(
            &self,
            _task: &str,
            _parent_session_id: &str,
        ) -> Result<SummarizerResult, ToolError> {
            self.call_count.fetch_add(1, Ordering::Relaxed);
            Ok(SummarizerResult {
                answer: self.answer.clone(),
                session_id: "sub-sess-1".into(),
            })
        }
    }

    struct FailingSummarizer;

    #[async_trait]
    impl ContentSummarizer for FailingSummarizer {
        async fn summarize(
            &self,
            _task: &str,
            _parent_session_id: &str,
        ) -> Result<SummarizerResult, ToolError> {
            Err(ToolError::Internal { message: "summarizer exploded".into() })
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

    // ─── Original tests (unchanged behavior) ─────────────────────────────

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

    // ─── New tests: summarizer + cache ───────────────────────────────────

    #[tokio::test]
    async fn summarizer_called_when_available() {
        let http = Arc::new(html_response("<html><head><title>Test</title></head><body><p>Hello</p></body></html>"));
        let summarizer = Arc::new(MockSummarizer::new("The page says Hello."));
        let tool = WebFetchTool::new_with_summarizer(http, summarizer.clone());
        let r = tool.execute(json!({"url": "https://example.com", "prompt": "what does it say?"}), &make_ctx()).await.unwrap();
        assert!(r.is_error.is_none());
        assert_eq!(extract_text(&r), "The page says Hello.");
        assert_eq!(summarizer.calls(), 1);
        let d = r.details.unwrap();
        assert_eq!(d["subagentSessionId"], "sub-sess-1");
        assert_eq!(d["fromCache"], false);
    }

    #[tokio::test]
    async fn cache_hit_skips_fetch_and_summarizer() {
        let fetch_count = Arc::new(AtomicUsize::new(0));
        let fc = fetch_count.clone();
        let http = Arc::new(MockHttp {
            handler: Box::new(move |_| {
                fc.fetch_add(1, Ordering::Relaxed);
                Ok(HttpResponse {
                    status: 200,
                    body: "<html><head><title>T</title></head><body>B</body></html>".into(),
                    content_type: Some("text/html".into()),
                })
            }),
        });
        let summarizer = Arc::new(MockSummarizer::new("Summary"));
        let tool = WebFetchTool::new_with_summarizer(http, summarizer.clone());
        let ctx = make_ctx();

        // First call — fetches + summarizes
        let _ = tool.execute(json!({"url": "https://example.com", "prompt": "q"}), &ctx).await.unwrap();
        assert_eq!(fetch_count.load(Ordering::Relaxed), 1);
        assert_eq!(summarizer.calls(), 1);

        // Second call — cache hit, no fetch or summarizer
        let r = tool.execute(json!({"url": "https://example.com", "prompt": "q"}), &ctx).await.unwrap();
        assert_eq!(fetch_count.load(Ordering::Relaxed), 1);
        assert_eq!(summarizer.calls(), 1);
        assert_eq!(extract_text(&r), "Summary");
        assert_eq!(r.details.unwrap()["fromCache"], true);
    }

    #[tokio::test]
    async fn cache_miss_then_hit() {
        let http = Arc::new(html_response("<html><body>Content</body></html>"));
        let summarizer = Arc::new(MockSummarizer::new("Cached answer"));
        let tool = WebFetchTool::new_with_summarizer(http, summarizer.clone());
        let ctx = make_ctx();

        // Miss
        let r1 = tool.execute(json!({"url": "https://example.com", "prompt": "q"}), &ctx).await.unwrap();
        assert_eq!(r1.details.as_ref().unwrap()["fromCache"], false);

        // Hit
        let r2 = tool.execute(json!({"url": "https://example.com", "prompt": "q"}), &ctx).await.unwrap();
        assert_eq!(r2.details.as_ref().unwrap()["fromCache"], true);
        assert_eq!(extract_text(&r2), "Cached answer");
    }

    #[tokio::test]
    async fn fallback_to_raw_content_without_summarizer() {
        let http = Arc::new(html_response("<html><head><title>Page</title></head><body><p>Raw content</p></body></html>"));
        let tool = WebFetchTool::new(http);
        let r = tool.execute(json!({"url": "https://example.com", "prompt": "q"}), &make_ctx()).await.unwrap();
        assert!(r.is_error.is_none());
        let text = extract_text(&r);
        assert!(text.contains("# Page"));
        assert!(text.contains("Raw content"));
        // No subagent session
        assert_eq!(r.details.as_ref().unwrap()["subagentSessionId"], "");
    }

    #[tokio::test]
    async fn summarizer_error_falls_back_to_raw_content() {
        let http = Arc::new(html_response("<html><head><title>Fallback</title></head><body><p>Raw</p></body></html>"));
        let summarizer: Arc<dyn ContentSummarizer> = Arc::new(FailingSummarizer);
        let tool = WebFetchTool::new_with_summarizer(http, summarizer);
        let r = tool.execute(json!({"url": "https://example.com", "prompt": "q"}), &make_ctx()).await.unwrap();
        assert!(r.is_error.is_none());
        let text = extract_text(&r);
        assert!(text.contains("# Fallback"));
        assert!(text.contains("Raw"));
    }

    #[tokio::test]
    async fn cache_returns_from_cache_flag() {
        let http = Arc::new(html_response("<html><body>X</body></html>"));
        let summarizer = Arc::new(MockSummarizer::new("A"));
        let tool = WebFetchTool::new_with_summarizer(http, summarizer);
        let ctx = make_ctx();

        let r1 = tool.execute(json!({"url": "https://example.com", "prompt": "q"}), &ctx).await.unwrap();
        assert_eq!(r1.details.as_ref().unwrap()["fromCache"], false);

        let r2 = tool.execute(json!({"url": "https://example.com", "prompt": "q"}), &ctx).await.unwrap();
        assert_eq!(r2.details.as_ref().unwrap()["fromCache"], true);
    }

    #[test]
    fn build_summarizer_task_includes_all_parts() {
        let task = build_summarizer_task("What is it?", "My Page", "Some content here");
        assert!(task.contains("What is it?"));
        assert!(task.contains("My Page"));
        assert!(task.contains("Some content here"));
        assert!(task.contains("Answer this question"));
        assert!(task.contains("Instructions:"));
    }
}
