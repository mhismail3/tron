//! `WebSearch` tool — Brave Search API integration.
//!
//! Searches the web using the Brave Search API with support for multiple
//! endpoints (web, news, images, videos), domain filtering, and freshness.

use std::sync::Arc;

use async_trait::async_trait;
use serde_json::{Value, json};
use crate::core::tools::{Tool, ToolCategory, ToolResultBody, TronToolResult};

use crate::tools::errors::ToolError;
use crate::tools::traits::{HttpClient, ToolContext, TronTool};
use crate::tools::utils::schema::ToolSchemaBuilder;
use crate::tools::utils::validation::{get_optional_string, get_optional_u64, validate_required_string};

const BRAVE_BASE_URL: &str = "https://api.search.brave.com";
const MAX_QUERY_LENGTH: usize = 400;

/// Classify a WebSearch failure into a structured error class.
///
/// Returns one of: `"invalid_query"`, `"rate_limited"`, `"api_key"`,
/// `"quota"`, `"timeout"`, `"network"`, or `"unknown"`. Called server-side
/// so iOS can render a structured error chip without scanning text.
pub(crate) fn classify_web_search_error(status: Option<u16>, message: &str) -> &'static str {
    if let Some(s) = status {
        match s {
            429 => return "rate_limited",
            401 | 403 => return "api_key",
            408 | 504 => return "timeout",
            _ => {}
        }
    }
    let lower = message.to_lowercase();
    if lower.contains("rate limit") || lower.contains("429") {
        return "rate_limited";
    }
    if lower.contains("api key")
        || lower.contains("authentication")
        || lower.contains("401")
        || lower.contains("403")
    {
        return "api_key";
    }
    if lower.contains("quota") || lower.contains("exceeded") {
        return "quota";
    }
    if lower.contains("timeout") || lower.contains("timed out") {
        return "timeout";
    }
    if lower.contains("too long") || (lower.contains("invalid") && lower.contains("query")) {
        return "invalid_query";
    }
    if lower.contains("network") || lower.contains("connection") || lower.contains("dns") {
        return "network";
    }
    "unknown"
}

/// Build an error TronToolResult with structured details for WebSearch.
fn web_search_error(message: impl Into<String>, status: Option<u16>) -> TronToolResult {
    let msg = message.into();
    let class = classify_web_search_error(status, &msg);
    TronToolResult {
        content: ToolResultBody::Blocks(vec![
            crate::core::content::ToolResultContent::text(&msg),
        ]),
        details: Some(json!({
            "error": msg,
            "errorClass": class,
            "httpStatus": status,
        })),
        is_error: Some(true),
        stop_turn: None,
    }
}

/// Endpoint-specific result limits.
struct EndpointLimits {
    min: u64,
    max: u64,
    default: u64,
}

fn endpoint_limits(endpoint: &str) -> EndpointLimits {
    match endpoint {
        "news" | "videos" => EndpointLimits {
            min: 1,
            max: 50,
            default: 20,
        },
        "images" => EndpointLimits {
            min: 1,
            max: 200,
            default: 50,
        },
        _ => EndpointLimits {
            min: 1,
            max: 20,
            default: 10,
        }, // web
    }
}

fn endpoint_path(endpoint: &str) -> &'static str {
    match endpoint {
        "news" => "/res/v1/news/search",
        "images" => "/res/v1/images/search",
        "videos" => "/res/v1/videos/search",
        _ => "/res/v1/web/search",
    }
}

/// The `WebSearch` tool searches the web using the Brave Search API.
pub struct WebSearchTool {
    http: Arc<dyn HttpClient>,
    api_key: String,
}

impl WebSearchTool {
    /// Create a new `WebSearch` tool with the given HTTP client and API key.
    pub fn new(http: Arc<dyn HttpClient>, api_key: String) -> Self {
        Self { http, api_key }
    }
}

#[async_trait]
impl TronTool for WebSearchTool {
    fn name(&self) -> &str {
        "WebSearch"
    }

    fn category(&self) -> ToolCategory {
        ToolCategory::Custom
    }

    fn definition(&self) -> Tool {
        ToolSchemaBuilder::new(
            "WebSearch",
            "Search the web using Brave Search API.\n\n\
                Endpoints:\n\
                - **web**: General web search (default)\n\
                - **news**: Current news articles\n\
                - **images**: Image search\n\
                - **videos**: Video search\n\n\
                Rate limit: 1 query per second. Batch your searches rather than issuing many in parallel.\n\n\
                Tips:\n\
                - Use 'news' endpoint for current events\n\
                - Use 'freshness' to filter by recency: 'pd' (day), 'pw' (week), 'pm' (month), 'py' (year)\n\
                - Use domain filters (allowedDomains/blockedDomains) for trusted sources\n\
                - Use WebFetch to read full content of interesting results",
        )
        .required_property("query", json!({"type": "string", "description": "Search query (max 400 chars)"}))
        .property("endpoint", json!({"type": "string", "enum": ["web", "news", "images", "videos"], "description": "Search endpoint"}))
        .property("count", json!({"type": "number", "description": "Number of results"}))
        .property("freshness", json!({"type": "string", "description": "Freshness filter: pd, pw, pm, py, or date range"}))
        .property("country", json!({"type": "string", "description": "2-character country code"}))
        .property("safesearch", json!({"type": "string", "enum": ["off", "moderate", "strict"]}))
        .property("offset", json!({"type": "number", "description": "Result offset (0-9)"}))
        .build()
    }

    async fn execute(
        &self,
        params: Value,
        _ctx: &ToolContext,
    ) -> Result<TronToolResult, ToolError> {
        let query = match validate_required_string(&params, "query", "a search query") {
            Ok(q) => q,
            Err(e) => return Ok(e),
        };

        if query.len() > MAX_QUERY_LENGTH {
            return Ok(web_search_error(
                format!("Query too long: {} chars (max {MAX_QUERY_LENGTH})", query.len()),
                None,
            ));
        }

        let endpoint = get_optional_string(&params, "endpoint").unwrap_or_else(|| "web".into());
        let limits = endpoint_limits(&endpoint);
        let count = get_optional_u64(&params, "count")
            .or_else(|| get_optional_u64(&params, "maxResults"))
            .unwrap_or(limits.default)
            .clamp(limits.min, limits.max);

        let freshness = get_optional_string(&params, "freshness");
        let country = get_optional_string(&params, "country");
        let safesearch = get_optional_string(&params, "safesearch");
        let offset = get_optional_u64(&params, "offset");

        // Build query string
        let mut query_params: Vec<(String, String)> = vec![
            ("q".into(), query.clone()),
            ("count".into(), count.to_string()),
        ];
        if let Some(f) = &freshness {
            query_params.push(("freshness".into(), f.clone()));
        }
        if let Some(c) = &country {
            query_params.push(("country".into(), c.clone()));
        }
        if let Some(s) = &safesearch {
            query_params.push(("safesearch".into(), s.clone()));
        }
        if let Some(o) = offset {
            query_params.push(("offset".into(), o.to_string()));
        }

        let path = endpoint_path(&endpoint);
        let qs = query_params
            .iter()
            .map(|(k, v)| format!("{k}={}", urlencoding::encode(v)))
            .collect::<Vec<_>>()
            .join("&");
        let url = format!("{BRAVE_BASE_URL}{path}?{qs}");

        let mut headers: Vec<(&str, &str)> = vec![("Accept", "application/json")];
        if !self.api_key.is_empty() {
            headers.push(("X-Subscription-Token", &self.api_key));
        }

        let response = match self.http.get_with_headers(&url, &headers).await {
            Ok(r) => r,
            Err(e) => {
                return Ok(web_search_error(
                    format!("Brave API request failed: {e}"),
                    None,
                ));
            }
        };

        if response.status != 200 {
            return Ok(web_search_error(
                format!("Brave API error: HTTP {}", response.status),
                Some(response.status),
            ));
        }

        // Parse and format results
        let json_body: Value = match serde_json::from_str(&response.body) {
            Ok(v) => v,
            Err(e) => {
                return Ok(web_search_error(
                    format!("Failed to parse Brave response: {e}"),
                    None,
                ));
            }
        };

        let output = format_results(&endpoint, &json_body);
        let structured = extract_structured_results(&endpoint, &json_body);
        let result_count = structured.len();

        Ok(TronToolResult {
            content: ToolResultBody::Blocks(vec![crate::core::content::ToolResultContent::text(
                output,
            )]),
            details: Some(json!({
                "endpoint": endpoint,
                "query": query,
                "resultCount": result_count,
                "results": structured,
            })),
            is_error: None,
            stop_turn: None,
        })
    }
}

/// Extract structured results from the Brave API JSON body so iOS can
/// render them without parsing the formatted text.
///
/// Returns a JSON array of objects: `{ title, url, snippet, age? }`.
fn extract_structured_results(endpoint: &str, body: &Value) -> Vec<Value> {
    let results = match endpoint {
        "news" | "images" | "videos" => body.get("results").and_then(Value::as_array),
        _ => body
            .get("web")
            .and_then(|w| w.get("results"))
            .and_then(Value::as_array),
    };
    let Some(results) = results else {
        return Vec::new();
    };
    results
        .iter()
        .map(|r| {
            let title = r.get("title").and_then(Value::as_str).unwrap_or("");
            // News/web use `url`; images use `src`; videos use `url`.
            let url = r
                .get("url")
                .and_then(Value::as_str)
                .or_else(|| r.get("src").and_then(Value::as_str))
                .unwrap_or("");
            let snippet = r
                .get("description")
                .and_then(Value::as_str)
                .unwrap_or("");
            let age = r.get("age").and_then(Value::as_str);
            let mut obj = serde_json::Map::new();
            obj.insert("title".into(), json!(title));
            obj.insert("url".into(), json!(url));
            obj.insert("snippet".into(), json!(snippet));
            if let Some(a) = age {
                obj.insert("age".into(), json!(a));
            }
            Value::Object(obj)
        })
        .collect()
}

fn format_results(endpoint: &str, body: &Value) -> String {
    match endpoint {
        "news" => format_news_results(body),
        "images" => format_image_results(body),
        "videos" => format_video_results(body),
        _ => format_web_results(body),
    }
}

fn format_web_results(body: &Value) -> String {
    let results = body
        .get("web")
        .and_then(|w| w.get("results"))
        .and_then(Value::as_array);

    let Some(results) = results else {
        return "No results found.".into();
    };

    if results.is_empty() {
        return "No results found.".into();
    }

    results
        .iter()
        .enumerate()
        .map(|(i, r)| {
            let title = r.get("title").and_then(Value::as_str).unwrap_or("");
            let url = r.get("url").and_then(Value::as_str).unwrap_or("");
            let desc = r.get("description").and_then(Value::as_str).unwrap_or("");
            format!("{}. [{}]({})\n   {}", i + 1, title, url, desc)
        })
        .collect::<Vec<_>>()
        .join("\n\n")
}

fn format_news_results(body: &Value) -> String {
    let results = body.get("results").and_then(Value::as_array);
    let Some(results) = results else {
        return "No news results found.".into();
    };
    if results.is_empty() {
        return "No news results found.".into();
    }
    results
        .iter()
        .enumerate()
        .map(|(i, r)| {
            let title = r.get("title").and_then(Value::as_str).unwrap_or("");
            let url = r.get("url").and_then(Value::as_str).unwrap_or("");
            let desc = r.get("description").and_then(Value::as_str).unwrap_or("");
            let age = r.get("age").and_then(Value::as_str).unwrap_or("");
            format!("{}. [{}]({})\n   {} ({})", i + 1, title, url, desc, age)
        })
        .collect::<Vec<_>>()
        .join("\n\n")
}

fn format_image_results(body: &Value) -> String {
    let results = body.get("results").and_then(Value::as_array);
    let Some(results) = results else {
        return "No image results found.".into();
    };
    if results.is_empty() {
        return "No image results found.".into();
    }
    results
        .iter()
        .enumerate()
        .map(|(i, r)| {
            let title = r.get("title").and_then(Value::as_str).unwrap_or("");
            let src = r.get("src").and_then(Value::as_str).unwrap_or("");
            format!("{}. {} — {}", i + 1, title, src)
        })
        .collect::<Vec<_>>()
        .join("\n")
}

fn format_video_results(body: &Value) -> String {
    let results = body.get("results").and_then(Value::as_array);
    let Some(results) = results else {
        return "No video results found.".into();
    };
    if results.is_empty() {
        return "No video results found.".into();
    }
    results
        .iter()
        .enumerate()
        .map(|(i, r)| {
            let title = r.get("title").and_then(Value::as_str).unwrap_or("");
            let url = r.get("url").and_then(Value::as_str).unwrap_or("");
            let duration = r.get("duration").and_then(Value::as_str).unwrap_or("");
            format!("{}. [{}]({}) [{}]", i + 1, title, url, duration)
        })
        .collect::<Vec<_>>()
        .join("\n")
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;
    use crate::tools::testutil::{extract_text, make_ctx};
    use crate::tools::traits::{HttpRequest, HttpResponse};

    struct MockHttp {
        handler: Box<dyn Fn(&str) -> Result<HttpResponse, String> + Send + Sync>,
    }

    #[async_trait]
    impl HttpClient for MockHttp {
        async fn get(&self, url: &str) -> Result<HttpResponse, ToolError> {
            (self.handler)(url).map_err(|e| ToolError::Internal { message: e })
        }

        async fn request(&self, req: &HttpRequest<'_>) -> Result<HttpResponse, ToolError> {
            self.get(req.url).await
        }
    }

    fn brave_web_response() -> MockHttp {
        MockHttp {
            handler: Box::new(|_| {
                Ok(HttpResponse {
                status: 200,
                body: r#"{"web":{"results":[{"title":"Example","url":"https://example.com","description":"A test result"}]}}"#.into(),
                content_type: Some("application/json".into()),
                headers: HashMap::new(),
            })
            }),
        }
    }

    #[tokio::test]
    async fn valid_query_returns_results() {
        let tool = WebSearchTool::new(Arc::new(brave_web_response()), "key".into());
        let r = tool
            .execute(json!({"query": "test"}), &make_ctx())
            .await
            .unwrap();
        assert!(r.is_error.is_none());
        let text = extract_text(&r);
        assert!(text.contains("Example"));
    }

    #[tokio::test]
    async fn missing_query_returns_error() {
        let tool = WebSearchTool::new(Arc::new(brave_web_response()), "key".into());
        let r = tool.execute(json!({}), &make_ctx()).await.unwrap();
        assert_eq!(r.is_error, Some(true));
    }

    #[tokio::test]
    async fn query_too_long() {
        let tool = WebSearchTool::new(Arc::new(brave_web_response()), "key".into());
        let r = tool
            .execute(json!({"query": "x".repeat(500)}), &make_ctx())
            .await
            .unwrap();
        assert_eq!(r.is_error, Some(true));
        assert!(extract_text(&r).contains("too long"));
    }

    #[tokio::test]
    async fn endpoint_selection() {
        let called_url = std::sync::Arc::new(std::sync::Mutex::new(String::new()));
        let url_clone = called_url.clone();

        let http = Arc::new(MockHttp {
            handler: Box::new(move |url| {
                *url_clone.lock().unwrap() = url.to_string();
                Ok(HttpResponse {
                    status: 200,
                    body: r#"{"results":[]}"#.into(),
                    content_type: Some("application/json".into()),
                    headers: HashMap::new(),
                })
            }),
        });

        let tool = WebSearchTool::new(http, "key".into());
        let _ = tool
            .execute(json!({"query": "test", "endpoint": "news"}), &make_ctx())
            .await;
        let url = called_url.lock().unwrap().clone();
        assert!(url.contains("/news/search"));
    }

    #[tokio::test]
    async fn freshness_filter_passed() {
        let called_url = std::sync::Arc::new(std::sync::Mutex::new(String::new()));
        let url_clone = called_url.clone();

        let http = Arc::new(MockHttp {
            handler: Box::new(move |url| {
                *url_clone.lock().unwrap() = url.to_string();
                Ok(HttpResponse {
                    status: 200,
                    body: r#"{"web":{"results":[]}}"#.into(),
                    content_type: Some("application/json".into()),
                    headers: HashMap::new(),
                })
            }),
        });

        let tool = WebSearchTool::new(http, "key".into());
        let _ = tool
            .execute(json!({"query": "test", "freshness": "pd"}), &make_ctx())
            .await;
        let url = called_url.lock().unwrap().clone();
        assert!(url.contains("freshness=pd"));
    }

    #[tokio::test]
    async fn empty_results_formatted() {
        let http = Arc::new(MockHttp {
            handler: Box::new(|_| {
                Ok(HttpResponse {
                    status: 200,
                    body: r#"{"web":{"results":[]}}"#.into(),
                    content_type: Some("application/json".into()),
                    headers: HashMap::new(),
                })
            }),
        });

        let tool = WebSearchTool::new(http, "key".into());
        let r = tool
            .execute(json!({"query": "test"}), &make_ctx())
            .await
            .unwrap();
        assert!(extract_text(&r).contains("No results"));
    }

    // ─── Error classification ───

    #[test]
    fn classify_by_http_status() {
        assert_eq!(classify_web_search_error(Some(429), ""), "rate_limited");
        assert_eq!(classify_web_search_error(Some(401), ""), "api_key");
        assert_eq!(classify_web_search_error(Some(403), ""), "api_key");
        assert_eq!(classify_web_search_error(Some(408), ""), "timeout");
        assert_eq!(classify_web_search_error(Some(504), ""), "timeout");
    }

    #[test]
    fn classify_by_message_text() {
        assert_eq!(
            classify_web_search_error(None, "Rate limit exceeded"),
            "rate_limited"
        );
        assert_eq!(
            classify_web_search_error(None, "Invalid API key"),
            "api_key"
        );
        assert_eq!(
            classify_web_search_error(None, "Monthly quota exceeded"),
            "quota"
        );
        assert_eq!(
            classify_web_search_error(None, "Request timed out"),
            "timeout"
        );
        assert_eq!(
            classify_web_search_error(None, "Query too long: 500 chars"),
            "invalid_query"
        );
        assert_eq!(
            classify_web_search_error(None, "network unreachable"),
            "network"
        );
    }

    #[test]
    fn classify_unknown_returns_unknown() {
        assert_eq!(
            classify_web_search_error(None, "weird failure"),
            "unknown"
        );
    }

    #[tokio::test]
    async fn http_error_response_includes_structured_details() {
        let http = Arc::new(MockHttp {
            handler: Box::new(|_| {
                Ok(HttpResponse {
                    status: 429,
                    body: String::new(),
                    content_type: Some("application/json".into()),
                    headers: HashMap::new(),
                })
            }),
        });

        let tool = WebSearchTool::new(http, "key".into());
        let r = tool
            .execute(json!({"query": "test"}), &make_ctx())
            .await
            .unwrap();
        assert_eq!(r.is_error, Some(true));
        let details = r.details.as_ref().expect("details present");
        assert_eq!(details["errorClass"], "rate_limited");
        assert_eq!(details["httpStatus"], 429);
        assert!(details["error"].as_str().unwrap().contains("429"));
    }

    #[tokio::test]
    async fn query_too_long_includes_structured_details() {
        let http = Arc::new(MockHttp {
            handler: Box::new(|_| {
                Ok(HttpResponse {
                    status: 200,
                    body: r#"{"web":{"results":[]}}"#.into(),
                    content_type: Some("application/json".into()),
                    headers: HashMap::new(),
                })
            }),
        });
        let tool = WebSearchTool::new(http, "key".into());
        let r = tool
            .execute(json!({"query": "x".repeat(500)}), &make_ctx())
            .await
            .unwrap();
        assert_eq!(r.is_error, Some(true));
        let details = r.details.as_ref().expect("details present");
        assert_eq!(details["errorClass"], "invalid_query");
        assert!(details.get("httpStatus").is_some_and(|v| v.is_null()));
    }

    #[tokio::test]
    async fn successful_search_has_no_error_class_in_details() {
        let tool = WebSearchTool::new(Arc::new(brave_web_response()), "key".into());
        let r = tool
            .execute(json!({"query": "test"}), &make_ctx())
            .await
            .unwrap();
        assert!(r.is_error.is_none());
        let details = r.details.as_ref().expect("details present");
        assert!(details.get("errorClass").is_none());
        assert!(details.get("error").is_none());
    }

    // ─── Structured results ───

    #[tokio::test]
    async fn web_results_emitted_as_structured_details() {
        let tool = WebSearchTool::new(Arc::new(brave_web_response()), "key".into());
        let r = tool
            .execute(json!({"query": "test"}), &make_ctx())
            .await
            .unwrap();
        let details = r.details.as_ref().unwrap();
        let results = details["results"].as_array().expect("results array");
        assert_eq!(results.len(), 1);
        assert_eq!(results[0]["title"], "Example");
        assert_eq!(results[0]["url"], "https://example.com");
        assert_eq!(results[0]["snippet"], "A test result");
        assert_eq!(details["resultCount"], 1);
    }

    #[tokio::test]
    async fn news_results_include_age() {
        let http = Arc::new(MockHttp {
            handler: Box::new(|_| {
                Ok(HttpResponse {
                    status: 200,
                    body: r#"{"results":[{"title":"Breaking","url":"https://news.example","description":"today","age":"2h"}]}"#.into(),
                    content_type: Some("application/json".into()),
                    headers: HashMap::new(),
                })
            }),
        });
        let tool = WebSearchTool::new(http, "key".into());
        let r = tool
            .execute(json!({"query": "breaking", "endpoint": "news"}), &make_ctx())
            .await
            .unwrap();
        let results = r.details.as_ref().unwrap()["results"].as_array().unwrap();
        assert_eq!(results.len(), 1);
        assert_eq!(results[0]["age"], "2h");
    }

    #[tokio::test]
    async fn image_results_use_src_as_url() {
        let http = Arc::new(MockHttp {
            handler: Box::new(|_| {
                Ok(HttpResponse {
                    status: 200,
                    body: r#"{"results":[{"title":"Cat","src":"https://img.example/cat.jpg"}]}"#.into(),
                    content_type: Some("application/json".into()),
                    headers: HashMap::new(),
                })
            }),
        });
        let tool = WebSearchTool::new(http, "key".into());
        let r = tool
            .execute(json!({"query": "cat", "endpoint": "images"}), &make_ctx())
            .await
            .unwrap();
        let results = r.details.as_ref().unwrap()["results"].as_array().unwrap();
        assert_eq!(results[0]["title"], "Cat");
        assert_eq!(results[0]["url"], "https://img.example/cat.jpg");
    }

    #[tokio::test]
    async fn empty_results_emits_empty_array() {
        let http = Arc::new(MockHttp {
            handler: Box::new(|_| {
                Ok(HttpResponse {
                    status: 200,
                    body: r#"{"web":{"results":[]}}"#.into(),
                    content_type: Some("application/json".into()),
                    headers: HashMap::new(),
                })
            }),
        });
        let tool = WebSearchTool::new(http, "key".into());
        let r = tool
            .execute(json!({"query": "test"}), &make_ctx())
            .await
            .unwrap();
        let details = r.details.as_ref().unwrap();
        assert_eq!(details["results"].as_array().unwrap().len(), 0);
        assert_eq!(details["resultCount"], 0);
    }
}
