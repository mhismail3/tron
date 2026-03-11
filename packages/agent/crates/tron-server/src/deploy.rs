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
pub struct RestartSentinel {
    /// Action that triggered the restart (e.g. "deploy").
    pub action: String,
    /// ISO-8601 timestamp of when the restart was initiated.
    pub timestamp: String,
    /// Git commit hash being deployed.
    pub commit: String,
    /// Git commit hash of the previous deployment.
    pub previous_commit: String,
    /// Current status ("restarting", "completed", "`rolled_back`", "failed").
    pub status: String,
    /// ISO-8601 timestamp of when the restart completed.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub completed_at: Option<String>,
    /// Who initiated the deploy (session ID or "cli").
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub initiated_by: Option<String>,
    /// Self-test results (populated after startup self-test runs).
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub self_test: Option<SelfTestResult>,
}

/// Result of the post-deploy startup self-test.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SelfTestResult {
    /// Whether all checks passed.
    pub passed: bool,
    /// Individual check results.
    pub checks: Vec<SelfTestCheck>,
    /// ISO-8601 timestamp.
    pub timestamp: String,
}

/// A single self-test check result.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SelfTestCheck {
    /// Check name (e.g. "database", "settings", "auth", "binary", "disk").
    pub name: String,
    /// Whether this check passed.
    pub passed: bool,
    /// Optional detail message.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
}

/// GET /deploy/status response.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DeployStatusResponse {
    /// Server version string.
    pub version: String,
    /// Git commit hash of the currently deployed binary.
    pub deployed_commit: String,
    /// Filesystem path to the server binary.
    pub binary_path: String,
    /// Whether the binary exists on disk.
    pub binary_exists: bool,
    /// ISO-8601 timestamp of binary's last modification.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub binary_modified: Option<String>,
    /// Whether a restart has been initiated but not yet completed.
    pub restart_initiated: bool,
    /// Active restart sentinel, if any.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub sentinel: Option<RestartSentinel>,
}

/// POST /deploy/restart request body.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DeployRestartRequest {
    /// Delay in milliseconds before the restart takes effect.
    #[serde(default = "default_delay")]
    pub delay_ms: u64,
    /// Path to the new binary to deploy. Uses current binary if `None`.
    pub source_binary: Option<String>,
    /// Session ID of the initiator (for audit trail).
    pub session_id: Option<String>,
}

fn default_delay() -> u64 {
    5000
}

/// POST /deploy/restart response.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DeployRestartResponse {
    /// Whether the restart was successfully initiated.
    pub ok: bool,
    /// Delay before the restart takes effect.
    pub restarting_in_ms: u64,
    /// Git commit hash being deployed.
    pub commit: String,
    /// Git commit hash being replaced.
    pub previous_commit: String,
}

/// Deploy operation errors.
#[derive(Debug, thiserror::Error)]
pub enum DeployError {
    /// Source binary file was not found at the specified path.
    #[error("source binary not found: {path}")]
    SourceNotFound {
        /// Path that was checked.
        path: String,
    },
    /// Failed to copy the binary to the install directory.
    #[error("binary copy failed: {0}")]
    CopyFailed(#[source] io::Error),
    /// Failed to set executable permissions on the new binary.
    #[error("failed to set executable permission: {0}")]
    PermissionFailed(#[source] io::Error),
    /// Atomic rename of the staged binary to the target path failed.
    #[error("atomic rename failed: {0}")]
    RenameFailed(#[source] io::Error),
    /// Failed to create a backup of the existing binary.
    #[error("backup failed: {0}")]
    BackupFailed(#[source] io::Error),
}

// ── Pure helpers ───────────────────────────────────────────────────────────

/// Read the deployed commit from `artifacts/deployment/deployed-commit`.
pub fn read_deployed_commit(artifacts_dir: &Path) -> String {
    std::fs::read_to_string(artifacts_dir.join("deployed-commit"))
        .map_or_else(|_| "unknown".to_string(), |s| s.trim().to_string())
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
    let json = serde_json::to_string_pretty(sentinel).map_err(io::Error::other)?;
    std::fs::write(artifacts_dir.join("restart-sentinel.json"), json)
}

/// Mark a "restarting" sentinel as completed. Returns the updated sentinel
/// only when a transition actually occurs (restarting → completed).
/// Returns `None` if no sentinel exists or if it's already in a terminal state
/// (completed, `rolled_back`, failed).
pub fn complete_sentinel(artifacts_dir: &Path) -> io::Result<Option<RestartSentinel>> {
    let path = artifacts_dir.join("restart-sentinel.json");
    let data = match std::fs::read_to_string(&path) {
        Ok(d) => d,
        Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(e) => return Err(e),
    };
    let mut sentinel: RestartSentinel =
        serde_json::from_str(&data).map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
    if sentinel.status != "restarting" {
        // Already in a terminal state — no transition needed
        return Ok(None);
    }
    sentinel.status = "completed".to_string();
    sentinel.completed_at =
        Some(chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true));
    let json = serde_json::to_string_pretty(&sentinel).map_err(io::Error::other)?;
    std::fs::write(&path, json)?;
    Ok(Some(sentinel))
}

/// Write `last-deployment.json` compatible with `scripts/tron` format.
///
/// `artifacts_dir` should be `~/.tron/artifacts/deployment/`.
pub fn write_last_deployment(artifacts_dir: &Path, sentinel: &RestartSentinel) -> io::Result<()> {
    write_last_deployment_inner(artifacts_dir, sentinel, None)
}

/// Write `last-deployment.json` with an error message (for rollback/failure cases).
pub fn write_last_deployment_with_error(
    artifacts_dir: &Path,
    sentinel: &RestartSentinel,
    error: &str,
) -> io::Result<()> {
    write_last_deployment_inner(artifacts_dir, sentinel, Some(error))
}

fn write_last_deployment_inner(
    artifacts_dir: &Path,
    sentinel: &RestartSentinel,
    error: Option<&str>,
) -> io::Result<()> {
    let json = json!({
        "status": sentinel.status,
        "timestamp": sentinel.completed_at.as_deref().unwrap_or(&sentinel.timestamp),
        "commit": sentinel.commit,
        "previousCommit": sentinel.previous_commit,
        "initiatedBy": sentinel.initiated_by,
        "selfTest": sentinel.self_test,
        "error": error,
    });
    let pretty = serde_json::to_string_pretty(&json).map_err(io::Error::other)?;
    std::fs::create_dir_all(artifacts_dir)?;
    std::fs::write(artifacts_dir.join("last-deployment.json"), pretty)
}

// ── Self-test & auto-rollback ─────────────────────────────────────────────

/// Run post-deploy self-test checks against critical infrastructure.
///
/// Checks: database connectivity, settings parsability, auth file existence,
/// binary existence + executable bit, and available disk space.
pub fn run_self_test(
    db_path: &Path,
    settings_path: &Path,
    auth_path: &Path,
    binary_path: &Path,
) -> SelfTestResult {
    let checks = vec![
        // 1. Database: open + SELECT 1 + verify events table exists
        check_database(db_path),
        // 2. Settings: read + parse
        check_settings(settings_path),
        // 3. Auth: file exists with content
        check_auth(auth_path),
        // 4. Binary: exists + executable
        check_binary(binary_path),
        // 5. Disk space
        check_disk_space(binary_path),
    ];

    let passed = checks.iter().all(|c| c.passed);
    SelfTestResult {
        passed,
        checks,
        timestamp: chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true),
    }
}

fn check_database(db_path: &Path) -> SelfTestCheck {
    if !db_path.exists() {
        return SelfTestCheck {
            name: "database".into(),
            passed: false,
            detail: Some(format!("not found: {}", db_path.display())),
        };
    }
    match rusqlite::Connection::open_with_flags(
        db_path,
        rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY | rusqlite::OpenFlags::SQLITE_OPEN_NO_MUTEX,
    ) {
        Ok(conn) => {
            // Verify basic connectivity
            if let Err(e) = conn.execute_batch("SELECT 1") {
                return SelfTestCheck {
                    name: "database".into(),
                    passed: false,
                    detail: Some(format!("SELECT 1 failed: {e}")),
                };
            }
            // Verify events table exists
            let has_events: bool = conn
                .prepare("SELECT 1 FROM sqlite_master WHERE type='table' AND name='events'")
                .and_then(|mut s| s.exists([]))
                .unwrap_or(false);
            if !has_events {
                return SelfTestCheck {
                    name: "database".into(),
                    passed: false,
                    detail: Some("events table missing".into()),
                };
            }
            SelfTestCheck {
                name: "database".into(),
                passed: true,
                detail: None,
            }
        }
        Err(e) => SelfTestCheck {
            name: "database".into(),
            passed: false,
            detail: Some(format!("open failed: {e}")),
        },
    }
}

fn check_settings(settings_path: &Path) -> SelfTestCheck {
    match std::fs::read_to_string(settings_path) {
        Ok(content) => match serde_json::from_str::<serde_json::Value>(&content) {
            Ok(_) => SelfTestCheck {
                name: "settings".into(),
                passed: true,
                detail: None,
            },
            Err(e) => SelfTestCheck {
                name: "settings".into(),
                passed: false,
                detail: Some(format!("parse error: {e}")),
            },
        },
        Err(e) if e.kind() == io::ErrorKind::NotFound => SelfTestCheck {
            name: "settings".into(),
            passed: true,
            detail: Some("not found (using defaults)".into()),
        },
        Err(e) => SelfTestCheck {
            name: "settings".into(),
            passed: false,
            detail: Some(format!("read error: {e}")),
        },
    }
}

fn check_auth(auth_path: &Path) -> SelfTestCheck {
    match std::fs::read_to_string(auth_path) {
        Ok(content) => match serde_json::from_str::<serde_json::Value>(&content) {
            Ok(v) => {
                let key_count = v.as_object().map_or(0, serde_json::Map::len);
                if key_count == 0 {
                    SelfTestCheck {
                        name: "auth".into(),
                        passed: false,
                        detail: Some("auth.json is empty".into()),
                    }
                } else {
                    SelfTestCheck {
                        name: "auth".into(),
                        passed: true,
                        detail: Some(format!("{key_count} provider(s)")),
                    }
                }
            }
            Err(e) => SelfTestCheck {
                name: "auth".into(),
                passed: false,
                detail: Some(format!("parse error: {e}")),
            },
        },
        Err(e) if e.kind() == io::ErrorKind::NotFound => SelfTestCheck {
            name: "auth".into(),
            passed: false,
            detail: Some("auth.json not found".into()),
        },
        Err(e) => SelfTestCheck {
            name: "auth".into(),
            passed: false,
            detail: Some(format!("read error: {e}")),
        },
    }
}

fn check_binary(binary_path: &Path) -> SelfTestCheck {
    match std::fs::metadata(binary_path) {
        Ok(meta) => {
            let mode = meta.permissions().mode();
            if mode & 0o111 == 0 {
                SelfTestCheck {
                    name: "binary".into(),
                    passed: false,
                    detail: Some("not executable".into()),
                }
            } else {
                SelfTestCheck {
                    name: "binary".into(),
                    passed: true,
                    detail: None,
                }
            }
        }
        Err(e) if e.kind() == io::ErrorKind::NotFound => SelfTestCheck {
            name: "binary".into(),
            passed: false,
            detail: Some("binary not found".into()),
        },
        Err(e) => SelfTestCheck {
            name: "binary".into(),
            passed: false,
            detail: Some(format!("stat error: {e}")),
        },
    }
}

fn check_disk_space(reference_path: &Path) -> SelfTestCheck {
    let dir = reference_path
        .parent()
        .unwrap_or(Path::new("/"))
        .to_string_lossy();
    // Use `df -m` to get available space in MB
    match std::process::Command::new("df")
        .args(["-m", &dir])
        .output()
    {
        Ok(output) if output.status.success() => {
            let text = String::from_utf8_lossy(&output.stdout);
            // Second line, fourth column = available MB
            let free_mb: Option<u64> = text
                .lines()
                .nth(1)
                .and_then(|line| line.split_whitespace().nth(3))
                .and_then(|s| s.parse().ok());
            match free_mb {
                Some(mb) if mb < 100 => SelfTestCheck {
                    name: "disk".into(),
                    passed: false,
                    detail: Some(format!("{mb}MB free (< 100MB)")),
                },
                Some(mb) => SelfTestCheck {
                    name: "disk".into(),
                    passed: true,
                    detail: Some(format!("{mb}MB free")),
                },
                None => SelfTestCheck {
                    name: "disk".into(),
                    passed: true,
                    detail: Some("could not parse df output (non-fatal)".into()),
                },
            }
        }
        _ => SelfTestCheck {
            name: "disk".into(),
            passed: true,
            detail: Some("df command failed (non-fatal)".into()),
        },
    }
}

/// Auto-rollback: restore backup binary, update sentinel, and exit.
///
/// This function never returns — it calls `std::process::exit(43)`.
pub fn auto_rollback(artifacts_dir: &Path, binary_path: &Path, reason: &str) -> ! {
    let backup_path = artifacts_dir.join("tron.bak");

    if backup_path.exists() {
        // Restore backup
        if let Err(e) = std::fs::copy(&backup_path, binary_path) {
            eprintln!("DEPLOY SAFETY: backup restore failed: {e}");
        } else if let Err(e) =
            std::fs::set_permissions(binary_path, std::fs::Permissions::from_mode(0o755))
        {
            eprintln!("DEPLOY SAFETY: chmod failed after restore: {e}");
        }

        // Re-sign restored binary for TCC persistence
        codesign_binary(binary_path);

        // Update sentinel to rolled_back
        if let Some(mut sentinel) = read_sentinel(artifacts_dir) {
            sentinel.status = "rolled_back".into();
            sentinel.completed_at =
                Some(chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true));
            let _ = write_sentinel(artifacts_dir, &sentinel);
            let _ = write_last_deployment_with_error(artifacts_dir, &sentinel, reason);
        }
    } else {
        eprintln!("DEPLOY SAFETY: no backup available for rollback");
        // Mark sentinel as failed to break deploy logic on next start
        if let Some(mut sentinel) = read_sentinel(artifacts_dir) {
            sentinel.status = "failed".into();
            sentinel.completed_at =
                Some(chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true));
            let _ = write_sentinel(artifacts_dir, &sentinel);
            let _ = write_last_deployment_with_error(artifacts_dir, &sentinel, reason);
        }
    }

    // Clean up attempt counter
    let _ = std::fs::remove_file(artifacts_dir.join("startup-attempts"));

    // Write pending notification for the next startup to send
    if let Some(sentinel) = read_sentinel(artifacts_dir) {
        let notification = json!({
            "type": if backup_path.exists() { "deploy.rolled_back" } else { "deploy.failed" },
            "commit": sentinel.commit,
            "previousCommit": sentinel.previous_commit,
            "reason": reason,
        });
        let _ = std::fs::write(
            artifacts_dir.join("deploy-notification-pending.json"),
            serde_json::to_string_pretty(&notification).unwrap_or_default(),
        );
    }

    eprintln!("DEPLOY SAFETY: auto-rollback complete: {reason}");
    std::process::exit(43)
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

    // Re-sign so macOS TCC permissions persist across binary updates
    codesign_binary(target);

    Ok(backup)
}

/// Sign a binary with the first available code signing identity.
///
/// Uses `security find-identity` to locate a signing cert, then `codesign --force --sign`.
/// This ensures macOS TCC (Full Disk Access, folder access) persists across binary updates
/// since permissions are tied to code signing identity, not binary hash.
/// Failures are logged but non-fatal — the binary still works unsigned.
pub fn codesign_binary(path: &Path) {
    // Find the first valid codesigning identity
    let identity = std::process::Command::new("security")
        .args(["find-identity", "-v", "-p", "codesigning"])
        .output()
        .ok()
        .and_then(|o| {
            if !o.status.success() {
                return None;
            }
            String::from_utf8(o.stdout).ok().and_then(|out| {
                // Parse first identity line: "  1) HEXHASH \"Name (ID)\""
                out.lines().find(|l| l.contains(')') && l.contains('"')).and_then(|line| {
                    let start = line.find('"')?;
                    let end = line.rfind('"')?;
                    if end > start {
                        Some(line[start + 1..end].to_string())
                    } else {
                        None
                    }
                })
            })
        });

    let Some(identity) = identity else {
        debug!("no codesigning identity found, skipping binary signing");
        return;
    };

    match std::process::Command::new("codesign")
        .args(["--force", "--sign", &identity, &path.to_string_lossy()])
        .output()
    {
        Ok(o) if o.status.success() => {
            info!(identity = identity.as_str(), "binary signed for TCC persistence");
        }
        Ok(o) => {
            let stderr = String::from_utf8_lossy(&o.stderr);
            warn!(%stderr, "codesign failed (non-fatal)");
        }
        Err(e) => {
            warn!(error = %e, "codesign command failed (non-fatal)");
        }
    }
}

// ── Axum handlers ──────────────────────────────────────────────────────────

/// GET /deploy/status
pub async fn status_handler(State(state): State<AppState>) -> Json<DeployStatusResponse> {
    let binary_path = &state.deploy_binary_path;
    let deploy_dir = &state.deploy_dir;

    let deployed_commit = read_deployed_commit(deploy_dir);
    let sentinel = read_sentinel(deploy_dir);
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

    let restart_initiated = state.deploy_restart_initiated.load(Ordering::Relaxed);

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

    let installed_binary = &state.deploy_binary_path;
    let deploy_dir = &state.deploy_dir;

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
    let previous_commit = read_deployed_commit(deploy_dir);
    let new_commit = workspace_root
        .as_deref()
        .and_then(git_head_commit)
        .unwrap_or_else(|| "unknown".to_string());

    // Ensure deployment dir exists
    let _ = tokio::fs::create_dir_all(&deploy_dir).await;

    // Atomic binary install (backup + copy)
    let _ = atomic_binary_install(&source, installed_binary, deploy_dir)
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
        initiated_by: req.session_id.or_else(|| Some("api".to_string())),
        self_test: None,
    };
    if let Err(e) = write_sentinel(deploy_dir, &sentinel) {
        warn!(error = %e, "failed to write restart sentinel (non-fatal)");
    }

    let delay_ms = req.delay_ms;

    // Spawn background shutdown task (runs AFTER this response reaches the client)
    let broadcast = state.broadcast.clone();
    let shutdown = state.shutdown.clone();
    let orchestrator = state.rpc_context.orchestrator.clone();

    #[allow(clippy::let_underscore_future)]
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
            initiated_by: None,
            self_test: None,
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

    use crate::config::ServerConfig;
    use crate::rpc::handlers::test_helpers::make_test_context;
    use crate::rpc::registry::MethodRegistry;
    use crate::server::TronServer;
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
        let real_binary = tron_settings::tron_home_dir().join("tron");
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

    // ── Self-test tests ───────────────────────────────────────────────

    #[test]
    fn self_test_all_pass() {
        let dir = tempfile::tempdir().unwrap();
        let db = dir.path().join("tron.db");
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

        let result = run_self_test(&db, &settings, &auth, &binary);
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
        );
        assert!(!result.passed);
        assert!(!result.checks[0].passed); // database
    }

    #[test]
    fn self_test_missing_auth() {
        let dir = tempfile::tempdir().unwrap();
        let db = dir.path().join("tron.db");
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
        );
        assert!(!result.passed);
        let auth_check = result.checks.iter().find(|c| c.name == "auth").unwrap();
        assert!(!auth_check.passed);
    }

    #[test]
    fn self_test_non_executable_binary() {
        let dir = tempfile::tempdir().unwrap();
        let db = dir.path().join("tron.db");
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

        let result = run_self_test(&db, &settings, &auth, &binary);
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
            initiated_by: Some("session-123".into()),
            self_test: Some(SelfTestResult {
                passed: true,
                checks: vec![SelfTestCheck {
                    name: "database".into(),
                    passed: true,
                    detail: None,
                }],
                timestamp: "2026-03-09T10:00:30.000Z".into(),
            }),
        };
        let json = serde_json::to_string_pretty(&s).unwrap();
        let back: RestartSentinel = serde_json::from_str(&json).unwrap();
        assert_eq!(back.initiated_by.as_deref(), Some("session-123"));
        assert!(back.self_test.unwrap().passed);
    }

    #[test]
    fn sentinel_backward_compatible_without_new_fields() {
        // Old sentinel JSON without initiatedBy or selfTest
        let json = r#"{
            "action": "deploy",
            "timestamp": "2026-02-23T10:00:00.000Z",
            "commit": "abc123",
            "previousCommit": "def456",
            "status": "completed"
        }"#;
        let s: RestartSentinel = serde_json::from_str(json).unwrap();
        assert!(s.initiated_by.is_none());
        assert!(s.self_test.is_none());
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
            initiated_by: Some("api".into()),
            self_test: None,
        };
        write_last_deployment_with_error(dir.path(), &s, "self-test failed: database").unwrap();
        let contents =
            std::fs::read_to_string(dir.path().join("last-deployment.json")).unwrap();
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
        let contents =
            std::fs::read_to_string(dir.path().join("last-deployment.json")).unwrap();
        let v: Value = serde_json::from_str(&contents).unwrap();
        assert!(v["error"].is_null());
    }
}
