//! Server-side deploy: types, sentinel I/O, atomic binary install, Axum handlers.

#[path = "deploy/service.rs"]
mod service;

use std::io;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};

use axum::extract::State;
use axum::http::StatusCode;
use axum::response::Json;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use tracing::{debug, info, warn};

use self::service::DeployService;
use crate::server::server::AppState;

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
    pub initiated_by: String,
    /// Self-test results (populated after startup self-test runs).
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub self_test: Option<SelfTestResult>,
    /// SHA-256 hash of the deployed binary (for integrity verification).
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub binary_sha256: Option<String>,
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

/// Read the deployed commit from `system/deployment/deployed-commit`.
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

/// Write a file atomically using temp-file + rename (crash-safe).
fn atomic_write(dir: &Path, filename: &str, content: &str) -> io::Result<()> {
    std::fs::create_dir_all(dir)?;
    let target = dir.join(filename);
    let tmp = dir.join(format!("{filename}.tmp"));
    std::fs::write(&tmp, content)?;
    std::fs::rename(&tmp, &target)
}

/// Write the restart sentinel (atomic: temp file + rename).
pub fn write_sentinel(artifacts_dir: &Path, sentinel: &RestartSentinel) -> io::Result<()> {
    let json = serde_json::to_string_pretty(sentinel).map_err(io::Error::other)?;
    atomic_write(artifacts_dir, "restart-sentinel.json", &json)
}

/// Compute SHA-256 hash of a file (streaming, for large binaries).
pub fn compute_binary_hash(path: &Path) -> io::Result<String> {
    use sha2::{Digest, Sha256};
    use std::io::Read;

    let mut file = std::fs::File::open(path)?;
    let mut hasher = Sha256::new();
    let mut buffer = [0u8; 8192];
    loop {
        let n = file.read(&mut buffer)?;
        if n == 0 {
            break;
        }
        hasher.update(&buffer[..n]);
    }
    Ok(format!("{:x}", hasher.finalize()))
}

/// Verify a deployed binary against its expected SHA-256 hash.
///
/// Returns `Ok(true)` if hash matches, `Ok(false)` on mismatch,
/// `Err` if the binary can't be read.
pub fn verify_binary_hash(binary_path: &Path, expected_hash: &str) -> io::Result<bool> {
    let actual = compute_binary_hash(binary_path)?;
    Ok(actual == expected_hash)
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
    atomic_write(artifacts_dir, "restart-sentinel.json", &json)?;
    Ok(Some(sentinel))
}

/// Write `last-deployment.json` compatible with `scripts/tron` format.
///
/// `artifacts_dir` should be `~/.tron/system/deployment/`.
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
    atomic_write(artifacts_dir, "last-deployment.json", &pretty)
}

async fn read_deployed_commit_async(artifacts_dir: &Path) -> String {
    tokio::fs::read_to_string(artifacts_dir.join("deployed-commit"))
        .await
        .map_or_else(|_| "unknown".to_string(), |s| s.trim().to_string())
}

async fn read_sentinel_async(artifacts_dir: &Path) -> Option<RestartSentinel> {
    let data = tokio::fs::read_to_string(artifacts_dir.join("restart-sentinel.json"))
        .await
        .ok()?;
    serde_json::from_str(&data).ok()
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
    deploy_dir: &Path,
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
        // 5. Binary hash integrity
        check_binary_hash(binary_path, deploy_dir),
        // 6. Disk space
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

fn check_binary_hash(binary_path: &Path, deploy_dir: &Path) -> SelfTestCheck {
    let sentinel = match read_sentinel(deploy_dir) {
        Some(s) => s,
        None => {
            return SelfTestCheck {
                name: "binary_hash".into(),
                passed: true,
                detail: Some("no sentinel — skipping hash check".into()),
            };
        }
    };
    let expected = match sentinel.binary_sha256 {
        Some(h) => h,
        None => {
            return SelfTestCheck {
                name: "binary_hash".into(),
                passed: true,
                detail: Some("no hash in sentinel — pre-hash deployment".into()),
            };
        }
    };
    match verify_binary_hash(binary_path, &expected) {
        Ok(true) => SelfTestCheck {
            name: "binary_hash".into(),
            passed: true,
            detail: None,
        },
        Ok(false) => {
            warn!(
                binary = %binary_path.display(),
                "binary hash mismatch — possible tampering"
            );
            SelfTestCheck {
                name: "binary_hash".into(),
                passed: false,
                detail: Some("hash mismatch — binary may have been tampered with".into()),
            }
        }
        Err(e) => SelfTestCheck {
            name: "binary_hash".into(),
            passed: false,
            detail: Some(format!("hash verification failed: {e}")),
        },
    }
}

fn check_disk_space(reference_path: &Path) -> SelfTestCheck {
    let path = reference_path.parent().unwrap_or(Path::new("/"));
    disk_self_test_from_result(crate::server::disk::available_megabytes(path))
}

fn disk_self_test_from_result(result: io::Result<u64>) -> SelfTestCheck {
    match result {
        Ok(mb) if mb < 100 => SelfTestCheck {
            name: "disk".into(),
            passed: false,
            detail: Some(format!("{mb}MB free (< 100MB)")),
        },
        Ok(mb) => SelfTestCheck {
            name: "disk".into(),
            passed: true,
            detail: Some(format!("{mb}MB free")),
        },
        Err(error) => SelfTestCheck {
            name: "disk".into(),
            passed: false,
            detail: Some(format!("disk probe failed: {error}")),
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

/// Sign the app bundle containing the given binary.
///
/// Walks up from the binary path to find the `.app` bundle root, then signs
/// the entire bundle with the best available code signing identity.
/// Priority: Developer ID Application > Apple Development > any valid cert > ad-hoc.
/// Failures are logged but non-fatal — the binary still works unsigned.
pub fn codesign_binary(path: &Path) {
    // Find the .app bundle root by walking up from the binary
    // Expected layout: Tron.app/Contents/MacOS/tron
    let bundle = path
        .ancestors()
        .find(|p| p.extension().is_some_and(|e| e == "app"));
    let Some(bundle) = bundle else {
        debug!("binary is not inside an .app bundle, skipping signing");
        return;
    };

    // Find valid (non-revoked) codesigning identity
    let identity = std::process::Command::new("security")
        .args(["find-identity", "-v", "-p", "codesigning"])
        .output()
        .ok()
        .and_then(|o| {
            if !o.status.success() {
                return None;
            }
            let out = String::from_utf8(o.stdout).ok()?;
            // Prefer Developer ID > Apple Development > any valid cert
            let lines: Vec<&str> = out
                .lines()
                .filter(|l| l.contains('"') && !l.contains("REVOKED"))
                .collect();
            let best = lines
                .iter()
                .find(|l| l.contains("Developer ID Application"))
                .or_else(|| lines.iter().find(|l| l.contains("Apple Development")))
                .or_else(|| lines.first());
            best.and_then(|line| {
                let start = line.find('"')?;
                let end = line.rfind('"')?;
                if end > start {
                    Some(line[start + 1..end].to_string())
                } else {
                    None
                }
            })
        });

    let bundle_str = bundle.to_string_lossy();
    let bundle_id = "com.tron.agent";

    // Locate the entitlements file next to the deployed bundle.
    // Expected layout: ~/.tron/system/Tron.app + ~/.tron/system/deployment/tron-agent.entitlements
    // (bundle.parent() is ~/.tron/system/, so join deployment/tron-agent.entitlements)
    let entitlements_path = bundle
        .parent()
        .map(|p| p.join("deployment").join("tron-agent.entitlements"))
        .filter(|p| p.exists());

    if let Some(ref identity) = identity {
        // Try full signing with hardened runtime + entitlements (matches
        // the shell-script codesign_bundle() tier 1 path).
        let mut args: Vec<&str> = vec![
            "--force", "--deep", "--sign", identity,
            "--identifier", bundle_id,
            "--options", "runtime",
        ];
        let entitlements_str;
        if let Some(ref ent) = entitlements_path {
            entitlements_str = ent.to_string_lossy().into_owned();
            args.push("--entitlements");
            args.push(&entitlements_str);
        } else {
            debug!("entitlements file not found — signing without entitlements");
        }
        args.push(&bundle_str);

        let result = std::process::Command::new("codesign").args(&args).output();

        if let Ok(o) = result {
            if o.status.success() {
                info!(
                    identity = identity.as_str(),
                    entitlements = entitlements_path.is_some(),
                    "signed app bundle for TCC persistence"
                );
                return;
            }
        }
    }

    // Fallback: ad-hoc signing
    match std::process::Command::new("codesign")
        .args([
            "--force", "--deep", "--sign", "-",
            "--identifier", bundle_id,
            &bundle_str,
        ])
        .output()
    {
        Ok(o) if o.status.success() => {
            info!("ad-hoc signed app bundle");
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
    Json(DeployService::new(&state).status().await)
}

/// POST /deploy/restart
pub async fn restart_handler(
    State(state): State<AppState>,
    axum::Json(req): axum::Json<DeployRestartRequest>,
) -> Result<Json<DeployRestartResponse>, (StatusCode, Json<Value>)> {
    DeployService::new(&state)
        .restart(req)
        .await
        .map(Json)
        .map_err(Into::into)
}


#[cfg(test)]
#[path = "deploy_tests.rs"]
mod tests;
