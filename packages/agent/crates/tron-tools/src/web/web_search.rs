//! `WebSearch` tool — Brave Search API integration.
//!
//! Searches the web using the Brave Search API with support for multiple
//! endpoints (web, news, images, videos), domain filtering, and freshness.

use std::sync::Arc;

use async_trait::async_trait;
use serde_json::{Value, json};
use tron_core::tools::{Tool, ToolCategory, ToolResultBody, TronToolResult, error_result};

use crate::errors::ToolError;
use crate::traits::{HttpClient, ToolContext, TronTool};
use crate::utils::schema::ToolSchemaBuilder;
use crate::utils::validation::{get_optional_string, get_optional_u64, validate_required_string};

const BRAVE_BASE_URL: &str = "https://api.search.brave.com";
const MAX_QUERY_LENGTH: usize = 400;

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
            return Ok(error_result(format!(
                "Query too long: {} chars (max {MAX_QUERY_LENGTH})",
                query.len()
            )));
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

        let response = self
            .http
            .get_with_headers(&url, &headers)
            .await
            .map_err(|e| ToolError::Internal {
                message: format!("Brave API request failed: {e}"),
            })?;

        if response.status != 200 {
            return Ok(error_result(format!(
                "Brave API error: HTTP {}",
                response.status
            )));
        }

        // Parse and format results
        let json_body: Value =
            serde_json::from_str(&response.body).map_err(|e| ToolError::Internal {
                message: format!("Failed to parse Brave response: {e}"),
            })?;

        let output = format_results(&endpoint, &json_body);

        let result_count = match endpoint.as_str() {
            "news" | "images" | "videos" => json_body
                .get("results")
                .and_then(Value::as_array)
                .map_or(0, Vec::len),
            _ => json_body
                .get("web")
                .and_then(|w| w.get("results"))
                .and_then(Value::as_array)
                .map_or(0, Vec::len),
        };

        Ok(TronToolResult {
            content: ToolResultBody::Blocks(vec![tron_core::content::ToolResultContent::text(
                output,
            )]),
            details: Some(json!({
                "endpoint": endpoint,
                "query": query,
                "resultCount": result_count,
            })),
            is_error: None,
            stop_turn: None,
        })
    }
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
    use crate::testutil::{extract_text, make_ctx};
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

    fn brave_web_response() -> MockHttp {
        MockHttp {
            handler: Box::new(|_| {
                Ok(HttpResponse {
                status: 200,
                body: r#"{"web":{"results":[{"title":"Example","url":"https://example.com","description":"A test result"}]}}"#.into(),
                content_type: Some("application/json".into()),
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
}
