//! Server-side deploy: types, sentinel I/O, atomic binary install, Axum handlers.

use std::io;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::sync::atomic::Ordering;
use std::time::{Duration, Instant};

use axum::extract::State;
use axum::http::StatusCode;
use axum::response::Json;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use tracing::{debug, info, warn};

use crate::rpc::types::RpcEvent;
use crate::server::AppState;

// ── Types ──────────────────────────────────────────────────────────────────

/// On-disk sentinel written before restart, completed on next startup.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
#[allow(missing_docs)]
pub struct RestartSentinel {
    pub action: String,
    pub timestamp: String,
    pub commit: String,
    pub previous_commit: String,
    pub status: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub completed_at: Option<String>,
}

/// GET /deploy/status response.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
#[allow(missing_docs)]
pub struct DeployStatusResponse {
    pub version: String,
    pub deployed_commit: String,
    pub binary_path: String,
    pub binary_exists: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub binary_modified: Option<String>,
    pub restart_initiated: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub sentinel: Option<RestartSentinel>,
}

/// POST /deploy/restart request body.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
#[allow(missing_docs)]
pub struct DeployRestartRequest {
    #[serde(default = "default_delay")]
    pub delay_ms: u64,
    pub source_binary: Option<String>,
}

fn default_delay() -> u64 {
    5000
}

/// POST /deploy/restart response.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
#[allow(missing_docs)]
pub struct DeployRestartResponse {
    pub ok: bool,
    pub restarting_in_ms: u64,
    pub commit: String,
    pub previous_commit: String,
}

/// Deploy operation errors.
#[derive(Debug, thiserror::Error)]
#[allow(missing_docs)]
pub enum DeployError {
    #[error("source binary not found: {path}")]
    SourceNotFound { path: String },
    #[error("binary copy failed: {0}")]
    CopyFailed(#[source] io::Error),
    #[error("failed to set executable permission: {0}")]
    PermissionFailed(#[source] io::Error),
    #[error("atomic rename failed: {0}")]
    RenameFailed(#[source] io::Error),
    #[error("backup failed: {0}")]
    BackupFailed(#[source] io::Error),
}

// ── Pure helpers ───────────────────────────────────────────────────────────

/// Read the deployed commit from `artifacts/deployment/deployed-commit`.
pub fn read_deployed_commit(artifacts_dir: &Path) -> String {
    std::fs::read_to_string(artifacts_dir.join("deployed-commit"))
        .map(|s| s.trim().to_string())
        .unwrap_or_else(|_| "unknown".to_string())
}

/// Read the restart sentinel if it exists.
pub fn read_sentinel(artifacts_dir: &Path) -> Option<RestartSentinel> {
    let path = artifacts_dir.join("restart-sentinel.json");
    let data = std::fs::read_to_string(path).ok()?;
    serde_json::from_str(&data).ok()
}

/// Write the restart sentinel.
pub fn write_sentinel(artifacts_dir: &Path, sentinel: &RestartSentinel) -> io::Result<()> {
    std::fs::create_dir_all(artifacts_dir)?;
    let json = serde_json::to_string_pretty(sentinel)
        .map_err(|e| io::Error::new(io::ErrorKind::Other, e))?;
    std::fs::write(artifacts_dir.join("restart-sentinel.json"), json)
}

/// Mark an existing sentinel as completed. Returns the updated sentinel.
pub fn complete_sentinel(artifacts_dir: &Path) -> io::Result<Option<RestartSentinel>> {
    let path = artifacts_dir.join("restart-sentinel.json");
    let data = match std::fs::read_to_string(&path) {
        Ok(d) => d,
        Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(e) => return Err(e),
    };
    let mut sentinel: RestartSentinel = serde_json::from_str(&data)
        .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
    if sentinel.status == "completed" {
        return Ok(Some(sentinel));
    }
    sentinel.status = "completed".to_string();
    sentinel.completed_at = Some(
        chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true),
    );
    let json = serde_json::to_string_pretty(&sentinel)
        .map_err(|e| io::Error::new(io::ErrorKind::Other, e))?;
    std::fs::write(&path, json)?;
    Ok(Some(sentinel))
}

/// Write `last-deployment.json` compatible with `scripts/tron` format.
///
/// `artifacts_dir` should be `~/.tron/artifacts/deployment/`.
pub fn write_last_deployment(artifacts_dir: &Path, sentinel: &RestartSentinel) -> io::Result<()> {
    let json = json!({
        "status": sentinel.status,
        "timestamp": sentinel.completed_at.as_deref().unwrap_or(&sentinel.timestamp),
        "commit": sentinel.commit,
        "previousCommit": sentinel.previous_commit,
        "error": null,
    });
    let pretty = serde_json::to_string_pretty(&json)
        .map_err(|e| io::Error::new(io::ErrorKind::Other, e))?;
    std::fs::create_dir_all(artifacts_dir)?;
    std::fs::write(artifacts_dir.join("last-deployment.json"), pretty)
}

/// Resolve the workspace root from `TRON_REPO_ROOT` environment variable.
pub fn resolve_workspace_root() -> Option<PathBuf> {
    std::env::var("TRON_REPO_ROOT").ok().map(PathBuf::from)
}

/// Resolve the source binary path.
pub fn resolve_source_binary(
    explicit: Option<&str>,
    workspace_root: Option<&Path>,
) -> Option<PathBuf> {
    if let Some(p) = explicit {
        return Some(PathBuf::from(p));
    }
    workspace_root.map(|root| root.join("target/release/tron"))
}

/// Get current git HEAD commit hash from a directory.
pub fn git_head_commit(repo_dir: &Path) -> Option<String> {
    std::process::Command::new("git")
        .args(["rev-parse", "HEAD"])
        .current_dir(repo_dir)
        .output()
        .ok()
        .filter(|o| o.status.success())
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
}

/// Atomically copy a binary: backup existing → write temp → set executable → rename.
///
/// `backup_dir` specifies where to write the backup (`tron.bak`).
pub async fn atomic_binary_install(
    source: &Path,
    target: &Path,
    backup_dir: &Path,
) -> Result<Option<PathBuf>, DeployError> {
    if !source.exists() {
        return Err(DeployError::SourceNotFound {
            path: source.display().to_string(),
        });
    }

    // Backup existing binary into the deployment directory
    let backup = if target.exists() {
        tokio::fs::create_dir_all(backup_dir)
            .await
            .map_err(DeployError::BackupFailed)?;
        let bak = backup_dir.join("tron.bak");
        let _ = tokio::fs::copy(target, &bak)
            .await
            .map_err(DeployError::BackupFailed)?;
        Some(bak)
    } else {
        None
    };

    // Write to temp file first
    let tmp = target.with_extension("tmp");
    if let Err(e) = tokio::fs::copy(source, &tmp).await {
        return Err(DeployError::CopyFailed(e));
    }

    // Set executable permissions
    if let Err(e) = tokio::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o755)).await {
        let _ = tokio::fs::remove_file(&tmp).await;
        return Err(DeployError::PermissionFailed(e));
    }

    // Atomic rename
    if let Err(e) = tokio::fs::rename(&tmp, target).await {
        let _ = tokio::fs::remove_file(&tmp).await;
        return Err(DeployError::RenameFailed(e));
    }

    Ok(backup)
}

// ── Axum handlers ──────────────────────────────────────────────────────────

/// GET /deploy/status
pub async fn status_handler(State(state): State<AppState>) -> Json<DeployStatusResponse> {
    let tron_home = tron_settings::tron_home_dir();
    let deploy_dir = tron_settings::deploy_dir();
    let binary_path = tron_home.join("tron");

    let deployed_commit = read_deployed_commit(&deploy_dir);
    let sentinel = read_sentinel(&deploy_dir);
    let binary_exists = binary_path.exists();
    let binary_modified = if binary_exists {
        tokio::fs::metadata(&binary_path)
            .await
            .ok()
            .and_then(|m| m.modified().ok())
            .map(|t| {
                let dt: chrono::DateTime<chrono::Utc> = t.into();
                dt.to_rfc3339_opts(chrono::SecondsFormat::Secs, true)
            })
    } else {
        None
    };

    let restart_initiated = state
        .deploy_restart_initiated
        .load(Ordering::Relaxed);

    Json(DeployStatusResponse {
        version: env!("CARGO_PKG_VERSION").to_string(),
        deployed_commit,
        binary_path: binary_path.to_string_lossy().to_string(),
        binary_exists,
        binary_modified,
        restart_initiated,
        sentinel,
    })
}

/// POST /deploy/restart
pub async fn restart_handler(
    State(state): State<AppState>,
    axum::Json(req): axum::Json<DeployRestartRequest>,
) -> Result<Json<DeployRestartResponse>, (StatusCode, Json<Value>)> {
    // Guard: prevent double-restart
    if state
        .deploy_restart_initiated
        .compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst)
        .is_err()
    {
        return Err((
            StatusCode::CONFLICT,
            Json(json!({ "error": "restart already initiated" })),
        ));
    }

    let tron_home = tron_settings::tron_home_dir();
    let deploy_dir = tron_settings::deploy_dir();
    let installed_binary = tron_home.join("tron");

    // Resolve source binary
    let workspace_root = resolve_workspace_root();
    let source = resolve_source_binary(req.source_binary.as_deref(), workspace_root.as_deref())
        .ok_or_else(|| {
            state
                .deploy_restart_initiated
                .store(false, Ordering::SeqCst);
            (
                StatusCode::BAD_REQUEST,
                Json(json!({
                    "error": "cannot resolve source binary: set TRON_REPO_ROOT env or pass sourceBinary"
                })),
            )
        })?;

    // Validate source exists
    if !source.exists() {
        state
            .deploy_restart_initiated
            .store(false, Ordering::SeqCst);
        return Err((
            StatusCode::BAD_REQUEST,
            Json(json!({
                "error": format!("source binary not found: {}", source.display())
            })),
        ));
    }

    // Read commits
    let previous_commit = read_deployed_commit(&deploy_dir);
    let new_commit = workspace_root
        .as_deref()
        .and_then(|w| git_head_commit(w))
        .unwrap_or_else(|| "unknown".to_string());

    // Ensure deployment dir exists
    let _ = tokio::fs::create_dir_all(&deploy_dir).await;

    // Atomic binary install (backup + copy)
    let _ = atomic_binary_install(&source, &installed_binary, &deploy_dir)
        .await
        .map_err(|e| {
            state
                .deploy_restart_initiated
                .store(false, Ordering::SeqCst);
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(json!({ "error": format!("binary install failed: {e}") })),
            )
        })?;

    // Write deployed commit
    let commit_path = deploy_dir.join("deployed-commit");
    let _ = tokio::fs::write(&commit_path, &new_commit).await;

    // Write sentinel
    let sentinel = RestartSentinel {
        action: "deploy".to_string(),
        timestamp: chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true),
        commit: new_commit.clone(),
        previous_commit: previous_commit.clone(),
        status: "restarting".to_string(),
        completed_at: None,
    };
    if let Err(e) = write_sentinel(&deploy_dir, &sentinel) {
        warn!(error = %e, "failed to write restart sentinel (non-fatal)");
    }

    let delay_ms = req.delay_ms;

    // Spawn background shutdown task (runs AFTER this response reaches the client)
    let broadcast = state.broadcast.clone();
    let shutdown = state.shutdown.clone();
    let orchestrator = state.rpc_context.orchestrator.clone();

    let _ = tokio::spawn(async move {
        // 1. Wait for response to reach client + agent to finish turn
        tokio::time::sleep(Duration::from_millis(delay_ms)).await;

        // 2. Broadcast server.restarting to all WebSocket clients
        let event = RpcEvent::new(
            "server.restarting",
            None,
            Some(json!({
                "reason": "deploy",
                "commit": sentinel.commit,
                "restartExpectedMs": 5000,
            })),
        );
        broadcast.broadcast_all(&event).await;

        // 3. Drain active agent runs (poll 500ms, max 30s)
        let drain_start = Instant::now();
        let drain_timeout = Duration::from_secs(30);
        loop {
            let active = orchestrator.active_run_count();
            if active == 0 {
                info!("deploy: all agent runs drained");
                break;
            }
            if drain_start.elapsed() >= drain_timeout {
                warn!(active, "deploy: drain timeout, proceeding with active runs");
                break;
            }
            debug!(active, "deploy: waiting for agent runs to drain...");
            tokio::time::sleep(Duration::from_millis(500)).await;
        }

        // 4. Graceful shutdown
        info!("deploy: initiating graceful shutdown");
        shutdown
            .graceful_shutdown(vec![], Some(Duration::from_secs(5)))
            .await;

        // 5. Exit with non-zero code so launchd's SuccessfulExit:false restarts us.
        // Code 42 = intentional deploy restart (not a crash or error).
        info!("deploy: exiting process for restart (code 42)");
        std::process::exit(42);
    });

    Ok(Json(DeployRestartResponse {
        ok: true,
        restarting_in_ms: delay_ms,
        commit: new_commit,
        previous_commit,
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    // ── Sentinel serialization ─────────────────────────────────────────

    fn sample_sentinel() -> RestartSentinel {
        RestartSentinel {
            action: "deploy".into(),
            timestamp: "2026-02-23T10:00:00.000Z".into(),
            commit: "abc123".into(),
            previous_commit: "def456".into(),
            status: "restarting".into(),
            completed_at: None,
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
            binary_path: "/home/user/.tron/tron".into(),
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
    fn complete_sentinel_already_completed() {
        let dir = tempfile::tempdir().unwrap();
        let mut s = sample_sentinel();
        s.status = "completed".into();
        s.completed_at = Some("2026-02-23T10:05:00.000Z".into());
        write_sentinel(dir.path(), &s).unwrap();

        let result = complete_sentinel(dir.path()).unwrap().unwrap();
        assert_eq!(result.status, "completed");
        assert_eq!(result.completed_at.as_deref(), Some("2026-02-23T10:05:00.000Z"));
    }

    #[test]
    fn write_last_deployment_compat() {
        let dir = tempfile::tempdir().unwrap();
        let mut s = sample_sentinel();
        s.status = "completed".into();
        s.completed_at = Some("2026-02-23T10:05:00.000Z".into());
        write_last_deployment(dir.path(), &s).unwrap();

        let contents =
            std::fs::read_to_string(dir.path().join("last-deployment.json")).unwrap();
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
        let result =
            resolve_source_binary(Some("/explicit"), Some(Path::new("/workspace")));
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

        atomic_binary_install(&src, &tgt, &bak_dir).await.unwrap();

        assert_eq!(std::fs::read(&tgt).unwrap(), b"binary content here");
    }

    #[tokio::test]
    async fn atomic_install_sets_executable() {
        let dir = tempfile::tempdir().unwrap();
        let src = dir.path().join("source");
        let tgt = dir.path().join("target");
        let bak_dir = dir.path().join("deployment");
        std::fs::write(&src, b"#!/bin/sh\necho hi").unwrap();

        atomic_binary_install(&src, &tgt, &bak_dir).await.unwrap();

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

        let err = atomic_binary_install(&src, &tgt, &bak_dir).await.unwrap_err();
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

        atomic_binary_install(&src, &tgt, &bak_dir).await.unwrap();

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

        atomic_binary_install(&src, &tgt, &bak_dir).await.unwrap();

        assert_eq!(std::fs::read(&tgt).unwrap(), data);
    }

    // ── Handler tests ──────────────────────────────────────────────────

    use crate::config::ServerConfig;
    use crate::rpc::handlers::test_helpers::make_test_context;
    use crate::rpc::registry::MethodRegistry;
    use crate::server::TronServer;
    use axum::body::Body;
    use axum::http::Request;
    use tower::ServiceExt;

    // Restart success tests write to ~/.tron/tron (via tron_home_dir()) and must
    // not run concurrently with each other.
    static RESTART_TEST_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

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
        assert!(
            !server
                .deploy_restart_initiated()
                .load(Ordering::SeqCst)
        );
    }

    #[tokio::test]
    async fn deploy_restart_returns_ok_with_commits() {
        let _lock = RESTART_TEST_LOCK.lock().unwrap();

        let dir = tempfile::tempdir().unwrap();
        let src = dir.path().join("fake-binary");
        std::fs::write(&src, b"fake tron binary").unwrap();

        let server = make_test_server();
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
        let _lock = RESTART_TEST_LOCK.lock().unwrap();

        let dir = tempfile::tempdir().unwrap();
        let src = dir.path().join("fake-binary");
        std::fs::write(&src, b"fake tron binary").unwrap();

        let server = make_test_server();
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
        let _lock = RESTART_TEST_LOCK.lock().unwrap();

        let dir = tempfile::tempdir().unwrap();
        let src = dir.path().join("fake-binary");
        std::fs::write(&src, b"fake tron binary").unwrap();

        let server = make_test_server();
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
}
