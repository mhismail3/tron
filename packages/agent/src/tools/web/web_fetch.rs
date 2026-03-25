//! `WebFetch` tool — universal HTTP client with HTML summarization.
//!
//! Two modes:
//! 1. **Summarization** (legacy): GET + prompt → fetch HTML → parse → summarize → cache
//! 2. **Raw HTTP**: Any method, headers, body → return raw response with status/headers
//!
//! Mode selection:
//! - If `prompt` is provided AND method is GET AND `rawResponse` is false → summarization
//! - Otherwise → raw HTTP mode

use std::collections::HashMap;
use std::sync::Arc;

use async_trait::async_trait;
use parking_lot::Mutex;
use serde_json::{Value, json};
use crate::core::tools::{Tool, ToolCategory, ToolResultBody, TronToolResult, error_result};

use crate::tools::errors::ToolError;
use crate::tools::traits::{ContentSummarizer, HttpClient, HttpRequest, ToolContext, TronTool};
use crate::tools::utils::schema::ToolSchemaBuilder;
use crate::tools::utils::validation::{
    get_optional_bool, get_optional_string, get_optional_u64, validate_required_string,
};
use crate::tools::web::cache::{CachedResult, WebCache, WebCacheConfig};
use crate::tools::web::html_parser::parse_html;
use crate::tools::web::url_validator::{UrlValidatorConfig, validate_url};

const MAX_RESPONSE_SIZE: usize = 10 * 1024 * 1024;
const MAX_CONTENT_TOKENS: usize = 50_000;
const MAX_BODY_SIZE: usize = 10 * 1024 * 1024;

/// The `WebFetch` tool fetches URLs and can either summarize HTML or return raw HTTP responses.
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

/// Parse request headers from a JSON value (object or null).
fn parse_headers(params: &Value) -> HashMap<String, String> {
    params
        .get("headers")
        .and_then(Value::as_object)
        .map(|obj| {
            obj.iter()
                .filter_map(|(k, v)| v.as_str().map(|s| (k.clone(), s.to_string())))
                .collect()
        })
        .unwrap_or_default()
}

/// Parse cookies from a JSON value (object or null) into a Cookie header string.
/// Keys and values are URL-encoded to handle special characters.
fn parse_cookies(params: &Value) -> Option<String> {
    params
        .get("cookies")
        .and_then(Value::as_object)
        .map(|obj| {
            obj.iter()
                .filter_map(|(k, v)| {
                    v.as_str().map(|s| {
                        let encoded_k = urlencoding::encode(k);
                        let encoded_v = urlencoding::encode(s);
                        format!("{encoded_k}={encoded_v}")
                    })
                })
                .collect::<Vec<_>>()
                .join("; ")
        })
        .filter(|s| !s.is_empty())
}

/// Serialize the request body from params. Returns the body string and whether
/// we should auto-set Content-Type to application/json.
fn extract_body(params: &Value) -> (Option<String>, bool) {
    match params.get("body") {
        None | Some(Value::Null) => (None, false),
        Some(Value::String(s)) => (Some(s.clone()), false),
        Some(obj @ (Value::Object(_) | Value::Array(_))) => {
            (Some(obj.to_string()), true)
        }
        Some(other) => (Some(other.to_string()), false),
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
        ToolSchemaBuilder::new(
            "WebFetch",
            "Universal HTTP client. Two modes:\n\n\
             **1. Summarization mode** (default for GET with prompt): Fetches a web page, extracts content, \
             and summarizes it to answer your question. Results cached for 15 minutes.\n\n\
             **2. Raw HTTP mode** (any method, or GET without prompt, or rawResponse=true): \
             Sends an HTTP request and returns the raw response with status code and headers. \
             Use this for REST APIs, webhooks, and service health checks.\n\n\
             Parameters:\n\
             - **url** (required): The URL to fetch. HTTP is auto-upgraded to HTTPS.\n\
             - **prompt** (optional): Question about the content. Triggers summarization mode for GET requests.\n\
             - **method** (optional): HTTP method — GET (default), POST, PUT, PATCH, DELETE, HEAD.\n\
             - **headers** (optional): Custom request headers as key-value object.\n\
             - **body** (optional): Request body. Objects are auto-serialized as JSON.\n\
             - **cookies** (optional): Cookies as key-value object.\n\
             - **rawResponse** (optional): If true, skip HTML parsing and return raw response body.\n\
             - **followRedirects** (optional): Whether to follow redirects (default: true).\n\
             - **allowPrivateNetwork** (optional): Allow requests to localhost/private IPs (default: false).",
        )
        .required_property("url", json!({"type": "string", "description": "The URL to fetch"}))
        .property("prompt", json!({"type": "string", "description": "Question about the page content (triggers summarization mode)"}))
        .property("method", json!({
            "type": "string",
            "description": "HTTP method",
            "enum": ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD"],
            "default": "GET"
        }))
        .property("headers", json!({"type": "object", "description": "Custom request headers", "additionalProperties": {"type": "string"}}))
        .property("body", json!({"description": "Request body (string or JSON object)"}))
        .property("cookies", json!({"type": "object", "description": "Cookies as key-value pairs", "additionalProperties": {"type": "string"}}))
        .property("rawResponse", json!({"type": "boolean", "description": "Return raw response body instead of parsing HTML", "default": false}))
        .property("followRedirects", json!({"type": "boolean", "description": "Follow HTTP redirects", "default": true}))
        .property("allowPrivateNetwork", json!({"type": "boolean", "description": "Allow requests to localhost and private IPs", "default": false}))
        .property("maxSize", json!({"type": "number", "description": "Override maximum response size in bytes (default: 10MB)"}))
        .build()
    }

    async fn execute(&self, params: Value, ctx: &ToolContext) -> Result<TronToolResult, ToolError> {
        let raw_url = match validate_required_string(&params, "url", "the URL to fetch") {
            Ok(u) => u,
            Err(e) => return Ok(e),
        };

        let prompt = get_optional_string(&params, "prompt");
        let method = get_optional_string(&params, "method")
            .unwrap_or_else(|| "GET".to_string())
            .to_uppercase();
        let raw_response = get_optional_bool(&params, "rawResponse").unwrap_or(false);
        let follow_redirects = get_optional_bool(&params, "followRedirects").unwrap_or(true);
        let allow_private = get_optional_bool(&params, "allowPrivateNetwork").unwrap_or(false);
        let max_size = get_optional_u64(&params, "maxSize")
            .map(|v| v as usize)
            .unwrap_or(MAX_RESPONSE_SIZE);
        let req_headers = parse_headers(&params);
        let cookie_header = parse_cookies(&params);
        let (body, auto_json_content_type) = extract_body(&params);

        // Validate body size
        if let Some(ref b) = body {
            if b.len() > MAX_BODY_SIZE {
                return Ok(error_result(format!(
                    "Request body too large: {} bytes (max {MAX_BODY_SIZE})",
                    b.len()
                )));
            }
        }

        // Validate URL
        let config = UrlValidatorConfig {
            allow_private_network: allow_private,
            ..Default::default()
        };
        let url = match validate_url(&raw_url, &config) {
            Ok(u) => u,
            Err(e) => return Ok(error_result(e.to_string())),
        };

        // Determine mode: summarization vs raw
        let use_summarization = prompt.is_some() && method == "GET" && !raw_response;

        if use_summarization {
            let prompt = prompt.unwrap();
            return self.execute_summarization(&url, &prompt, max_size, ctx).await;
        }

        // Raw HTTP mode
        self.execute_raw(&url, &method, &req_headers, cookie_header.as_deref(),
                         body.as_deref(), auto_json_content_type, follow_redirects, max_size).await
    }
}

impl WebFetchTool {
    /// Execute in summarization mode (legacy behavior).
    async fn execute_summarization(
        &self,
        url: &str,
        prompt: &str,
        max_size: usize,
        ctx: &ToolContext,
    ) -> Result<TronToolResult, ToolError> {
        // Check cache
        {
            let mut cache = self.cache.lock();
            if let Some(cached) = cache.get(url, prompt) {
                let cached = cached.clone();
                return Ok(TronToolResult {
                    content: ToolResultBody::Blocks(vec![
                        crate::core::content::ToolResultContent::text(&cached.answer),
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

        // Fetch via simple GET
        let response = match self.http.get(url).await {
            Ok(r) => r,
            Err(e) => return Ok(error_result(format!("HTTP request failed: {e}"))),
        };

        if response.status != 200 {
            return Ok(error_result(format!("HTTP {} for {url}", response.status)));
        }

        if response.body.len() > max_size {
            return Ok(error_result(format!(
                "Response too large: {} bytes (max {max_size})",
                response.body.len()
            )));
        }

        // Parse HTML
        let parsed = parse_html(&response.body, Some(url));

        // Truncate content for summarization
        let max_bytes = MAX_CONTENT_TOKENS * 4;
        let truncated_content = if parsed.markdown.len() > max_bytes {
            let prefix = crate::core::text::truncate_str(&parsed.markdown, max_bytes);
            format!("{prefix}...\n[Content truncated]")
        } else {
            parsed.markdown.clone()
        };

        let title = if parsed.title.is_empty() {
            "(untitled)".to_string()
        } else {
            parsed.title.clone()
        };

        // Summarize via subagent (or fall back to raw content)
        let (answer, subagent_session_id) = if let Some(ref summarizer) = self.summarizer {
            let task = build_summarizer_task(prompt, &title, &truncated_content);
            match summarizer.summarize(&task, &ctx.session_id).await {
                Ok(result) => (result.answer, result.session_id),
                Err(e) => {
                    tracing::debug!(error = %e, "summarizer failed, returning raw content");
                    (format!("# {title}\n\n{truncated_content}"), String::new())
                }
            }
        } else {
            (format!("# {title}\n\n{truncated_content}"), String::new())
        };

        // Cache the result
        self.cache.lock().set(
            url,
            prompt,
            CachedResult {
                answer: answer.clone(),
                url: url.to_string(),
                title: title.clone(),
                subagent_session_id: subagent_session_id.clone(),
            },
        );

        Ok(TronToolResult {
            content: ToolResultBody::Blocks(vec![crate::core::content::ToolResultContent::text(
                &answer,
            )]),
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

    /// Execute in raw HTTP mode.
    async fn execute_raw(
        &self,
        url: &str,
        method: &str,
        headers: &HashMap<String, String>,
        cookie_header: Option<&str>,
        body: Option<&str>,
        auto_json_content_type: bool,
        follow_redirects: bool,
        max_size: usize,
    ) -> Result<TronToolResult, ToolError> {
        // Build header list
        let mut header_pairs: Vec<(&str, &str)> = headers
            .iter()
            .map(|(k, v)| (k.as_str(), v.as_str()))
            .collect();

        // Auto-set Content-Type for JSON bodies if not already set
        let has_content_type = headers.keys().any(|k| k.eq_ignore_ascii_case("content-type"));
        let json_ct = "application/json".to_string();
        if auto_json_content_type && !has_content_type {
            header_pairs.push(("Content-Type", &json_ct));
        }

        // Add cookie header
        let cookie_val;
        if let Some(cookies) = cookie_header {
            cookie_val = cookies.to_string();
            header_pairs.push(("Cookie", &cookie_val));
        }

        let req = HttpRequest {
            url,
            method,
            headers: header_pairs,
            body,
            follow_redirects,
        };

        let response = match self.http.request(&req).await {
            Ok(r) => r,
            Err(e) => return Ok(error_result(format!("HTTP request failed: {e}"))),
        };

        if response.body.len() > max_size {
            return Ok(error_result(format!(
                "Response too large: {} bytes (max {max_size})",
                response.body.len()
            )));
        }

        // Handle binary response: base64-encode if content-type is not text/*
        let is_binary = response.content_type.as_ref()
            .map(|ct| !ct.starts_with("text/") && !ct.contains("json") && !ct.contains("xml") && !ct.contains("javascript"))
            .unwrap_or(false);

        let body_text = if is_binary {
            use base64::Engine;
            let b64 = base64::engine::general_purpose::STANDARD.encode(response.body.as_bytes());
            format!("[Binary response, base64-encoded]\n{b64}")
        } else {
            response.body.clone()
        };

        // Format response headers for display
        let resp_headers_json: serde_json::Map<String, Value> = response
            .headers
            .iter()
            .map(|(k, v)| (k.clone(), Value::String(v.clone())))
            .collect();

        // Truncate body for context if very large
        let max_bytes = MAX_CONTENT_TOKENS * 4;
        let display_body = if body_text.len() > max_bytes {
            let prefix = crate::core::text::truncate_str(&body_text, max_bytes);
            format!("{prefix}\n\n[Response truncated — {}/{} bytes shown]", max_bytes, body_text.len())
        } else {
            body_text
        };

        let output = format!(
            "HTTP {} {}\n\n{}",
            response.status,
            url,
            display_body,
        );

        Ok(TronToolResult {
            content: ToolResultBody::Blocks(vec![crate::core::content::ToolResultContent::text(
                output,
            )]),
            details: Some(json!({
                "url": url,
                "method": method,
                "status": response.status,
                "contentType": response.content_type,
                "responseHeaders": resp_headers_json,
                "bodyLength": response.body.len(),
            })),
            is_error: None,
            stop_turn: None,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::tools::traits::{HttpResponse, SummarizerResult};
    use std::sync::atomic::{AtomicUsize, Ordering};

    struct MockHttp {
        get_handler: Box<dyn Fn(&str) -> Result<HttpResponse, String> + Send + Sync>,
        request_handler: Box<dyn Fn(&HttpRequest<'_>) -> Result<HttpResponse, String> + Send + Sync>,
    }

    impl MockHttp {
        fn get_only(handler: impl Fn(&str) -> Result<HttpResponse, String> + Send + Sync + 'static) -> Self {
            Self {
                get_handler: Box::new(handler),
                request_handler: Box::new(|req| {
                    Ok(HttpResponse {
                        status: 200,
                        body: format!("{} {}", req.method, req.url),
                        content_type: Some("text/plain".into()),
                        headers: HashMap::new(),
                    })
                }),
            }
        }
    }

    #[async_trait]
    impl HttpClient for MockHttp {
        async fn get(&self, url: &str) -> Result<HttpResponse, ToolError> {
            (self.get_handler)(url).map_err(|e| ToolError::Internal { message: e })
        }

        async fn request(&self, req: &HttpRequest<'_>) -> Result<HttpResponse, ToolError> {
            (self.request_handler)(req).map_err(|e| ToolError::Internal { message: e })
        }
    }

    fn html_response(body: &str) -> MockHttp {
        let body = body.to_string();
        MockHttp::get_only(move |_| {
            Ok(HttpResponse {
                status: 200,
                body: body.clone(),
                content_type: Some("text/html".into()),
                headers: HashMap::new(),
            })
        })
    }

    /// Full mock that handles both get and request
    fn full_mock() -> MockHttp {
        MockHttp {
            get_handler: Box::new(|_| {
                Ok(HttpResponse {
                    status: 200,
                    body: "<html><body>test</body></html>".into(),
                    content_type: Some("text/html".into()),
                    headers: HashMap::new(),
                })
            }),
            request_handler: Box::new(|req| {
                let mut headers = HashMap::new();
                headers.insert("x-request-id".into(), "test-123".into());

                // Echo back the method and body for testing
                let body = if let Some(b) = req.body {
                    format!("method={} body={}", req.method, b)
                } else {
                    format!("method={}", req.method)
                };

                Ok(HttpResponse {
                    status: 200,
                    body,
                    content_type: Some("application/json".into()),
                    headers,
                })
            }),
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
            let _ = self.call_count.fetch_add(1, Ordering::Relaxed);
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
            Err(ToolError::Internal {
                message: "summarizer exploded".into(),
            })
        }
    }

    use crate::tools::testutil::{extract_text, make_ctx};

    // ─── Original tests (unchanged behavior) ─────────────────────────────

    #[tokio::test]
    async fn successful_fetch_returns_parsed_content() {
        let http = Arc::new(html_response(
            "<html><head><title>Test</title></head><body><p>Hello World</p></body></html>",
        ));
        let tool = WebFetchTool::new(http);
        let r = tool
            .execute(
                json!({"url": "https://example.com", "prompt": "what is it?"}),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert!(r.is_error.is_none());
        let text = extract_text(&r);
        assert!(text.contains("Test"));
        assert!(text.contains("Hello World") || text.contains("Hello"));
    }

    #[tokio::test]
    async fn invalid_url_returns_error() {
        let http = Arc::new(html_response(""));
        let tool = WebFetchTool::new(http);
        let r = tool
            .execute(json!({"url": "not-a-url", "prompt": "q"}), &make_ctx())
            .await
            .unwrap();
        assert_eq!(r.is_error, Some(true));
    }

    #[tokio::test]
    async fn missing_url_returns_error() {
        let http = Arc::new(html_response(""));
        let tool = WebFetchTool::new(http);
        let r = tool
            .execute(json!({"prompt": "q"}), &make_ctx())
            .await
            .unwrap();
        assert_eq!(r.is_error, Some(true));
    }

    #[tokio::test]
    async fn http_error_status() {
        let http = Arc::new(MockHttp::get_only(|_| {
            Ok(HttpResponse {
                status: 404,
                body: "Not Found".into(),
                content_type: Some("text/html".into()),
                headers: HashMap::new(),
            })
        }));
        let tool = WebFetchTool::new(http);
        let r = tool
            .execute(
                json!({"url": "https://example.com/missing", "prompt": "q"}),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert_eq!(r.is_error, Some(true));
        assert!(extract_text(&r).contains("404"));
    }

    #[tokio::test]
    async fn network_failure_returns_tool_error() {
        let http = Arc::new(MockHttp::get_only(|_| {
            Err("connection timed out".into())
        }));
        let tool = WebFetchTool::new(http);
        let r = tool
            .execute(
                json!({"url": "https://example.com", "prompt": "q"}),
                &make_ctx(),
            )
            .await;
        let result = r.unwrap();
        assert_eq!(result.is_error, Some(true));
        assert!(extract_text(&result).contains("HTTP request failed"));
    }

    #[tokio::test]
    async fn details_include_url_and_title() {
        let http = Arc::new(html_response(
            "<html><head><title>My Page</title></head><body>content</body></html>",
        ));
        let tool = WebFetchTool::new(http);
        let r = tool
            .execute(
                json!({"url": "https://example.com", "prompt": "q"}),
                &make_ctx(),
            )
            .await
            .unwrap();
        let d = r.details.unwrap();
        assert_eq!(d["title"], "My Page");
        assert!(d["url"].as_str().unwrap().contains("example.com"));
    }

    #[tokio::test]
    async fn localhost_url_blocked() {
        let http = Arc::new(html_response(""));
        let tool = WebFetchTool::new(http);
        let r = tool
            .execute(
                json!({"url": "https://localhost/admin", "prompt": "q"}),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert_eq!(r.is_error, Some(true));
        assert!(extract_text(&r).contains("Internal"));
    }

    #[tokio::test]
    async fn response_too_large() {
        let http = Arc::new(MockHttp::get_only(|_| {
            Ok(HttpResponse {
                status: 200,
                body: "x".repeat(11 * 1024 * 1024),
                content_type: Some("text/html".into()),
                headers: HashMap::new(),
            })
        }));
        let tool = WebFetchTool::new(http);
        let r = tool
            .execute(
                json!({"url": "https://example.com", "prompt": "q"}),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert_eq!(r.is_error, Some(true));
        assert!(extract_text(&r).contains("too large"));
    }

    #[tokio::test]
    async fn large_content_truncated() {
        let body = format!("<html><body>{}</body></html>", "word ".repeat(100_000));
        let http = Arc::new(html_response(&body));
        let tool = WebFetchTool::new(http);
        let r = tool
            .execute(
                json!({"url": "https://example.com", "prompt": "q"}),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert!(r.is_error.is_none());
    }

    // ─── Summarizer + cache tests ────────────────────────────────────────

    #[tokio::test]
    async fn summarizer_called_when_available() {
        let http = Arc::new(html_response(
            "<html><head><title>Test</title></head><body><p>Hello</p></body></html>",
        ));
        let summarizer = Arc::new(MockSummarizer::new("The page says Hello."));
        let tool = WebFetchTool::new_with_summarizer(http, summarizer.clone());
        let r = tool
            .execute(
                json!({"url": "https://example.com", "prompt": "what does it say?"}),
                &make_ctx(),
            )
            .await
            .unwrap();
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
        let http = Arc::new(MockHttp::get_only(move |_| {
            let _ = fc.fetch_add(1, Ordering::Relaxed);
            Ok(HttpResponse {
                status: 200,
                body: "<html><head><title>T</title></head><body>B</body></html>".into(),
                content_type: Some("text/html".into()),
                headers: HashMap::new(),
            })
        }));
        let summarizer = Arc::new(MockSummarizer::new("Summary"));
        let tool = WebFetchTool::new_with_summarizer(http, summarizer.clone());
        let ctx = make_ctx();

        let _ = tool
            .execute(json!({"url": "https://example.com", "prompt": "q"}), &ctx)
            .await
            .unwrap();
        assert_eq!(fetch_count.load(Ordering::Relaxed), 1);
        assert_eq!(summarizer.calls(), 1);

        let r = tool
            .execute(json!({"url": "https://example.com", "prompt": "q"}), &ctx)
            .await
            .unwrap();
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

        let r1 = tool
            .execute(json!({"url": "https://example.com", "prompt": "q"}), &ctx)
            .await
            .unwrap();
        assert_eq!(r1.details.as_ref().unwrap()["fromCache"], false);

        let r2 = tool
            .execute(json!({"url": "https://example.com", "prompt": "q"}), &ctx)
            .await
            .unwrap();
        assert_eq!(r2.details.as_ref().unwrap()["fromCache"], true);
        assert_eq!(extract_text(&r2), "Cached answer");
    }

    #[tokio::test]
    async fn fallback_to_raw_content_without_summarizer() {
        let http = Arc::new(html_response(
            "<html><head><title>Page</title></head><body><p>Raw content</p></body></html>",
        ));
        let tool = WebFetchTool::new(http);
        let r = tool
            .execute(
                json!({"url": "https://example.com", "prompt": "q"}),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert!(r.is_error.is_none());
        let text = extract_text(&r);
        assert!(text.contains("# Page"));
        assert!(text.contains("Raw content"));
        assert_eq!(r.details.as_ref().unwrap()["subagentSessionId"], "");
    }

    #[tokio::test]
    async fn summarizer_error_falls_back_to_raw_content() {
        let http = Arc::new(html_response(
            "<html><head><title>Fallback</title></head><body><p>Raw</p></body></html>",
        ));
        let summarizer: Arc<dyn ContentSummarizer> = Arc::new(FailingSummarizer);
        let tool = WebFetchTool::new_with_summarizer(http, summarizer);
        let r = tool
            .execute(
                json!({"url": "https://example.com", "prompt": "q"}),
                &make_ctx(),
            )
            .await
            .unwrap();
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

        let r1 = tool
            .execute(json!({"url": "https://example.com", "prompt": "q"}), &ctx)
            .await
            .unwrap();
        assert_eq!(r1.details.as_ref().unwrap()["fromCache"], false);

        let r2 = tool
            .execute(json!({"url": "https://example.com", "prompt": "q"}), &ctx)
            .await
            .unwrap();
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

    // ─── New HTTP method tests ───────────────────────────────────────────

    #[tokio::test]
    async fn post_with_json_body() {
        let http = Arc::new(full_mock());
        let tool = WebFetchTool::new(http);
        let r = tool
            .execute(
                json!({
                    "url": "https://api.example.com/data",
                    "method": "POST",
                    "body": {"key": "value"},
                }),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert!(r.is_error.is_none());
        let text = extract_text(&r);
        assert!(text.contains("method=POST"));
        assert!(text.contains("key"));
        let d = r.details.unwrap();
        assert_eq!(d["method"], "POST");
        assert_eq!(d["status"], 200);
    }

    #[tokio::test]
    async fn post_with_string_body() {
        let http = Arc::new(full_mock());
        let tool = WebFetchTool::new(http);
        let r = tool
            .execute(
                json!({
                    "url": "https://api.example.com/data",
                    "method": "POST",
                    "body": "raw string body",
                }),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert!(r.is_error.is_none());
        let text = extract_text(&r);
        assert!(text.contains("method=POST"));
        assert!(text.contains("raw string body"));
    }

    #[tokio::test]
    async fn put_request() {
        let http = Arc::new(full_mock());
        let tool = WebFetchTool::new(http);
        let r = tool
            .execute(
                json!({
                    "url": "https://api.example.com/data/1",
                    "method": "PUT",
                    "body": {"updated": true},
                }),
                &make_ctx(),
            )
            .await
            .unwrap();
        let text = extract_text(&r);
        assert!(text.contains("method=PUT"));
    }

    #[tokio::test]
    async fn delete_request() {
        let http = Arc::new(full_mock());
        let tool = WebFetchTool::new(http);
        let r = tool
            .execute(
                json!({
                    "url": "https://api.example.com/data/1",
                    "method": "DELETE",
                }),
                &make_ctx(),
            )
            .await
            .unwrap();
        let text = extract_text(&r);
        assert!(text.contains("method=DELETE"));
    }

    #[tokio::test]
    async fn patch_request() {
        let http = Arc::new(full_mock());
        let tool = WebFetchTool::new(http);
        let r = tool
            .execute(
                json!({
                    "url": "https://api.example.com/data/1",
                    "method": "PATCH",
                    "body": {"field": "new_value"},
                }),
                &make_ctx(),
            )
            .await
            .unwrap();
        let text = extract_text(&r);
        assert!(text.contains("method=PATCH"));
    }

    #[tokio::test]
    async fn head_request() {
        let http = Arc::new(full_mock());
        let tool = WebFetchTool::new(http);
        let r = tool
            .execute(
                json!({
                    "url": "https://api.example.com/health",
                    "method": "HEAD",
                }),
                &make_ctx(),
            )
            .await
            .unwrap();
        let d = r.details.unwrap();
        assert_eq!(d["method"], "HEAD");
        assert_eq!(d["status"], 200);
    }

    #[tokio::test]
    async fn custom_headers() {
        let http = Arc::new(MockHttp {
            get_handler: Box::new(|_| Ok(HttpResponse {
                status: 200, body: String::new(), content_type: None, headers: HashMap::new(),
            })),
            request_handler: Box::new(|req| {
                // Verify headers were passed through
                let auth = req.headers.iter().find(|(k, _)| *k == "Authorization");
                let body = if let Some((_, v)) = auth {
                    format!("auth={v}")
                } else {
                    "no-auth".into()
                };
                Ok(HttpResponse {
                    status: 200, body, content_type: None, headers: HashMap::new(),
                })
            }),
        });
        let tool = WebFetchTool::new(http);
        let r = tool
            .execute(
                json!({
                    "url": "https://api.example.com/data",
                    "method": "GET",
                    "headers": {"Authorization": "Bearer token123"},
                    "rawResponse": true,
                }),
                &make_ctx(),
            )
            .await
            .unwrap();
        let text = extract_text(&r);
        assert!(text.contains("auth=Bearer token123"));
    }

    #[tokio::test]
    async fn cookies_sent_with_request() {
        let http = Arc::new(MockHttp {
            get_handler: Box::new(|_| Ok(HttpResponse {
                status: 200, body: String::new(), content_type: None, headers: HashMap::new(),
            })),
            request_handler: Box::new(|req| {
                let cookie = req.headers.iter().find(|(k, _)| *k == "Cookie");
                let body = if let Some((_, v)) = cookie {
                    format!("cookie={v}")
                } else {
                    "no-cookie".into()
                };
                Ok(HttpResponse {
                    status: 200, body, content_type: None, headers: HashMap::new(),
                })
            }),
        });
        let tool = WebFetchTool::new(http);
        let r = tool
            .execute(
                json!({
                    "url": "https://api.example.com/data",
                    "method": "GET",
                    "cookies": {"session": "abc123", "user": "test"},
                    "rawResponse": true,
                }),
                &make_ctx(),
            )
            .await
            .unwrap();
        let text = extract_text(&r);
        assert!(text.contains("session=abc123"));
        assert!(text.contains("user=test"));
    }

    #[tokio::test]
    async fn raw_response_includes_status_and_headers() {
        let http = Arc::new(full_mock());
        let tool = WebFetchTool::new(http);
        let r = tool
            .execute(
                json!({
                    "url": "https://api.example.com/data",
                    "rawResponse": true,
                }),
                &make_ctx(),
            )
            .await
            .unwrap();
        let d = r.details.unwrap();
        assert_eq!(d["status"], 200);
        assert!(d["responseHeaders"].is_object());
        assert_eq!(d["responseHeaders"]["x-request-id"], "test-123");
    }

    #[tokio::test]
    async fn get_without_prompt_uses_raw_mode() {
        let http = Arc::new(full_mock());
        let tool = WebFetchTool::new(http);
        let r = tool
            .execute(
                json!({"url": "https://api.example.com/data"}),
                &make_ctx(),
            )
            .await
            .unwrap();
        // Raw mode returns method= prefix, not HTML-parsed content
        let d = r.details.unwrap();
        assert_eq!(d["method"], "GET");
        assert!(d.get("status").is_some());
    }

    #[tokio::test]
    async fn non_2xx_returns_response_not_error() {
        let http = Arc::new(MockHttp {
            get_handler: Box::new(|_| Ok(HttpResponse {
                status: 404, body: "Not Found".into(), content_type: None, headers: HashMap::new(),
            })),
            request_handler: Box::new(|_| {
                Ok(HttpResponse {
                    status: 404,
                    body: "Not Found".into(),
                    content_type: None,
                    headers: HashMap::new(),
                })
            }),
        });
        let tool = WebFetchTool::new(http);
        // In raw mode, non-2xx is NOT an error
        let r = tool
            .execute(
                json!({"url": "https://api.example.com/missing", "method": "GET", "rawResponse": true}),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert!(r.is_error.is_none());
        let d = r.details.unwrap();
        assert_eq!(d["status"], 404);
    }

    #[tokio::test]
    async fn allow_private_network_flag() {
        let http = Arc::new(full_mock());
        let tool = WebFetchTool::new(http);

        // Blocked by default
        let r = tool
            .execute(
                json!({"url": "https://localhost/api", "rawResponse": true}),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert_eq!(r.is_error, Some(true));

        // Allowed with flag
        let r = tool
            .execute(
                json!({
                    "url": "https://localhost/api",
                    "rawResponse": true,
                    "allowPrivateNetwork": true,
                }),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert!(r.is_error.is_none());
    }

    #[tokio::test]
    async fn oversized_body_rejected() {
        let http = Arc::new(full_mock());
        let tool = WebFetchTool::new(http);
        let r = tool
            .execute(
                json!({
                    "url": "https://api.example.com/upload",
                    "method": "POST",
                    "body": "x".repeat(11 * 1024 * 1024),
                }),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert_eq!(r.is_error, Some(true));
        assert!(extract_text(&r).contains("too large"));
    }

    #[tokio::test]
    async fn content_type_auto_set_for_json_body() {
        let http = Arc::new(MockHttp {
            get_handler: Box::new(|_| Ok(HttpResponse {
                status: 200, body: String::new(), content_type: None, headers: HashMap::new(),
            })),
            request_handler: Box::new(|req| {
                let ct = req.headers.iter().find(|(k, _)| *k == "Content-Type");
                let body = if let Some((_, v)) = ct {
                    format!("ct={v}")
                } else {
                    "no-ct".into()
                };
                Ok(HttpResponse {
                    status: 200, body, content_type: None, headers: HashMap::new(),
                })
            }),
        });
        let tool = WebFetchTool::new(http);
        let r = tool
            .execute(
                json!({
                    "url": "https://api.example.com/data",
                    "method": "POST",
                    "body": {"key": "value"},
                }),
                &make_ctx(),
            )
            .await
            .unwrap();
        let text = extract_text(&r);
        assert!(text.contains("ct=application/json"));
    }

    #[tokio::test]
    async fn missing_prompt_in_summarization_mode_uses_raw() {
        let http = Arc::new(full_mock());
        let tool = WebFetchTool::new(http);
        // GET without prompt → raw mode
        let r = tool
            .execute(
                json!({"url": "https://example.com"}),
                &make_ctx(),
            )
            .await
            .unwrap();
        let d = r.details.unwrap();
        assert_eq!(d["method"], "GET");
    }

    // ─── Schema tests ────────────────────────────────────────────────

    #[test]
    fn schema_has_method_parameter() {
        let http = Arc::new(full_mock());
        let tool = WebFetchTool::new(http);
        let def = tool.definition();
        let props = def.parameters.properties.unwrap();
        assert!(props.contains_key("method"));
    }

    #[test]
    fn schema_has_headers_parameter() {
        let http = Arc::new(full_mock());
        let tool = WebFetchTool::new(http);
        let def = tool.definition();
        let props = def.parameters.properties.unwrap();
        assert!(props.contains_key("headers"));
    }

    #[test]
    fn schema_has_body_parameter() {
        let http = Arc::new(full_mock());
        let tool = WebFetchTool::new(http);
        let def = tool.definition();
        let props = def.parameters.properties.unwrap();
        assert!(props.contains_key("body"));
    }

    #[test]
    fn schema_method_enum_values() {
        let http = Arc::new(full_mock());
        let tool = WebFetchTool::new(http);
        let def = tool.definition();
        let props = def.parameters.properties.unwrap();
        let method = &props["method"];
        let enum_values = method["enum"].as_array().unwrap();
        assert!(enum_values.contains(&json!("GET")));
        assert!(enum_values.contains(&json!("POST")));
        assert!(enum_values.contains(&json!("PUT")));
        assert!(enum_values.contains(&json!("PATCH")));
        assert!(enum_values.contains(&json!("DELETE")));
        assert!(enum_values.contains(&json!("HEAD")));
    }

    #[test]
    fn schema_has_max_size_parameter() {
        let http = Arc::new(full_mock());
        let tool = WebFetchTool::new(http);
        let def = tool.definition();
        let props = def.parameters.properties.unwrap();
        assert!(props.contains_key("maxSize"));
    }

    // ─── Multiple headers test ───────────────────────────────────────

    #[tokio::test]
    async fn multiple_custom_headers() {
        let http = Arc::new(MockHttp {
            get_handler: Box::new(|_| Ok(HttpResponse {
                status: 200, body: String::new(), content_type: None, headers: HashMap::new(),
            })),
            request_handler: Box::new(|req| {
                let auth = req.headers.iter().find(|(k, _)| *k == "Authorization");
                let accept = req.headers.iter().find(|(k, _)| *k == "Accept");
                let body = format!(
                    "auth={} accept={}",
                    auth.map(|(_, v)| *v).unwrap_or("none"),
                    accept.map(|(_, v)| *v).unwrap_or("none"),
                );
                Ok(HttpResponse {
                    status: 200, body, content_type: None, headers: HashMap::new(),
                })
            }),
        });
        let tool = WebFetchTool::new(http);
        let r = tool
            .execute(
                json!({
                    "url": "https://api.example.com/data",
                    "method": "GET",
                    "headers": {
                        "Authorization": "Bearer token123",
                        "Accept": "application/json",
                    },
                    "rawResponse": true,
                }),
                &make_ctx(),
            )
            .await
            .unwrap();
        let text = extract_text(&r);
        assert!(text.contains("auth=Bearer token123"));
        assert!(text.contains("accept=application/json"));
    }

    // ─── Cookie special characters ───────────────────────────────────

    #[tokio::test]
    async fn cookies_with_special_characters() {
        let http = Arc::new(MockHttp {
            get_handler: Box::new(|_| Ok(HttpResponse {
                status: 200, body: String::new(), content_type: None, headers: HashMap::new(),
            })),
            request_handler: Box::new(|req| {
                let cookie = req.headers.iter().find(|(k, _)| *k == "Cookie");
                let body = if let Some((_, v)) = cookie {
                    format!("cookie={v}")
                } else {
                    "no-cookie".into()
                };
                Ok(HttpResponse {
                    status: 200, body, content_type: None, headers: HashMap::new(),
                })
            }),
        });
        let tool = WebFetchTool::new(http);
        let r = tool
            .execute(
                json!({
                    "url": "https://api.example.com/data",
                    "method": "GET",
                    "cookies": {"token": "abc=123&foo"},
                    "rawResponse": true,
                }),
                &make_ctx(),
            )
            .await
            .unwrap();
        let text = extract_text(&r);
        // Cookie values should be URL-encoded
        assert!(text.contains("cookie="));
        assert!(text.contains("token"));
    }

    // ─── Redirect tests ──────────────────────────────────────────────

    #[tokio::test]
    async fn follow_redirects_default_true() {
        // Default behavior: follow redirects (handled by reqwest)
        let http = Arc::new(full_mock());
        let tool = WebFetchTool::new(http);
        let r = tool
            .execute(
                json!({"url": "https://example.com", "rawResponse": true}),
                &make_ctx(),
            )
            .await
            .unwrap();
        // Just verify it doesn't error — redirect following is default behavior
        assert!(r.is_error.is_none());
    }

    #[tokio::test]
    async fn no_follow_redirects() {
        let http = Arc::new(MockHttp {
            get_handler: Box::new(|_| Ok(HttpResponse {
                status: 200, body: String::new(), content_type: None, headers: HashMap::new(),
            })),
            request_handler: Box::new(|req| {
                // Verify the flag was passed (in real impl, reqwest would not follow)
                let body = format!("follow={}", req.follow_redirects);
                Ok(HttpResponse {
                    status: 301, body, content_type: None,
                    headers: {
                        let mut h = HashMap::new();
                        h.insert("location".into(), "https://example.com/new".into());
                        h
                    },
                })
            }),
        });
        let tool = WebFetchTool::new(http);
        let r = tool
            .execute(
                json!({
                    "url": "https://example.com/old",
                    "rawResponse": true,
                    "followRedirects": false,
                }),
                &make_ctx(),
            )
            .await
            .unwrap();
        let text = extract_text(&r);
        assert!(text.contains("follow=false"));
        let d = r.details.unwrap();
        assert_eq!(d["status"], 301);
    }

    // ─── Error handling tests ────────────────────────────────────────

    #[tokio::test]
    async fn invalid_method_returns_error() {
        let http = Arc::new(MockHttp {
            get_handler: Box::new(|_| Ok(HttpResponse {
                status: 200, body: String::new(), content_type: None, headers: HashMap::new(),
            })),
            request_handler: Box::new(|_| {
                Err("Unsupported HTTP method: TRACE".into())
            }),
        });
        let tool = WebFetchTool::new(http);
        let r = tool
            .execute(
                json!({"url": "https://example.com", "method": "TRACE"}),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert_eq!(r.is_error, Some(true));
    }

    #[tokio::test]
    async fn binary_response_base64_encoded() {
        let http = Arc::new(MockHttp {
            get_handler: Box::new(|_| Ok(HttpResponse {
                status: 200, body: String::new(), content_type: None, headers: HashMap::new(),
            })),
            request_handler: Box::new(|_| {
                Ok(HttpResponse {
                    status: 200,
                    body: "binary\x00data".into(),
                    content_type: Some("application/octet-stream".into()),
                    headers: HashMap::new(),
                })
            }),
        });
        let tool = WebFetchTool::new(http);
        let r = tool
            .execute(
                json!({"url": "https://example.com/file.bin", "rawResponse": true}),
                &make_ctx(),
            )
            .await
            .unwrap();
        let text = extract_text(&r);
        assert!(text.contains("base64-encoded"));
    }

    #[tokio::test]
    async fn json_response_not_base64() {
        let http = Arc::new(MockHttp {
            get_handler: Box::new(|_| Ok(HttpResponse {
                status: 200, body: String::new(), content_type: None, headers: HashMap::new(),
            })),
            request_handler: Box::new(|_| {
                Ok(HttpResponse {
                    status: 200,
                    body: r#"{"key":"value"}"#.into(),
                    content_type: Some("application/json".into()),
                    headers: HashMap::new(),
                })
            }),
        });
        let tool = WebFetchTool::new(http);
        let r = tool
            .execute(
                json!({"url": "https://api.example.com/data", "rawResponse": true}),
                &make_ctx(),
            )
            .await
            .unwrap();
        let text = extract_text(&r);
        assert!(!text.contains("base64-encoded"));
        assert!(text.contains(r#""key":"value""#));
    }

    #[tokio::test]
    async fn max_size_override() {
        let http = Arc::new(MockHttp {
            get_handler: Box::new(|_| Ok(HttpResponse {
                status: 200, body: String::new(), content_type: None, headers: HashMap::new(),
            })),
            request_handler: Box::new(|_| {
                Ok(HttpResponse {
                    status: 200,
                    body: "x".repeat(5000),
                    content_type: Some("text/plain".into()),
                    headers: HashMap::new(),
                })
            }),
        });
        let tool = WebFetchTool::new(http);
        // With a tiny maxSize, the response should be rejected
        let r = tool
            .execute(
                json!({
                    "url": "https://example.com",
                    "rawResponse": true,
                    "maxSize": 100,
                }),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert_eq!(r.is_error, Some(true));
        assert!(extract_text(&r).contains("too large"));
    }

    #[tokio::test]
    async fn body_on_get_passed_through() {
        // RFC 7230 allows body on GET — we pass it through without error
        let http = Arc::new(full_mock());
        let tool = WebFetchTool::new(http);
        let r = tool
            .execute(
                json!({
                    "url": "https://api.example.com/search",
                    "method": "GET",
                    "body": {"query": "test"},
                    "rawResponse": true,
                }),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert!(r.is_error.is_none());
        let text = extract_text(&r);
        assert!(text.contains("method=GET"));
    }

    #[tokio::test]
    async fn empty_body_on_post_sends_empty() {
        let http = Arc::new(MockHttp {
            get_handler: Box::new(|_| Ok(HttpResponse {
                status: 200, body: String::new(), content_type: None, headers: HashMap::new(),
            })),
            request_handler: Box::new(|req| {
                let body_desc = match req.body {
                    Some(b) => format!("body_len={}", b.len()),
                    None => "no_body".into(),
                };
                Ok(HttpResponse {
                    status: 200, body: body_desc, content_type: None, headers: HashMap::new(),
                })
            }),
        });
        let tool = WebFetchTool::new(http);
        let r = tool
            .execute(
                json!({
                    "url": "https://api.example.com/data",
                    "method": "POST",
                    "body": "",
                }),
                &make_ctx(),
            )
            .await
            .unwrap();
        let text = extract_text(&r);
        // Empty string body should be sent, not null
        assert!(text.contains("body_len=0"));
    }

    #[tokio::test]
    async fn text_response_not_base64() {
        let http = Arc::new(MockHttp {
            get_handler: Box::new(|_| Ok(HttpResponse {
                status: 200, body: String::new(), content_type: None, headers: HashMap::new(),
            })),
            request_handler: Box::new(|_| {
                Ok(HttpResponse {
                    status: 200,
                    body: "plain text content".into(),
                    content_type: Some("text/plain".into()),
                    headers: HashMap::new(),
                })
            }),
        });
        let tool = WebFetchTool::new(http);
        let r = tool
            .execute(
                json!({"url": "https://example.com/file.txt", "rawResponse": true}),
                &make_ctx(),
            )
            .await
            .unwrap();
        let text = extract_text(&r);
        assert!(!text.contains("base64-encoded"));
        assert!(text.contains("plain text content"));
    }
}
