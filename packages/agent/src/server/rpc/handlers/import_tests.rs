use super::*;
use crate::server::rpc::handlers::test_helpers::make_test_context;
use serde_json::json;
use std::io::Write;
use tempfile::tempdir;

fn write_sample_session_file(dir: &std::path::Path) -> std::path::PathBuf {
    let file = dir.join("sample-uuid.jsonl");
    let mut f = std::fs::File::create(&file).unwrap();

    writeln!(f, "{}", json!({
        "type": "user", "uuid": "u1",
        "timestamp": "2026-01-01T00:00:00Z", "promptId": "p1",
        "message": { "role": "user", "content": "Hello" }
    })).unwrap();

    writeln!(f, "{}", json!({
        "type": "assistant", "uuid": "a1", "parentUuid": "u1",
        "timestamp": "2026-01-01T00:00:01Z",
        "message": {
            "id": "msg_01", "role": "assistant",
            "content": [{ "type": "text", "text": "Hi there! How can I help?" }],
            "stop_reason": "end_turn",
            "usage": { "input_tokens": 100, "output_tokens": 50 },
            "model": "claude-opus-4-6"
        }
    })).unwrap();

    file
}

#[tokio::test]
async fn preview_session_returns_messages() {
    let ctx = make_test_context();
    let dir = tempdir().unwrap();
    let path = write_sample_session_file(dir.path());

    let result = PreviewSessionHandler
        .handle(
            Some(json!({ "sessionPath": path.to_str().unwrap() })),
            &ctx,
        )
        .await
        .unwrap();

    let messages = result["messages"].as_array().unwrap();
    assert!(!messages.is_empty());
    assert_eq!(result["totalMessages"], 2);
}

#[tokio::test]
async fn preview_session_truncates_content() {
    let ctx = make_test_context();
    let dir = tempdir().unwrap();
    let file = dir.path().join("long.jsonl");
    let mut f = std::fs::File::create(&file).unwrap();

    let long_text = "x".repeat(500);
    writeln!(f, "{}", json!({
        "type": "user", "uuid": "u1",
        "timestamp": "2026-01-01T00:00:00Z", "promptId": "p1",
        "message": { "role": "user", "content": long_text }
    })).unwrap();
    writeln!(f, "{}", json!({
        "type": "assistant", "uuid": "a1", "parentUuid": "u1",
        "timestamp": "2026-01-01T00:00:01Z",
        "message": {
            "id": "msg_01", "role": "assistant",
            "content": [{ "type": "text", "text": "ok" }],
            "stop_reason": "end_turn",
            "usage": { "input_tokens": 10, "output_tokens": 5 },
            "model": "claude-opus-4-6"
        }
    })).unwrap();

    let result = PreviewSessionHandler
        .handle(Some(json!({ "sessionPath": file.to_str().unwrap() })), &ctx)
        .await
        .unwrap();

    let preview = result["messages"][0]["contentPreview"].as_str().unwrap();
    assert!(preview.len() <= 204); // 200 + "…" (multi-byte)
}

#[tokio::test]
async fn execute_import_creates_session() {
    let ctx = make_test_context();
    let dir = tempdir().unwrap();
    let path = write_sample_session_file(dir.path());

    let result = ExecuteImportHandler
        .handle(
            Some(json!({
                "sessionPath": path.to_str().unwrap(),
                "workingDirectory": "/tmp/test-project"
            })),
            &ctx,
        )
        .await
        .unwrap();

    assert!(result["sessionId"].as_str().unwrap().starts_with("sess_"));
    assert_eq!(result["alreadyImported"], false);
    assert!(result["eventCount"].as_i64().unwrap() > 0);
}

#[tokio::test]
async fn execute_import_duplicate_returns_existing() {
    let ctx = make_test_context();
    let dir = tempdir().unwrap();
    let path = write_sample_session_file(dir.path());

    let first = ExecuteImportHandler
        .handle(
            Some(json!({
                "sessionPath": path.to_str().unwrap(),
                "workingDirectory": "/tmp/test-project"
            })),
            &ctx,
        )
        .await
        .unwrap();

    let second = ExecuteImportHandler
        .handle(
            Some(json!({
                "sessionPath": path.to_str().unwrap(),
                "workingDirectory": "/tmp/test-project"
            })),
            &ctx,
        )
        .await
        .unwrap();

    assert_eq!(second["alreadyImported"], true);
    assert_eq!(
        second["existingSessionId"].as_str().unwrap(),
        first["sessionId"].as_str().unwrap()
    );
}

#[tokio::test]
async fn execute_import_missing_path() {
    let ctx = make_test_context();
    let result = ExecuteImportHandler.handle(Some(json!({})), &ctx).await;
    assert!(result.is_err());
}

#[tokio::test]
async fn preview_missing_path() {
    let ctx = make_test_context();
    let result = PreviewSessionHandler.handle(Some(json!({})), &ctx).await;
    assert!(result.is_err());
}
