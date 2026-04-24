//! RPC handler tests for the Prompt Library.

use super::*;
use crate::server::rpc::errors::RpcError;
use crate::server::rpc::handlers::test_helpers::make_test_context;
use crate::server::rpc::registry::MethodHandler;
use serde_json::json;

// ─── promptHistory.list ─────────────────────────────────────────────────

#[tokio::test]
async fn history_list_empty_store_returns_empty_page() {
    let ctx = make_test_context();
    let out = ListHistoryHandler
        .handle(Some(json!({})), &ctx)
        .await
        .unwrap();
    assert_eq!(out["items"].as_array().unwrap().len(), 0);
    assert!(out["nextCursor"].is_null());
}

#[tokio::test]
async fn history_list_returns_recorded_prompts_newest_first() {
    let ctx = make_test_context();
    let pool = ctx.event_store.pool();

    // Seed 3 distinct prompts with staggered timestamps.
    for (i, text) in ["first", "second", "third"].iter().enumerate() {
        crate::prompt_library::store::record_prompt(pool, text).unwrap();
        if i < 2 {
            std::thread::sleep(std::time::Duration::from_millis(5));
        }
    }

    let out = ListHistoryHandler
        .handle(Some(json!({ "limit": 10 })), &ctx)
        .await
        .unwrap();
    let items = out["items"].as_array().unwrap();
    assert_eq!(items.len(), 3);
    assert_eq!(items[0]["text"], "third");
    assert_eq!(items[2]["text"], "first");
}

#[tokio::test]
async fn history_list_rejects_limit_too_large() {
    let ctx = make_test_context();
    let err = ListHistoryHandler
        .handle(Some(json!({ "limit": 500 })), &ctx)
        .await
        .unwrap_err();
    assert!(matches!(err, RpcError::InvalidParams { .. }));
}

#[tokio::test]
async fn history_list_rejects_malformed_cursor() {
    let ctx = make_test_context();
    let err = ListHistoryHandler
        .handle(Some(json!({ "cursor": "!!!not-base64!!!" })), &ctx)
        .await
        .unwrap_err();
    assert!(matches!(err, RpcError::InvalidParams { .. }));
}

#[tokio::test]
async fn history_list_rejects_overlong_query() {
    let ctx = make_test_context();
    let err = ListHistoryHandler
        .handle(Some(json!({ "query": "x".repeat(500) })), &ctx)
        .await
        .unwrap_err();
    assert!(matches!(err, RpcError::InvalidParams { .. }));
}

#[tokio::test]
async fn history_list_pagination_roundtrip() {
    let ctx = make_test_context();
    let pool = ctx.event_store.pool();

    for i in 0..5 {
        crate::prompt_library::store::record_prompt(pool, &format!("msg {i}")).unwrap();
        std::thread::sleep(std::time::Duration::from_millis(2));
    }

    let page1 = ListHistoryHandler
        .handle(Some(json!({ "limit": 2 })), &ctx)
        .await
        .unwrap();
    let cursor = page1["nextCursor"].as_str().unwrap().to_string();
    assert_eq!(page1["items"].as_array().unwrap().len(), 2);

    let page2 = ListHistoryHandler
        .handle(Some(json!({ "limit": 10, "cursor": cursor })), &ctx)
        .await
        .unwrap();
    assert_eq!(page2["items"].as_array().unwrap().len(), 3);
    assert!(page2["nextCursor"].is_null());
}

// ─── promptHistory.delete ───────────────────────────────────────────────

#[tokio::test]
async fn history_delete_existing_returns_true() {
    let ctx = make_test_context();
    let pool = ctx.event_store.pool();
    crate::prompt_library::store::record_prompt(pool, "hello").unwrap();
    let page = crate::prompt_library::store::list_history(pool, 10, None, None).unwrap();
    let id = page.items[0].id.clone();

    let out = DeleteHistoryHandler
        .handle(Some(json!({ "id": id })), &ctx)
        .await
        .unwrap();
    assert_eq!(out["deleted"], true);
}

#[tokio::test]
async fn history_delete_missing_returns_false() {
    let ctx = make_test_context();
    let out = DeleteHistoryHandler
        .handle(Some(json!({ "id": "nonexistent" })), &ctx)
        .await
        .unwrap();
    assert_eq!(out["deleted"], false);
}

#[tokio::test]
async fn history_delete_rejects_missing_id() {
    let ctx = make_test_context();
    let err = DeleteHistoryHandler
        .handle(Some(json!({})), &ctx)
        .await
        .unwrap_err();
    assert!(matches!(err, RpcError::InvalidParams { .. }));
}

// ─── promptHistory.clear ────────────────────────────────────────────────

#[tokio::test]
async fn history_clear_removes_all_rows() {
    let ctx = make_test_context();
    let pool = ctx.event_store.pool();
    for t in ["a", "b", "c"] {
        crate::prompt_library::store::record_prompt(pool, t).unwrap();
    }

    let out = ClearHistoryHandler.handle(None, &ctx).await.unwrap();
    assert_eq!(out["deletedCount"], 3);

    let remaining = crate::prompt_library::store::list_history(pool, 10, None, None).unwrap();
    assert_eq!(remaining.items.len(), 0);
}

// ─── promptSnippet.list ─────────────────────────────────────────────────

#[tokio::test]
async fn snippet_list_empty_returns_empty_items() {
    let ctx = make_test_context();
    let out = ListSnippetsHandler.handle(None, &ctx).await.unwrap();
    assert_eq!(out["items"].as_array().unwrap().len(), 0);
}

#[tokio::test]
async fn snippet_list_returns_sorted_items() {
    let ctx = make_test_context();
    let pool = ctx.event_store.pool();
    crate::prompt_library::store::create_snippet(pool, "first", "alpha").unwrap();
    std::thread::sleep(std::time::Duration::from_millis(5));
    crate::prompt_library::store::create_snippet(pool, "second", "beta").unwrap();

    let out = ListSnippetsHandler.handle(None, &ctx).await.unwrap();
    let items = out["items"].as_array().unwrap();
    assert_eq!(items.len(), 2);
    assert_eq!(items[0]["name"], "second");
}

// ─── promptSnippet.create ───────────────────────────────────────────────

#[tokio::test]
async fn snippet_create_returns_snippet() {
    let ctx = make_test_context();
    let out = CreateSnippetHandler
        .handle(Some(json!({ "name": "Greeting", "text": "Hello!" })), &ctx)
        .await
        .unwrap();
    assert_eq!(out["snippet"]["name"], "Greeting");
    assert_eq!(out["snippet"]["text"], "Hello!");
    assert!(out["snippet"]["id"].is_string());
}

#[tokio::test]
async fn snippet_create_rejects_empty_name() {
    let ctx = make_test_context();
    let err = CreateSnippetHandler
        .handle(Some(json!({ "name": "   ", "text": "body" })), &ctx)
        .await
        .unwrap_err();
    assert!(matches!(err, RpcError::InvalidParams { .. }));
}

#[tokio::test]
async fn snippet_create_rejects_long_name() {
    let ctx = make_test_context();
    let long = "n".repeat(101);
    let err = CreateSnippetHandler
        .handle(Some(json!({ "name": long, "text": "body" })), &ctx)
        .await
        .unwrap_err();
    assert!(matches!(err, RpcError::InvalidParams { .. }));
}

#[tokio::test]
async fn snippet_create_rejects_empty_text() {
    let ctx = make_test_context();
    let err = CreateSnippetHandler
        .handle(Some(json!({ "name": "Name", "text": "" })), &ctx)
        .await
        .unwrap_err();
    assert!(matches!(err, RpcError::InvalidParams { .. }));
}

#[tokio::test]
async fn snippet_create_rejects_missing_params() {
    let ctx = make_test_context();
    let err = CreateSnippetHandler
        .handle(Some(json!({ "name": "only-name" })), &ctx)
        .await
        .unwrap_err();
    assert!(matches!(err, RpcError::InvalidParams { .. }));
}

// ─── promptSnippet.update ───────────────────────────────────────────────

#[tokio::test]
async fn snippet_update_renames() {
    let ctx = make_test_context();
    let pool = ctx.event_store.pool();
    let s = crate::prompt_library::store::create_snippet(pool, "old", "body").unwrap();

    let out = UpdateSnippetHandler
        .handle(Some(json!({ "id": s.id, "name": "new" })), &ctx)
        .await
        .unwrap();
    assert_eq!(out["snippet"]["name"], "new");
    assert_eq!(out["snippet"]["text"], "body");
}

#[tokio::test]
async fn snippet_update_with_no_mutating_fields_errors() {
    let ctx = make_test_context();
    let pool = ctx.event_store.pool();
    let s = crate::prompt_library::store::create_snippet(pool, "n", "t").unwrap();

    let err = UpdateSnippetHandler
        .handle(Some(json!({ "id": s.id })), &ctx)
        .await
        .unwrap_err();
    assert!(matches!(err, RpcError::InvalidParams { .. }));
}

#[tokio::test]
async fn snippet_update_missing_id_returns_not_found() {
    let ctx = make_test_context();
    let err = UpdateSnippetHandler
        .handle(Some(json!({ "id": "nonexistent", "name": "new" })), &ctx)
        .await
        .unwrap_err();
    assert!(matches!(err, RpcError::NotFound { .. }));
}

// ─── promptSnippet.delete ───────────────────────────────────────────────

#[tokio::test]
async fn snippet_delete_returns_true_on_first_then_false() {
    let ctx = make_test_context();
    let pool = ctx.event_store.pool();
    let s = crate::prompt_library::store::create_snippet(pool, "n", "t").unwrap();

    let first = DeleteSnippetHandler
        .handle(Some(json!({ "id": s.id.clone() })), &ctx)
        .await
        .unwrap();
    assert_eq!(first["deleted"], true);

    let second = DeleteSnippetHandler
        .handle(Some(json!({ "id": s.id })), &ctx)
        .await
        .unwrap();
    assert_eq!(second["deleted"], false);
}

#[tokio::test]
async fn snippet_delete_rejects_missing_id() {
    let ctx = make_test_context();
    let err = DeleteSnippetHandler
        .handle(Some(json!({})), &ctx)
        .await
        .unwrap_err();
    assert!(matches!(err, RpcError::InvalidParams { .. }));
}

// ─── promptSnippet.get ──────────────────────────────────────────────────

#[tokio::test]
async fn snippet_get_returns_snippet() {
    let ctx = make_test_context();
    let pool = ctx.event_store.pool();
    let s = crate::prompt_library::store::create_snippet(pool, "n", "t").unwrap();

    let out = GetSnippetHandler
        .handle(Some(json!({ "id": s.id.clone() })), &ctx)
        .await
        .unwrap();
    assert_eq!(out["snippet"]["id"], s.id);
}

#[tokio::test]
async fn snippet_get_missing_returns_not_found() {
    let ctx = make_test_context();
    let err = GetSnippetHandler
        .handle(Some(json!({ "id": "nope" })), &ctx)
        .await
        .unwrap_err();
    assert!(matches!(err, RpcError::NotFound { .. }));
}
