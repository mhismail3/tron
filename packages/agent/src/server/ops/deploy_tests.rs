use super::*;
use std::sync::atomic::Ordering;

// ── Sentinel serialization ─────────────────────────────────────────

fn sample_sentinel() -> RestartSentinel {
    RestartSentinel {
        action: "deploy".into(),
        timestamp: "2026-02-23T10:00:00.000Z".into(),
        commit: "abc123".into(),
        previous_commit: "def456".into(),
        status: "restarting".into(),
        completed_at: None,
        initiated_by: "test".into(),
        self_test: None,
        binary_sha256: None,
    }
}

#[test]
fn sentinel_serialization_roundtrip() {
    let s = sample_sentinel();
    let json = serde_json::to_string(&s).unwrap();
    let back: RestartSentinel = serde_json::from_str(&json).unwrap();
    assert_eq!(back.action, "deploy");
    assert_eq!(back.commit, "abc123");
    assert_eq!(back.previous_commit, "def456");
    assert_eq!(back.status, "restarting");
    assert!(back.completed_at.is_none());
}

#[test]
fn sentinel_camel_case_wire_format() {
    let s = sample_sentinel();
    let json = serde_json::to_string(&s).unwrap();
    assert!(json.contains("previousCommit"));
    assert!(!json.contains("previous_commit"));
}

#[test]
fn sentinel_skips_none_completed_at() {
    let s = sample_sentinel();
    let json = serde_json::to_string(&s).unwrap();
    assert!(!json.contains("completedAt"));
}

#[test]
fn sentinel_includes_completed_at_when_set() {
    let mut s = sample_sentinel();
    s.completed_at = Some("2026-02-23T10:05:00.000Z".into());
    let json = serde_json::to_string(&s).unwrap();
    assert!(json.contains("completedAt"));
    assert!(json.contains("2026-02-23T10:05:00.000Z"));
}

// ── DeployStatusResponse serialization ─────────────────────────────

#[test]
fn status_response_serialization() {
    let resp = DeployStatusResponse {
        version: "0.1.0".into(),
        deployed_commit: "abc123".into(),
        binary_path: "/home/user/.tron/system/Tron.app/Contents/MacOS/tron".into(),
        binary_exists: true,
        binary_modified: Some("2026-02-23T10:00:00Z".into()),
        restart_initiated: false,
        sentinel: Some(sample_sentinel()),
    };
    let json = serde_json::to_string(&resp).unwrap();
    let v: Value = serde_json::from_str(&json).unwrap();
    assert_eq!(v["version"], "0.1.0");
    assert_eq!(v["deployedCommit"], "abc123");
    assert_eq!(v["binaryExists"], true);
    assert_eq!(v["restartInitiated"], false);
    assert!(v["sentinel"].is_object());
}

#[test]
fn status_response_skips_none_fields() {
    let resp = DeployStatusResponse {
        version: "0.1.0".into(),
        deployed_commit: "abc123".into(),
        binary_path: "/tmp/tron".into(),
        binary_exists: false,
        binary_modified: None,
        restart_initiated: false,
        sentinel: None,
    };
    let json = serde_json::to_string(&resp).unwrap();
    assert!(!json.contains("binaryModified"));
    assert!(!json.contains("sentinel"));
}

// ── DeployRestartRequest deserialization ────────────────────────────

#[test]
fn restart_request_defaults() {
    let req: DeployRestartRequest = serde_json::from_str("{}").unwrap();
    assert_eq!(req.delay_ms, 5000);
    assert!(req.source_binary.is_none());
}

#[test]
fn restart_request_custom_delay() {
    let req: DeployRestartRequest = serde_json::from_str(r#"{"delayMs": 3000}"#).unwrap();
    assert_eq!(req.delay_ms, 3000);
}

#[test]
fn restart_request_with_source() {
    let req: DeployRestartRequest =
        serde_json::from_str(r#"{"sourceBinary": "/tmp/tron"}"#).unwrap();
    assert_eq!(req.source_binary.as_deref(), Some("/tmp/tron"));
}

#[test]
fn restart_request_all_fields() {
    let req: DeployRestartRequest =
        serde_json::from_str(r#"{"delayMs": 2000, "sourceBinary": "/usr/bin/tron"}"#).unwrap();
    assert_eq!(req.delay_ms, 2000);
    assert_eq!(req.source_binary.as_deref(), Some("/usr/bin/tron"));
}

// ── DeployRestartResponse serialization ────────────────────────────

#[test]
fn restart_response_serialization() {
    let resp = DeployRestartResponse {
        ok: true,
        restarting_in_ms: 5000,
        commit: "abc123".into(),
        previous_commit: "def456".into(),
    };
    let json = serde_json::to_string(&resp).unwrap();
    let v: Value = serde_json::from_str(&json).unwrap();
    assert_eq!(v["ok"], true);
    assert_eq!(v["restartingInMs"], 5000);
    assert_eq!(v["commit"], "abc123");
    assert_eq!(v["previousCommit"], "def456");
}

// ── File I/O helpers ───────────────────────────────────────────────

#[test]
fn read_deployed_commit_exists() {
    let dir = tempfile::tempdir().unwrap();
    std::fs::write(dir.path().join("deployed-commit"), "abc123\n").unwrap();
    assert_eq!(read_deployed_commit(dir.path()), "abc123");
}

#[test]
fn read_deployed_commit_missing() {
    let dir = tempfile::tempdir().unwrap();
    assert_eq!(read_deployed_commit(dir.path()), "unknown");
}

#[test]
fn read_sentinel_exists() {
    let dir = tempfile::tempdir().unwrap();
    let s = sample_sentinel();
    let json = serde_json::to_string_pretty(&s).unwrap();
    std::fs::write(dir.path().join("restart-sentinel.json"), json).unwrap();
    let loaded = read_sentinel(dir.path()).unwrap();
    assert_eq!(loaded.commit, "abc123");
    assert_eq!(loaded.status, "restarting");
}

#[test]
fn read_sentinel_missing() {
    let dir = tempfile::tempdir().unwrap();
    assert!(read_sentinel(dir.path()).is_none());
}

#[test]
fn read_sentinel_corrupt_json() {
    let dir = tempfile::tempdir().unwrap();
    std::fs::write(dir.path().join("restart-sentinel.json"), "not json {{{").unwrap();
    assert!(read_sentinel(dir.path()).is_none());
}

#[test]
fn write_sentinel_creates_file() {
    let dir = tempfile::tempdir().unwrap();
    let s = sample_sentinel();
    write_sentinel(dir.path(), &s).unwrap();
    let contents = std::fs::read_to_string(dir.path().join("restart-sentinel.json")).unwrap();
    let back: RestartSentinel = serde_json::from_str(&contents).unwrap();
    assert_eq!(back.commit, "abc123");
}

#[test]
fn write_sentinel_creates_parent_dir() {
    let dir = tempfile::tempdir().unwrap();
    let nested = dir.path().join("sub/artifacts");
    let s = sample_sentinel();
    write_sentinel(&nested, &s).unwrap();
    assert!(nested.join("restart-sentinel.json").exists());
}

#[test]
fn complete_sentinel_updates_status() {
    let dir = tempfile::tempdir().unwrap();
    let s = sample_sentinel();
    write_sentinel(dir.path(), &s).unwrap();

    let completed = complete_sentinel(dir.path()).unwrap().unwrap();
    assert_eq!(completed.status, "completed");
    assert!(completed.completed_at.is_some());

    // Verify file was updated on disk
    let on_disk = read_sentinel(dir.path()).unwrap();
    assert_eq!(on_disk.status, "completed");
}

#[test]
fn complete_sentinel_missing_file() {
    let dir = tempfile::tempdir().unwrap();
    assert!(complete_sentinel(dir.path()).unwrap().is_none());
}

#[test]
fn complete_sentinel_already_completed_returns_none() {
    let dir = tempfile::tempdir().unwrap();
    let mut s = sample_sentinel();
    s.status = "completed".into();
    s.completed_at = Some("2026-02-23T10:05:00.000Z".into());
    write_sentinel(dir.path(), &s).unwrap();

    // Already terminal — no transition, returns None
    assert!(complete_sentinel(dir.path()).unwrap().is_none());

    // Sentinel on disk unchanged
    let on_disk = read_sentinel(dir.path()).unwrap();
    assert_eq!(on_disk.status, "completed");
}

#[test]
fn complete_sentinel_rolled_back_returns_none() {
    let dir = tempfile::tempdir().unwrap();
    let mut s = sample_sentinel();
    s.status = "rolled_back".into();
    write_sentinel(dir.path(), &s).unwrap();

    assert!(complete_sentinel(dir.path()).unwrap().is_none());
}

#[test]
fn write_last_deployment_compat() {
    let dir = tempfile::tempdir().unwrap();
    let mut s = sample_sentinel();
    s.status = "completed".into();
    s.completed_at = Some("2026-02-23T10:05:00.000Z".into());
    write_last_deployment(dir.path(), &s).unwrap();

    let contents = std::fs::read_to_string(dir.path().join("last-deployment.json")).unwrap();
    let v: Value = serde_json::from_str(&contents).unwrap();
    assert_eq!(v["status"], "completed");
    assert_eq!(v["commit"], "abc123");
    assert_eq!(v["previousCommit"], "def456");
    assert_eq!(v["timestamp"], "2026-02-23T10:05:00.000Z");
    assert!(v["error"].is_null());
}

// ── Path resolution ────────────────────────────────────────────────

#[test]
#[allow(unsafe_code)]
fn resolve_workspace_root_from_env() {
    let prev = std::env::var("TRON_REPO_ROOT").ok();
    // SAFETY: test-only, single-threaded access to this env var
    unsafe { std::env::set_var("TRON_REPO_ROOT", "/tmp/workspace") };
    let result = resolve_workspace_root();
    assert_eq!(result.as_deref(), Some(Path::new("/tmp/workspace")));
    match prev {
        Some(v) => unsafe { std::env::set_var("TRON_REPO_ROOT", v) },
        None => unsafe { std::env::remove_var("TRON_REPO_ROOT") },
    }
}

#[test]
fn resolve_source_binary_explicit() {
    let result = resolve_source_binary(Some("/usr/local/bin/tron"), None);
    assert_eq!(result.as_deref(), Some(Path::new("/usr/local/bin/tron")));
}

#[test]
fn resolve_source_binary_from_workspace() {
    let result = resolve_source_binary(None, Some(Path::new("/home/user/project")));
    assert_eq!(
        result.as_deref(),
        Some(Path::new("/home/user/project/target/release/tron"))
    );
}

#[test]
fn resolve_source_binary_explicit_overrides_workspace() {
    let result = resolve_source_binary(Some("/explicit"), Some(Path::new("/workspace")));
    assert_eq!(result.as_deref(), Some(Path::new("/explicit")));
}

#[test]
fn resolve_source_binary_none() {
    let result = resolve_source_binary(None, None);
    assert!(result.is_none());
}

// ── Atomic binary install ──────────────────────────────────────────

#[tokio::test]
async fn atomic_install_copies_binary() {
    let dir = tempfile::tempdir().unwrap();
    let src = dir.path().join("source");
    let tgt = dir.path().join("target");
    let bak_dir = dir.path().join("deployment");
    std::fs::write(&src, b"binary content here").unwrap();

    let backup = atomic_binary_install(&src, &tgt, &bak_dir).await.unwrap();

    assert!(backup.is_none());
    assert_eq!(std::fs::read(&tgt).unwrap(), b"binary content here");
}

#[tokio::test]
async fn atomic_install_sets_executable() {
    let dir = tempfile::tempdir().unwrap();
    let src = dir.path().join("source");
    let tgt = dir.path().join("target");
    let bak_dir = dir.path().join("deployment");
    std::fs::write(&src, b"#!/bin/sh\necho hi").unwrap();

    let backup = atomic_binary_install(&src, &tgt, &bak_dir).await.unwrap();

    assert!(backup.is_none());
    let mode = std::fs::metadata(&tgt).unwrap().permissions().mode();
    assert_eq!(mode & 0o755, 0o755);
}

#[tokio::test]
async fn atomic_install_backs_up_existing() {
    let dir = tempfile::tempdir().unwrap();
    let src = dir.path().join("source");
    let tgt = dir.path().join("target");
    let bak_dir = dir.path().join("deployment");
    std::fs::write(&src, b"new binary").unwrap();
    std::fs::write(&tgt, b"old binary").unwrap();

    let backup = atomic_binary_install(&src, &tgt, &bak_dir).await.unwrap();

    assert!(backup.is_some());
    let bak_path = backup.unwrap();
    assert_eq!(bak_path, bak_dir.join("tron.bak"));
    assert_eq!(std::fs::read(&bak_path).unwrap(), b"old binary");
    assert_eq!(std::fs::read(&tgt).unwrap(), b"new binary");
}

#[tokio::test]
async fn atomic_install_no_backup_when_missing() {
    let dir = tempfile::tempdir().unwrap();
    let src = dir.path().join("source");
    let tgt = dir.path().join("target");
    let bak_dir = dir.path().join("deployment");
    std::fs::write(&src, b"new binary").unwrap();

    let backup = atomic_binary_install(&src, &tgt, &bak_dir).await.unwrap();
    assert!(backup.is_none());
}

#[tokio::test]
async fn atomic_install_source_not_found() {
    let dir = tempfile::tempdir().unwrap();
    let src = dir.path().join("nonexistent");
    let tgt = dir.path().join("target");
    let bak_dir = dir.path().join("deployment");

    let err = atomic_binary_install(&src, &tgt, &bak_dir)
        .await
        .unwrap_err();
    assert!(matches!(err, DeployError::SourceNotFound { .. }));
}

#[tokio::test]
async fn atomic_install_overwrites_stale_tmp() {
    let dir = tempfile::tempdir().unwrap();
    let src = dir.path().join("source");
    let tgt = dir.path().join("target");
    let bak_dir = dir.path().join("deployment");
    let stale_tmp = dir.path().join("target.tmp");
    std::fs::write(&src, b"new binary").unwrap();
    std::fs::write(&stale_tmp, b"stale leftover").unwrap();

    let backup = atomic_binary_install(&src, &tgt, &bak_dir).await.unwrap();

    assert!(backup.is_none());
    assert_eq!(std::fs::read(&tgt).unwrap(), b"new binary");
    // .tmp should be gone (renamed to target)
    assert!(!stale_tmp.exists());
}

#[tokio::test]
async fn atomic_install_preserves_content() {
    let dir = tempfile::tempdir().unwrap();
    let src = dir.path().join("source");
    let tgt = dir.path().join("target");
    let bak_dir = dir.path().join("deployment");
    // Write a large-ish binary payload
    let data: Vec<u8> = (0..10_000).map(|i| (i % 256) as u8).collect();
    std::fs::write(&src, &data).unwrap();

    let backup = atomic_binary_install(&src, &tgt, &bak_dir).await.unwrap();

    assert!(backup.is_none());
    assert_eq!(std::fs::read(&tgt).unwrap(), data);
}

// ── Handler tests ──────────────────────────────────────────────────

use crate::server::config::ServerConfig;
use crate::server::rpc::handlers::test_helpers::make_test_context;
use crate::server::rpc::registry::MethodRegistry;
use crate::server::server::TronServer;
use axum::body::Body;
use axum::http::Request;
use tower::ServiceExt;

fn make_metrics_handle() -> metrics_exporter_prometheus::PrometheusHandle {
    metrics_exporter_prometheus::PrometheusBuilder::new()
        .build_recorder()
        .handle()
}

fn make_test_server() -> TronServer {
    let ctx = make_test_context();
    TronServer::new(
        ServerConfig::default(),
        MethodRegistry::new(),
        ctx,
        make_metrics_handle(),
    )
}

fn make_isolated_test_server(deploy_root: &Path) -> TronServer {
    make_test_server().with_deploy_paths(deploy_root.join("tron"), deploy_root.join("deploy"))
}

#[tokio::test]
async fn deploy_status_endpoint_returns_200() {
    let server = make_test_server();
    let app = server.router();

    let req = Request::builder()
        .uri("/deploy/status")
        .body(Body::empty())
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
}

#[tokio::test]
async fn deploy_status_has_version() {
    let server = make_test_server();
    let app = server.router();

    let req = Request::builder()
        .uri("/deploy/status")
        .body(Body::empty())
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    let body = axum::body::to_bytes(resp.into_body(), 10_000)
        .await
        .unwrap();
    let v: Value = serde_json::from_slice(&body).unwrap();
    assert_eq!(v["version"], env!("CARGO_PKG_VERSION"));
    assert!(v["deployedCommit"].is_string());
    assert!(v["binaryPath"].is_string());
    assert_eq!(v["restartInitiated"], false);
}

#[tokio::test]
async fn deploy_restart_rejects_missing_binary() {
    let server = make_test_server();
    let app = server.router();

    let req = Request::builder()
        .method("POST")
        .uri("/deploy/restart")
        .header("content-type", "application/json")
        .body(Body::from(
            r#"{"sourceBinary": "/tmp/definitely-does-not-exist-tron-xyz"}"#,
        ))
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn deploy_restart_rejects_double_restart() {
    let server = make_test_server();
    // Pre-set the flag
    server
        .deploy_restart_initiated()
        .store(true, Ordering::SeqCst);

    let app = server.router();
    let req = Request::builder()
        .method("POST")
        .uri("/deploy/restart")
        .header("content-type", "application/json")
        .body(Body::from(r#"{"sourceBinary": "/tmp/fake"}"#))
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::CONFLICT);
}

#[tokio::test]
async fn deploy_restart_resets_flag_on_error() {
    let server = make_test_server();

    let app = server.router();
    let req = Request::builder()
        .method("POST")
        .uri("/deploy/restart")
        .header("content-type", "application/json")
        .body(Body::from(
            r#"{"sourceBinary": "/tmp/definitely-does-not-exist-tron-xyz"}"#,
        ))
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);

    // Flag should be reset so we can try again
    assert!(!server.deploy_restart_initiated().load(Ordering::SeqCst));
}

#[tokio::test]
async fn deploy_restart_returns_ok_with_commits() {
    let dir = tempfile::tempdir().unwrap();
    let src = dir.path().join("fake-binary");
    std::fs::write(&src, b"fake tron binary").unwrap();

    let server = make_isolated_test_server(dir.path());
    let app = server.router();
    let req = Request::builder()
        .method("POST")
        .uri("/deploy/restart")
        .header("content-type", "application/json")
        .body(Body::from(format!(
            r#"{{"sourceBinary": "{}",  "delayMs": 60000}}"#,
            src.display()
        )))
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let body = axum::body::to_bytes(resp.into_body(), 10_000)
        .await
        .unwrap();
    let v: Value = serde_json::from_slice(&body).unwrap();
    assert_eq!(v["ok"], true);
    assert!(v["commit"].is_string());
    assert!(v["previousCommit"].is_string());

    server.shutdown().shutdown();
}

#[tokio::test]
async fn deploy_restart_default_delay() {
    let dir = tempfile::tempdir().unwrap();
    let src = dir.path().join("fake-binary");
    std::fs::write(&src, b"fake tron binary").unwrap();

    let server = make_isolated_test_server(dir.path());
    let app = server.router();
    let req = Request::builder()
        .method("POST")
        .uri("/deploy/restart")
        .header("content-type", "application/json")
        .body(Body::from(format!(
            r#"{{"sourceBinary": "{}"}}"#,
            src.display()
        )))
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    let body = axum::body::to_bytes(resp.into_body(), 10_000)
        .await
        .unwrap();
    let v: Value = serde_json::from_slice(&body).unwrap();
    assert_eq!(v["restartingInMs"], 5000);

    server.shutdown().shutdown();
}

#[tokio::test]
async fn deploy_restart_custom_delay() {
    let dir = tempfile::tempdir().unwrap();
    let src = dir.path().join("fake-binary");
    std::fs::write(&src, b"fake tron binary").unwrap();

    let server = make_isolated_test_server(dir.path());
    let app = server.router();
    let req = Request::builder()
        .method("POST")
        .uri("/deploy/restart")
        .header("content-type", "application/json")
        .body(Body::from(format!(
            r#"{{"sourceBinary": "{}", "delayMs": 3000}}"#,
            src.display()
        )))
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    let body = axum::body::to_bytes(resp.into_body(), 10_000)
        .await
        .unwrap();
    let v: Value = serde_json::from_slice(&body).unwrap();
    assert_eq!(v["restartingInMs"], 3000);

    server.shutdown().shutdown();
}

#[tokio::test]
async fn deploy_unknown_route_404() {
    let server = make_test_server();
    let app = server.router();
    let req = Request::builder()
        .uri("/deploy/other")
        .body(Body::empty())
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn deploy_restart_does_not_touch_real_binary() {
    let real_binary = crate::core::paths::tron_binary_path();
    if !real_binary.exists() {
        // CI or fresh machine — nothing to protect
        return;
    }
    let before = std::fs::metadata(&real_binary).unwrap();
    let before_len = before.len();
    let before_modified = before.modified().unwrap();

    let dir = tempfile::tempdir().unwrap();
    let src = dir.path().join("fake-binary");
    std::fs::write(&src, b"fake tron binary").unwrap();

    let server = make_isolated_test_server(dir.path());
    let app = server.router();
    let req = Request::builder()
        .method("POST")
        .uri("/deploy/restart")
        .header("content-type", "application/json")
        .body(Body::from(format!(
            r#"{{"sourceBinary": "{}", "delayMs": 60000}}"#,
            src.display()
        )))
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let after = std::fs::metadata(&real_binary).unwrap();
    assert_eq!(after.len(), before_len);
    assert_eq!(after.modified().unwrap(), before_modified);

    server.shutdown().shutdown();
}

#[tokio::test]
async fn deploy_restart_writes_commit_and_sentinel_artifacts() {
    let dir = tempfile::tempdir().unwrap();
    let src = dir.path().join("fake-binary");
    std::fs::write(&src, b"fake tron binary").unwrap();

    let server = make_isolated_test_server(dir.path());
    let app = server.router();
    let req = Request::builder()
        .method("POST")
        .uri("/deploy/restart")
        .header("content-type", "application/json")
        .body(Body::from(format!(
            r#"{{"sourceBinary": "{}", "delayMs": 60000, "sessionId": "sess-123"}}"#,
            src.display()
        )))
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let body = axum::body::to_bytes(resp.into_body(), 10_000)
        .await
        .unwrap();
    let response: Value = serde_json::from_slice(&body).unwrap();

    let deployed_commit =
        std::fs::read_to_string(dir.path().join("deploy").join("deployed-commit")).unwrap();
    assert_eq!(deployed_commit.trim(), response["commit"].as_str().unwrap());

    let sentinel = read_sentinel(&dir.path().join("deploy")).unwrap();
    assert_eq!(sentinel.status, "restarting");
    assert_eq!(sentinel.commit, response["commit"].as_str().unwrap());
    assert_eq!(
        sentinel.previous_commit,
        response["previousCommit"].as_str().unwrap()
    );
    assert_eq!(sentinel.initiated_by, "sess-123");

    server.shutdown().shutdown();
}

#[tokio::test]
async fn deploy_restart_fails_when_deploy_dir_is_not_a_directory() {
    let dir = tempfile::tempdir().unwrap();
    let src = dir.path().join("fake-binary");
    std::fs::write(&src, b"fake tron binary").unwrap();
    std::fs::write(dir.path().join("deploy"), b"not a directory").unwrap();

    let server = make_isolated_test_server(dir.path());
    let app = server.router();
    let req = Request::builder()
        .method("POST")
        .uri("/deploy/restart")
        .header("content-type", "application/json")
        .body(Body::from(format!(
            r#"{{"sourceBinary": "{}", "delayMs": 60000}}"#,
            src.display()
        )))
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::INTERNAL_SERVER_ERROR);
    assert!(!server.deploy_restart_initiated().load(Ordering::SeqCst));
    assert!(read_sentinel(&dir.path().join("deploy")).is_none());
}

// ── Self-test tests ───────────────────────────────────────────────

#[test]
fn self_test_all_pass() {
    let dir = tempfile::tempdir().unwrap();
    let db = dir.path().join("log.db");
    let settings = dir.path().join("settings.json");
    let auth = dir.path().join("auth.json");
    let binary = dir.path().join("tron");

    // Create a valid SQLite DB with events table
    let conn = rusqlite::Connection::open(&db).unwrap();
    conn.execute_batch(
        "CREATE TABLE events (id TEXT PRIMARY KEY); CREATE TABLE sessions (id TEXT PRIMARY KEY);",
    )
    .unwrap();
    drop(conn);

    std::fs::write(&settings, r#"{"server": {}}"#).unwrap();
    std::fs::write(&auth, r#"{"anthropic": "sk-test"}"#).unwrap();
    std::fs::write(&binary, b"#!/bin/sh").unwrap();
    std::fs::set_permissions(&binary, std::fs::Permissions::from_mode(0o755)).unwrap();

    let result = run_self_test(&db, &settings, &auth, &binary, dir.path());
    assert!(result.passed);
    assert!(result.checks.iter().all(|c| c.passed));
}

#[test]
fn self_test_missing_db() {
    let dir = tempfile::tempdir().unwrap();
    let result = run_self_test(
        &dir.path().join("missing.db"),
        &dir.path().join("s.json"),
        &dir.path().join("a.json"),
        &dir.path().join("bin"),
        dir.path(),
    );
    assert!(!result.passed);
    assert!(!result.checks[0].passed); // database
}

#[test]
fn self_test_missing_auth() {
    let dir = tempfile::tempdir().unwrap();
    let db = dir.path().join("log.db");
    let conn = rusqlite::Connection::open(&db).unwrap();
    conn.execute_batch("CREATE TABLE events (id TEXT); CREATE TABLE sessions (id TEXT);")
        .unwrap();
    drop(conn);

    let binary = dir.path().join("tron");
    std::fs::write(&binary, b"bin").unwrap();
    std::fs::set_permissions(&binary, std::fs::Permissions::from_mode(0o755)).unwrap();

    let result = run_self_test(
        &db,
        &dir.path().join("missing.json"),
        &dir.path().join("missing-auth.json"),
        &binary,
        dir.path(),
    );
    assert!(!result.passed);
    let auth_check = result.checks.iter().find(|c| c.name == "auth").unwrap();
    assert!(!auth_check.passed);
}

#[test]
fn self_test_non_executable_binary() {
    let dir = tempfile::tempdir().unwrap();
    let db = dir.path().join("log.db");
    let conn = rusqlite::Connection::open(&db).unwrap();
    conn.execute_batch("CREATE TABLE events (id TEXT); CREATE TABLE sessions (id TEXT);")
        .unwrap();
    drop(conn);

    let settings = dir.path().join("settings.json");
    let auth = dir.path().join("auth.json");
    let binary = dir.path().join("tron");
    std::fs::write(&settings, "{}").unwrap();
    std::fs::write(&auth, r#"{"a":"b"}"#).unwrap();
    std::fs::write(&binary, b"bin").unwrap();
    std::fs::set_permissions(&binary, std::fs::Permissions::from_mode(0o644)).unwrap();

    let result = run_self_test(&db, &settings, &auth, &binary, dir.path());
    assert!(!result.passed);
    let bin_check = result.checks.iter().find(|c| c.name == "binary").unwrap();
    assert!(!bin_check.passed);
}

#[test]
fn self_test_result_serialization() {
    let result = SelfTestResult {
        passed: true,
        checks: vec![SelfTestCheck {
            name: "database".into(),
            passed: true,
            detail: None,
        }],
        timestamp: "2026-03-09T10:00:00.000Z".into(),
    };
    let json = serde_json::to_string(&result).unwrap();
    let back: SelfTestResult = serde_json::from_str(&json).unwrap();
    assert!(back.passed);
    assert_eq!(back.checks.len(), 1);
}

#[test]
fn sentinel_with_new_fields_roundtrip() {
    let s = RestartSentinel {
        action: "deploy".into(),
        timestamp: "2026-03-09T10:00:00.000Z".into(),
        commit: "abc123".into(),
        previous_commit: "def456".into(),
        status: "completed".into(),
        completed_at: Some("2026-03-09T10:01:00.000Z".into()),
        initiated_by: "session-123".into(),
        self_test: Some(SelfTestResult {
            passed: true,
            checks: vec![SelfTestCheck {
                name: "database".into(),
                passed: true,
                detail: None,
            }],
            timestamp: "2026-03-09T10:00:30.000Z".into(),
        }),
        binary_sha256: None,
    };
    let json = serde_json::to_string_pretty(&s).unwrap();
    let back: RestartSentinel = serde_json::from_str(&json).unwrap();
    assert_eq!(back.initiated_by, "session-123");
    assert!(back.self_test.unwrap().passed);
}

#[test]
fn sentinel_initiated_by_required() {
    let json = r#"{
        "action": "deploy",
        "timestamp": "2026-02-23T10:00:00.000Z",
        "commit": "abc123",
        "previousCommit": "def456",
        "status": "completed"
    }"#;
    assert!(serde_json::from_str::<RestartSentinel>(json).is_err());
}

#[test]
fn sentinel_initiated_by_always_serialized() {
    let s = sample_sentinel();
    let json = serde_json::to_string(&s).unwrap();
    let v: serde_json::Value = serde_json::from_str(&json).unwrap();
    assert!(v.get("initiatedBy").is_some());
}

#[test]
fn restart_request_with_session_id() {
    let req: DeployRestartRequest =
        serde_json::from_str(r#"{"sessionId": "sess-abc"}"#).unwrap();
    assert_eq!(req.session_id.as_deref(), Some("sess-abc"));
}

#[test]
fn restart_request_without_session_id() {
    let req: DeployRestartRequest = serde_json::from_str("{}").unwrap();
    assert!(req.session_id.is_none());
}

#[test]
fn write_last_deployment_with_error_includes_error() {
    let dir = tempfile::tempdir().unwrap();
    let s = RestartSentinel {
        action: "deploy".into(),
        timestamp: "2026-03-09T10:00:00.000Z".into(),
        commit: "abc123".into(),
        previous_commit: "def456".into(),
        status: "rolled_back".into(),
        completed_at: Some("2026-03-09T10:01:00.000Z".into()),
        initiated_by: "api".into(),
        self_test: None,
        binary_sha256: None,
    };
    write_last_deployment_with_error(dir.path(), &s, "self-test failed: database").unwrap();
    let contents = std::fs::read_to_string(dir.path().join("last-deployment.json")).unwrap();
    let v: Value = serde_json::from_str(&contents).unwrap();
    assert_eq!(v["status"], "rolled_back");
    assert_eq!(v["error"], "self-test failed: database");
    assert_eq!(v["initiatedBy"], "api");
}

#[test]
fn write_last_deployment_no_error() {
    let dir = tempfile::tempdir().unwrap();
    let mut s = sample_sentinel();
    s.status = "completed".into();
    s.completed_at = Some("2026-03-09T10:01:00.000Z".into());
    write_last_deployment(dir.path(), &s).unwrap();
    let contents = std::fs::read_to_string(dir.path().join("last-deployment.json")).unwrap();
    let v: Value = serde_json::from_str(&contents).unwrap();
    assert!(v["error"].is_null());
}

#[test]
fn disk_self_test_fails_on_probe_error() {
    let check = disk_self_test_from_result(Err(io::Error::other("statvfs failed")));
    assert_eq!(check.name, "disk");
    assert!(!check.passed);
    assert!(check.detail.unwrap().contains("disk probe failed"));
}

#[test]
fn disk_self_test_thresholds() {
    assert!(!disk_self_test_from_result(Ok(80)).passed);
    assert!(disk_self_test_from_result(Ok(500)).passed);
}

// ── Binary hash verification tests ──────────────────────────

#[test]
fn binary_hash_matches() {
    let dir = tempfile::tempdir().unwrap();
    let bin = dir.path().join("test-binary");
    std::fs::write(&bin, b"hello world binary content").unwrap();

    let hash = compute_binary_hash(&bin).unwrap();
    assert!(verify_binary_hash(&bin, &hash).unwrap());
}

#[test]
fn binary_hash_mismatch() {
    let dir = tempfile::tempdir().unwrap();
    let bin = dir.path().join("test-binary");
    std::fs::write(&bin, b"original content").unwrap();

    let hash = compute_binary_hash(&bin).unwrap();
    std::fs::write(&bin, b"tampered content").unwrap();
    assert!(!verify_binary_hash(&bin, &hash).unwrap());
}

#[test]
fn binary_hash_missing_file() {
    let dir = tempfile::tempdir().unwrap();
    let result = compute_binary_hash(&dir.path().join("nonexistent"));
    assert!(result.is_err());
}

#[test]
fn sentinel_with_hash_roundtrip() {
    let dir = tempfile::tempdir().unwrap();
    let bin = dir.path().join("binary");
    std::fs::write(&bin, b"test").unwrap();
    let hash = compute_binary_hash(&bin).unwrap();

    let mut s = sample_sentinel();
    s.binary_sha256 = Some(hash.clone());
    write_sentinel(dir.path(), &s).unwrap();

    let loaded = read_sentinel(dir.path()).unwrap();
    assert_eq!(loaded.binary_sha256.unwrap(), hash);
}

#[test]
fn sentinel_without_hash_backwards_compat() {
    let dir = tempfile::tempdir().unwrap();
    let s = sample_sentinel();
    write_sentinel(dir.path(), &s).unwrap();

    let loaded = read_sentinel(dir.path()).unwrap();
    assert!(loaded.binary_sha256.is_none());
}

// ── Self-test binary hash verification ──────────────────────

#[test]
fn self_test_hash_match_passes() {
    let dir = tempfile::tempdir().unwrap();
    let binary = dir.path().join("tron");
    std::fs::write(&binary, b"test binary content").unwrap();

    let hash = compute_binary_hash(&binary).unwrap();
    let mut s = sample_sentinel();
    s.binary_sha256 = Some(hash);
    write_sentinel(dir.path(), &s).unwrap();

    let check = check_binary_hash(&binary, dir.path());
    assert!(check.passed, "Hash match should pass");
}

#[test]
fn self_test_hash_mismatch_fails() {
    let dir = tempfile::tempdir().unwrap();
    let binary = dir.path().join("tron");
    std::fs::write(&binary, b"original content").unwrap();

    let hash = compute_binary_hash(&binary).unwrap();
    let mut s = sample_sentinel();
    s.binary_sha256 = Some(hash);
    write_sentinel(dir.path(), &s).unwrap();

    // Tamper with binary
    std::fs::write(&binary, b"tampered content").unwrap();

    let check = check_binary_hash(&binary, dir.path());
    assert!(!check.passed, "Hash mismatch should fail");
    assert!(check.detail.unwrap().contains("tampered"));
}

#[test]
fn self_test_no_sentinel_skips_hash() {
    let dir = tempfile::tempdir().unwrap();
    let binary = dir.path().join("tron");
    std::fs::write(&binary, b"content").unwrap();

    let check = check_binary_hash(&binary, dir.path());
    assert!(check.passed, "No sentinel should pass gracefully");
}

#[test]
fn self_test_no_hash_in_sentinel_skips() {
    let dir = tempfile::tempdir().unwrap();
    let binary = dir.path().join("tron");
    std::fs::write(&binary, b"content").unwrap();

    let s = sample_sentinel(); // binary_sha256: None
    write_sentinel(dir.path(), &s).unwrap();

    let check = check_binary_hash(&binary, dir.path());
    assert!(check.passed, "No hash in sentinel should pass gracefully");
    assert!(check.detail.unwrap().contains("pre-hash"));
}
