use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use axum::http::StatusCode;
use axum::response::Json;
use serde_json::{Value, json};
use tracing::{debug, info, warn};

use crate::server::rpc::context::RpcContext;
use crate::server::rpc::errors::RpcError;
use crate::server::rpc::types::RpcEvent;
use crate::server::server::AppState;
use crate::server::shutdown::ShutdownCoordinator;
use crate::server::websocket::broadcast::BroadcastManager;

use super::{
    DeployRestartRequest, DeployRestartResponse, DeployStatusResponse, RestartSentinel,
    atomic_binary_install, git_head_commit, read_deployed_commit_async, read_sentinel_async,
    resolve_source_binary, resolve_workspace_root, write_sentinel,
};

pub(crate) struct DeployService {
    broadcast: Arc<BroadcastManager>,
    shutdown: Arc<ShutdownCoordinator>,
    rpc_context: Arc<RpcContext>,
    restart_flag: Arc<AtomicBool>,
    binary_path: PathBuf,
    deploy_dir: PathBuf,
}

impl DeployService {
    pub(crate) fn new(state: &AppState) -> Self {
        Self {
            broadcast: Arc::clone(&state.broadcast),
            shutdown: Arc::clone(&state.shutdown),
            rpc_context: Arc::clone(&state.rpc_context),
            restart_flag: Arc::clone(&state.deploy_restart_initiated),
            binary_path: state.deploy_binary_path.clone(),
            deploy_dir: state.deploy_dir.clone(),
        }
    }

    pub(crate) async fn status(&self) -> DeployStatusResponse {
        let (deployed_commit, sentinel, binary_metadata) = tokio::join!(
            read_deployed_commit_async(&self.deploy_dir),
            read_sentinel_async(&self.deploy_dir),
            tokio::fs::metadata(&self.binary_path),
        );

        let binary_exists = binary_metadata.is_ok();
        let binary_modified = binary_metadata
            .ok()
            .and_then(|m| m.modified().ok())
            .map(|t| {
                let dt: chrono::DateTime<chrono::Utc> = t.into();
                dt.to_rfc3339_opts(chrono::SecondsFormat::Secs, true)
            });

        let restart_initiated = self.restart_flag.load(Ordering::Relaxed);

        DeployStatusResponse {
            version: env!("CARGO_PKG_VERSION").to_string(),
            deployed_commit,
            binary_path: self.binary_path.to_string_lossy().to_string(),
            binary_exists,
            binary_modified,
            restart_initiated,
            sentinel,
        }
    }

    pub(crate) async fn restart(
        &self,
        req: DeployRestartRequest,
    ) -> Result<DeployRestartResponse, DeployHttpError> {
        let guard = RestartFlagGuard::acquire(Arc::clone(&self.restart_flag))?;

        let workspace_root = resolve_workspace_root();
        let source = resolve_source_binary(req.source_binary.as_deref(), workspace_root.as_deref())
            .ok_or_else(|| {
                DeployHttpError::bad_request(
                    "cannot resolve source binary: set TRON_REPO_ROOT env or pass sourceBinary",
                )
            })?;

        ensure_source_exists(&source).await?;

        let previous_commit = read_deployed_commit_async(&self.deploy_dir).await;
        let new_commit = self.resolve_commit(workspace_root).await?;
        self.ensure_deploy_dir_ready().await?;

        let _backup = atomic_binary_install(&source, &self.binary_path, &self.deploy_dir)
            .await
            .map_err(|error| {
                DeployHttpError::internal(format!("binary install failed: {error}"))
            })?;

        let sentinel = self
            .persist_restart_artifacts(&req, &new_commit, &previous_commit)
            .await?;

        self.spawn_restart_task(req.delay_ms, sentinel);
        guard.commit();

        Ok(DeployRestartResponse {
            ok: true,
            restarting_in_ms: req.delay_ms,
            commit: new_commit,
            previous_commit,
        })
    }

    async fn resolve_commit(
        &self,
        workspace_root: Option<PathBuf>,
    ) -> Result<String, DeployHttpError> {
        self.rpc_context
            .run_blocking("http.deploy.git_head", move || {
                Ok(workspace_root
                    .as_deref()
                    .and_then(git_head_commit)
                    .unwrap_or_else(|| "unknown".to_string()))
            })
            .await
            .map_err(|error| {
                DeployHttpError::internal(format!("failed to resolve git commit: {error}"))
            })
    }

    async fn ensure_deploy_dir_ready(&self) -> Result<(), DeployHttpError> {
        tokio::fs::create_dir_all(&self.deploy_dir)
            .await
            .map_err(|error| {
                DeployHttpError::internal(format!(
                    "failed to prepare deploy directory '{}': {error}",
                    self.deploy_dir.display()
                ))
            })
    }

    async fn persist_restart_artifacts(
        &self,
        req: &DeployRestartRequest,
        new_commit: &str,
        previous_commit: &str,
    ) -> Result<RestartSentinel, DeployHttpError> {
        let commit_path = self.deploy_dir.join("deployed-commit");
        tokio::fs::write(&commit_path, new_commit)
            .await
            .map_err(|error| {
                DeployHttpError::internal(format!(
                    "failed to write deployed commit '{}': {error}",
                    commit_path.display()
                ))
            })?;

        let sentinel = RestartSentinel {
            action: "deploy".to_string(),
            timestamp: chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true),
            commit: new_commit.to_string(),
            previous_commit: previous_commit.to_string(),
            status: "restarting".to_string(),
            completed_at: None,
            initiated_by: req.session_id.clone().or_else(|| Some("api".to_string())),
            self_test: None,
        };
        let deploy_dir = self.deploy_dir.clone();
        let sentinel_for_write = sentinel.clone();
        self.rpc_context
            .run_blocking("http.deploy.write_sentinel", move || {
                write_sentinel(&deploy_dir, &sentinel_for_write).map_err(|error| {
                    RpcError::Internal {
                        message: format!("failed to write restart sentinel: {error}"),
                    }
                })?;
                Ok(())
            })
            .await
            .map_err(DeployHttpError::from)?;

        Ok(sentinel)
    }

    fn spawn_restart_task(&self, delay_ms: u64, sentinel: RestartSentinel) {
        let broadcast = Arc::clone(&self.broadcast);
        let shutdown = Arc::clone(&self.shutdown);
        let orchestrator = Arc::clone(&self.rpc_context.orchestrator);

        drop(tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(delay_ms)).await;

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

            info!("deploy: initiating graceful shutdown");
            shutdown
                .graceful_shutdown(vec![], Some(Duration::from_secs(5)))
                .await;

            info!("deploy: exiting process for restart (code 42)");
            std::process::exit(42);
        }));
    }
}

async fn ensure_source_exists(source: &Path) -> Result<(), DeployHttpError> {
    tokio::fs::metadata(source).await.map(|_| ()).map_err(|_| {
        DeployHttpError::bad_request(format!("source binary not found: {}", source.display()))
    })
}

struct RestartFlagGuard {
    restart_flag: Arc<AtomicBool>,
    committed: bool,
}

impl RestartFlagGuard {
    fn acquire(restart_flag: Arc<AtomicBool>) -> Result<Self, DeployHttpError> {
        if restart_flag
            .compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst)
            .is_err()
        {
            return Err(DeployHttpError::conflict("restart already initiated"));
        }

        Ok(Self {
            restart_flag,
            committed: false,
        })
    }

    fn commit(mut self) {
        self.committed = true;
    }
}

impl Drop for RestartFlagGuard {
    fn drop(&mut self) {
        if !self.committed {
            self.restart_flag.store(false, Ordering::SeqCst);
        }
    }
}

#[derive(Debug)]
pub(crate) struct DeployHttpError {
    status: StatusCode,
    message: String,
}

impl DeployHttpError {
    fn bad_request(message: impl Into<String>) -> Self {
        Self {
            status: StatusCode::BAD_REQUEST,
            message: message.into(),
        }
    }

    fn conflict(message: impl Into<String>) -> Self {
        Self {
            status: StatusCode::CONFLICT,
            message: message.into(),
        }
    }

    fn internal(message: impl Into<String>) -> Self {
        Self {
            status: StatusCode::INTERNAL_SERVER_ERROR,
            message: message.into(),
        }
    }
}

impl From<RpcError> for DeployHttpError {
    fn from(error: RpcError) -> Self {
        Self::internal(error.to_string())
    }
}

impl From<DeployHttpError> for (StatusCode, Json<Value>) {
    fn from(error: DeployHttpError) -> Self {
        (
            error.status,
            Json(json!({
                "error": error.message,
            })),
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn restart_flag_guard_resets_flag_on_drop() {
        let flag = Arc::new(AtomicBool::new(false));
        let guard = RestartFlagGuard::acquire(Arc::clone(&flag)).unwrap();
        assert!(flag.load(Ordering::SeqCst));
        drop(guard);
        assert!(!flag.load(Ordering::SeqCst));
    }

    #[test]
    fn restart_flag_guard_preserves_flag_after_commit() {
        let flag = Arc::new(AtomicBool::new(false));
        let guard = RestartFlagGuard::acquire(Arc::clone(&flag)).unwrap();
        guard.commit();
        assert!(flag.load(Ordering::SeqCst));
    }
}
