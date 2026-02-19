//! Search handlers: content, events.

use async_trait::async_trait;
use serde_json::Value;
use tracing::instrument;

use crate::rpc::context::RpcContext;
use crate::rpc::errors::RpcError;
use crate::rpc::handlers::require_string_param;
use crate::rpc::registry::MethodHandler;

/// Search event content using FTS5.
pub struct ContentSearchHandler;

#[async_trait]
impl MethodHandler for ContentSearchHandler {
    #[instrument(skip(self, ctx), fields(method = "search.content"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let query = require_string_param(params.as_ref(), "query")?;

        let session_id = params
            .as_ref()
            .and_then(|p| p.get("sessionId"))
            .and_then(Value::as_str);

        let limit = params
            .as_ref()
            .and_then(|p| p.get("limit"))
            .and_then(Value::as_i64);

        let results = if let Some(sid) = session_id {
            ctx.event_store
                .search_in_session(sid, &query, limit)
                .map_err(|e| RpcError::Internal {
                    message: e.to_string(),
                })?
        } else {
            ctx.event_store
                .search(
                    &query,
                    &tron_events::sqlite::repositories::search::SearchOptions {
                        limit,
                        ..Default::default()
                    },
                )
                .map_err(|e| RpcError::Internal {
                    message: e.to_string(),
                })?
        };

        let wire: Vec<Value> = results
            .iter()
            .map(|r| {
                serde_json::json!({
                    "eventId": r.event_id,
                    "sessionId": r.session_id,
                    "type": r.event_type.to_string(),
                    "timestamp": r.timestamp,
                    "snippet": r.snippet,
                    "score": r.score,
                })
            })
            .collect();

        Ok(serde_json::json!({ "results": wire }))
    }
}

/// Search events in a session.
pub struct EventSearchHandler;

#[async_trait]
impl MethodHandler for EventSearchHandler {
    #[instrument(skip(self, ctx), fields(method = "search.events"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let query = require_string_param(params.as_ref(), "query")?;

        let session_id = params
            .as_ref()
            .and_then(|p| p.get("sessionId"))
            .and_then(Value::as_str);

        let limit = params
            .as_ref()
            .and_then(|p| p.get("limit"))
            .and_then(Value::as_i64);

        let results = if let Some(sid) = session_id {
            ctx.event_store
                .search_in_session(sid, &query, limit)
                .map_err(|e| RpcError::Internal {
                    message: e.to_string(),
                })?
        } else {
            ctx.event_store
                .search(
                    &query,
                    &tron_events::sqlite::repositories::search::SearchOptions {
                        limit,
                        ..Default::default()
                    },
                )
                .map_err(|e| RpcError::Internal {
                    message: e.to_string(),
                })?
        };

        let wire: Vec<Value> = results
            .iter()
            .map(|r| {
                serde_json::json!({
                    "eventId": r.event_id,
                    "sessionId": r.session_id,
                    "type": r.event_type.to_string(),
                    "snippet": r.snippet,
                    "score": r.score,
                })
            })
            .collect();

        Ok(serde_json::json!({ "results": wire }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::rpc::handlers::test_helpers::make_test_context;
    use serde_json::json;

    #[tokio::test]
    async fn content_search_no_results() {
        let ctx = make_test_context();
        let result = ContentSearchHandler
            .handle(Some(json!({"query": "nonexistent"})), &ctx)
            .await
            .unwrap();
        assert!(result["results"].as_array().unwrap().is_empty());
    }

    #[tokio::test]
    async fn content_search_missing_query() {
        let ctx = make_test_context();
        let err = ContentSearchHandler
            .handle(Some(json!({})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
    }

    #[tokio::test]
    async fn content_search_with_session_filter() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", Some("t"))
            .unwrap();

        let result = ContentSearchHandler
            .handle(Some(json!({"query": "hello", "sessionId": sid})), &ctx)
            .await
            .unwrap();
        assert!(result["results"].is_array());
    }

    #[tokio::test]
    async fn event_search_no_results() {
        let ctx = make_test_context();
        let result = EventSearchHandler
            .handle(Some(json!({"query": "nothing"})), &ctx)
            .await
            .unwrap();
        assert!(result["results"].as_array().unwrap().is_empty());
    }

    #[tokio::test]
    async fn event_search_missing_query() {
        let ctx = make_test_context();
        let err = EventSearchHandler
            .handle(Some(json!({})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
    }
}
