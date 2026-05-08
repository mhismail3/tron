//! Server-owned Codex App Server lifecycle management.
//!
//! Tron owns the child `codex app-server` process so mobile clients never have
//! to invent host commands, endpoint ports, or bearer tokens. The Rust daemon
//! starts the child on daemon startup, restarts it when server settings change,
//! exposes its current endpoint through authenticated Tron engine capability, and kills the
//! child during Tron shutdown. Startup also removes stale managed listeners
//! left behind by a hard-killed previous Tron process, but only when the
//! process command line matches both the managed listen URL and token file.

use std::fmt;
use std::io;
use std::io::Write as _;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::Arc;
use std::time::Duration;

use async_trait::async_trait;
use serde::Serialize;
use tokio::process::{Child, Command};

use crate::server::onboarding::generate_bearer_token;
use crate::settings::{CodexAppApprovalPolicy, CodexAppSandboxMode, CodexAppServerSettings};

const CODEX_BIN: &str = "codex";
const STARTUP_SETTLE: Duration = Duration::from_millis(400);
const SHUTDOWN_TIMEOUT: Duration = Duration::from_secs(5);
const STALE_PROCESS_SHUTDOWN_TIMEOUT: Duration = Duration::from_secs(2);
const REQUIRED_WS_FLAGS: [&str; 3] = ["--listen", "--ws-auth", "--ws-token-file"];

/// Runtime lifecycle state for the managed Codex child process.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum CodexAppServerState {
    /// Settings disabled the managed app-server.
    Disabled,
    /// Spawn is in progress.
    Starting,
    /// Child process is alive and ready for iOS discovery.
    Running,
    /// Child process is not running because startup or supervision failed.
    Failed,
    /// Child process was stopped because Tron is shutting down or settings changed.
    Stopped,
}

/// WebSocket endpoint fields iOS combines with the active paired-server host.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CodexAppServerEndpointStatus {
    /// `ws` for the managed listener.
    pub scheme: &'static str,
    /// `None` means clients should use the active Tron paired-server host.
    pub host: Option<String>,
    /// Listener port.
    pub port: u16,
    /// URL path segment. Currently blank for `codex app-server`.
    pub path: &'static str,
    /// Whether clients must send `Authorization: Bearer`.
    pub requires_token: bool,
    /// Raw bearer token, delivered only over authenticated Tron engine capability.
    pub bearer_token: String,
}

/// Safe subset of server-owned Codex defaults surfaced to iOS.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CodexAppServerDefaultsStatus {
    /// Default working directory iOS should pass to `thread/start`, when set.
    pub preferred_cwd: Option<String>,
    /// Default model iOS should pass to `thread/start`, when set.
    pub preferred_model: Option<String>,
    /// Default approval behavior for new threads.
    pub approval_policy: CodexAppApprovalPolicy,
    /// Default sandbox policy for new threads.
    pub sandbox_mode: CodexAppSandboxMode,
}

/// Snapshot returned by `codexApp.status`.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CodexAppServerStatus {
    /// Whether the managed child is enabled in server settings.
    pub enabled: bool,
    /// Current supervised process lifecycle state.
    pub state: CodexAppServerState,
    /// Connectable endpoint when the child is running.
    pub endpoint: Option<CodexAppServerEndpointStatus>,
    /// Server-owned defaults used by iOS when creating Codex threads.
    pub defaults: CodexAppServerDefaultsStatus,
    /// Raw listen URL passed to the child process.
    pub listen_url: String,
    /// OS process id for the managed child, when running.
    pub pid: Option<u32>,
    /// Most recent lifecycle error, if any.
    pub last_error: Option<String>,
}

/// Fully materialized child-process launch request.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CodexAppServerLaunchSpec {
    /// Executable to spawn.
    pub command: String,
    /// Process arguments, excluding the executable name.
    pub args: Vec<String>,
    /// WebSocket listener URL passed to `--listen`.
    pub listen_url: String,
    /// Absolute path to the bearer-token file passed to app-server auth.
    pub token_path: PathBuf,
}

impl CodexAppServerLaunchSpec {
    fn from_settings(settings: &CodexAppServerSettings, token_path: PathBuf) -> Self {
        let listen_url = settings.listen_url();
        Self {
            command: CODEX_BIN.to_string(),
            args: vec![
                "app-server".to_string(),
                "--listen".to_string(),
                listen_url.clone(),
                "--ws-auth".to_string(),
                "capability-token".to_string(),
                "--ws-token-file".to_string(),
                token_path.to_string_lossy().into_owned(),
            ],
            listen_url,
            token_path,
        }
    }
}

/// Capability probe result for the installed Codex CLI.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum CodexAppServerSupport {
    /// Installed CLI exposes the WebSocket App Server launch flags Tron needs.
    Supported,
    /// Installed CLI has `app-server`, but not the WebSocket listener/auth flow.
    Unsupported {
        /// Human-readable CLI version, when available.
        version: Option<String>,
        /// Required flags that were missing from `codex app-server --help`.
        missing_flags: Vec<&'static str>,
    },
}

impl CodexAppServerSupport {
    fn unsupported_message(&self) -> Option<String> {
        let Self::Unsupported {
            version,
            missing_flags,
        } = self
        else {
            return None;
        };

        let version = version.as_deref().unwrap_or("unknown version");
        Some(format!(
            "installed Codex CLI ({version}) does not support the WebSocket App Server flags {}. Upgrade Codex CLI until `codex app-server --help` lists --listen, --ws-auth, and --ws-token-file.",
            missing_flags.join(", ")
        ))
    }
}

/// Process exit snapshot for real and fake children.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CodexAppServerExit {
    /// Human-readable process exit status.
    pub description: String,
}

impl From<std::process::ExitStatus> for CodexAppServerExit {
    fn from(status: std::process::ExitStatus) -> Self {
        Self {
            description: status.to_string(),
        }
    }
}

/// Abstract spawned child used by the manager and tests.
#[async_trait]
pub trait CodexAppServerChild: Send {
    /// OS process id when available.
    fn id(&self) -> Option<u32>;
    /// Non-blocking exit probe.
    fn try_wait(&mut self) -> io::Result<Option<CodexAppServerExit>>;
    /// Terminate the child and wait up to `timeout`.
    async fn terminate(&mut self, timeout: Duration) -> io::Result<()>;
}

/// Abstract process spawner used by the manager and tests.
#[async_trait]
pub trait CodexAppServerSpawner: Send + Sync {
    /// Confirm the installed CLI supports the WebSocket App Server flags Tron
    /// needs before spawning a long-lived child.
    async fn validate_support(&self) -> io::Result<CodexAppServerSupport> {
        Ok(CodexAppServerSupport::Supported)
    }

    /// Stop stale app-server processes left behind by a prior hard-killed Tron
    /// process. Production only matches the exact listen URL and token file.
    async fn cleanup_stale_listeners(
        &self,
        _spec: &CodexAppServerLaunchSpec,
    ) -> io::Result<Vec<u32>> {
        Ok(Vec::new())
    }

    /// Spawn the managed app-server child process from a materialized spec.
    async fn spawn(
        &self,
        spec: CodexAppServerLaunchSpec,
    ) -> io::Result<Box<dyn CodexAppServerChild>>;
}

/// Production `tokio::process::Command` spawner.
#[derive(Default)]
pub struct TokioCodexAppServerSpawner;

#[async_trait]
impl CodexAppServerSpawner for TokioCodexAppServerSpawner {
    async fn validate_support(&self) -> io::Result<CodexAppServerSupport> {
        let version = codex_command_text(&["--version"])
            .await
            .ok()
            .and_then(|text| text.lines().next().map(str::trim).map(str::to_string))
            .filter(|line| !line.is_empty());
        let help = codex_command_text(&["app-server", "--help"]).await?;
        let missing_flags = REQUIRED_WS_FLAGS
            .iter()
            .copied()
            .filter(|flag| !help.contains(flag))
            .collect::<Vec<_>>();

        if missing_flags.is_empty() {
            Ok(CodexAppServerSupport::Supported)
        } else {
            Ok(CodexAppServerSupport::Unsupported {
                version,
                missing_flags,
            })
        }
    }

    async fn cleanup_stale_listeners(
        &self,
        spec: &CodexAppServerLaunchSpec,
    ) -> io::Result<Vec<u32>> {
        #[cfg(unix)]
        {
            let output = Command::new("ps")
                .args(["-axo", "pid=,command="])
                .stdin(Stdio::null())
                .output()
                .await?;
            let mut text = String::from_utf8_lossy(&output.stdout).into_owned();
            let stderr = String::from_utf8_lossy(&output.stderr);
            if !stderr.trim().is_empty() {
                if !text.is_empty() {
                    text.push('\n');
                }
                text.push_str(&stderr);
            }
            let pids = stale_codex_pids_from_ps(&text, spec, std::process::id());
            for pid in &pids {
                terminate_pid(*pid, STALE_PROCESS_SHUTDOWN_TIMEOUT).await?;
            }
            Ok(pids)
        }
        #[cfg(not(unix))]
        {
            let _ = spec;
            Ok(Vec::new())
        }
    }

    async fn spawn(
        &self,
        spec: CodexAppServerLaunchSpec,
    ) -> io::Result<Box<dyn CodexAppServerChild>> {
        let mut command = Command::new(&spec.command);
        command
            .args(&spec.args)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null());
        let child = command.spawn()?;
        Ok(Box::new(TokioCodexAppServerChild { child }))
    }
}

fn stale_codex_pids_from_ps(
    process_table: &str,
    spec: &CodexAppServerLaunchSpec,
    current_pid: u32,
) -> Vec<u32> {
    let token_path = spec.token_path.to_string_lossy();
    process_table
        .lines()
        .filter_map(|line| {
            let trimmed = line.trim_start();
            let (pid_text, command) = trimmed.split_once(char::is_whitespace)?;
            let pid = pid_text.parse::<u32>().ok()?;
            if pid == current_pid {
                return None;
            }
            let matches = command.contains("app-server")
                && command.contains("--listen")
                && command.contains(&spec.listen_url)
                && command.contains("--ws-token-file")
                && command.contains(token_path.as_ref());
            matches.then_some(pid)
        })
        .collect()
}

async fn terminate_pid(pid: u32, timeout: Duration) -> io::Result<()> {
    if !pid_exists(pid).await {
        return Ok(());
    }

    let _ = Command::new("kill")
        .arg("-TERM")
        .arg(pid.to_string())
        .stdin(Stdio::null())
        .status()
        .await;

    let deadline = tokio::time::Instant::now() + timeout;
    while tokio::time::Instant::now() < deadline {
        if !pid_exists(pid).await {
            return Ok(());
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }

    let status = Command::new("kill")
        .arg("-KILL")
        .arg(pid.to_string())
        .stdin(Stdio::null())
        .status()
        .await?;
    if status.success() || !pid_exists(pid).await {
        Ok(())
    } else {
        Err(io::Error::other(format!(
            "failed to terminate stale Codex App Server process {pid}"
        )))
    }
}

async fn pid_exists(pid: u32) -> bool {
    Command::new("kill")
        .arg("-0")
        .arg(pid.to_string())
        .stdin(Stdio::null())
        .status()
        .await
        .map(|status| status.success())
        .unwrap_or(false)
}

async fn codex_command_text(args: &[&str]) -> io::Result<String> {
    let output = Command::new(CODEX_BIN)
        .args(args)
        .stdin(Stdio::null())
        .output()
        .await?;
    let mut text = String::from_utf8_lossy(&output.stdout).into_owned();
    let stderr = String::from_utf8_lossy(&output.stderr);
    if !stderr.trim().is_empty() {
        if !text.is_empty() {
            text.push('\n');
        }
        text.push_str(&stderr);
    }
    Ok(text)
}

struct TokioCodexAppServerChild {
    child: Child,
}

#[async_trait]
impl CodexAppServerChild for TokioCodexAppServerChild {
    fn id(&self) -> Option<u32> {
        self.child.id()
    }

    fn try_wait(&mut self) -> io::Result<Option<CodexAppServerExit>> {
        self.child.try_wait().map(|exit| exit.map(Into::into))
    }

    async fn terminate(&mut self, timeout: Duration) -> io::Result<()> {
        if self.child.try_wait()?.is_some() {
            return Ok(());
        }

        let _ = self.child.start_kill();
        match tokio::time::timeout(timeout, self.child.wait()).await {
            Ok(result) => result.map(|_| ()),
            Err(_) => self.child.kill().await,
        }
    }
}

struct RuntimeState {
    settings: CodexAppServerSettings,
    state: CodexAppServerState,
    child: Option<Box<dyn CodexAppServerChild>>,
    token: String,
    last_error: Option<String>,
}

impl RuntimeState {
    fn endpoint(&self) -> Option<CodexAppServerEndpointStatus> {
        if self.state != CodexAppServerState::Running {
            return None;
        }
        Some(CodexAppServerEndpointStatus {
            scheme: CodexAppServerSettings::SCHEME,
            host: None,
            port: self.settings.port,
            path: CodexAppServerSettings::PATH,
            requires_token: true,
            bearer_token: self.token.clone(),
        })
    }

    fn defaults(&self) -> CodexAppServerDefaultsStatus {
        CodexAppServerDefaultsStatus {
            preferred_cwd: self.settings.preferred_cwd.clone(),
            preferred_model: self.settings.preferred_model.clone(),
            approval_policy: self.settings.approval_policy.clone(),
            sandbox_mode: self.settings.sandbox_mode.clone(),
        }
    }

    fn status(&self) -> CodexAppServerStatus {
        CodexAppServerStatus {
            enabled: self.settings.enabled,
            state: self.state.clone(),
            endpoint: self.endpoint(),
            defaults: self.defaults(),
            listen_url: self.settings.listen_url(),
            pid: self.child.as_ref().and_then(|child| child.id()),
            last_error: self.last_error.clone(),
        }
    }
}

/// Error returned by lifecycle operations.
#[derive(Debug)]
pub struct CodexAppServerError {
    message: String,
}

impl CodexAppServerError {
    fn new(message: impl Into<String>) -> Self {
        Self {
            message: message.into(),
        }
    }
}

impl fmt::Display for CodexAppServerError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.message)
    }
}

impl std::error::Error for CodexAppServerError {}

/// Owns the managed Codex App Server child process.
pub struct CodexAppServerManager {
    token_path: PathBuf,
    spawner: Arc<dyn CodexAppServerSpawner>,
    startup_settle: Duration,
    shutdown_timeout: Duration,
    runtime: tokio::sync::Mutex<RuntimeState>,
}

impl CodexAppServerManager {
    /// Create a production manager from current server settings.
    pub fn new(settings: CodexAppServerSettings) -> io::Result<Self> {
        Self::with_deps(
            settings,
            crate::core::paths::codex_app_server_token_path(),
            Arc::new(TokioCodexAppServerSpawner),
            STARTUP_SETTLE,
            SHUTDOWN_TIMEOUT,
        )
    }

    /// Create a manager with injected dependencies for tests.
    pub fn with_deps(
        settings: CodexAppServerSettings,
        token_path: PathBuf,
        spawner: Arc<dyn CodexAppServerSpawner>,
        startup_settle: Duration,
        shutdown_timeout: Duration,
    ) -> io::Result<Self> {
        let token = load_or_create_token_file(&token_path)?;
        let state = if settings.enabled {
            CodexAppServerState::Stopped
        } else {
            CodexAppServerState::Disabled
        };
        Ok(Self {
            token_path,
            spawner,
            startup_settle,
            shutdown_timeout,
            runtime: tokio::sync::Mutex::new(RuntimeState {
                settings,
                state,
                child: None,
                token,
                last_error: None,
            }),
        })
    }

    /// Start the managed child unless settings disable it.
    pub async fn start(&self) -> Result<(), CodexAppServerError> {
        let mut runtime = self.runtime.lock().await;
        if !runtime.settings.enabled {
            runtime.state = CodexAppServerState::Disabled;
            runtime.child = None;
            runtime.last_error = None;
            return Ok(());
        }
        if runtime.state == CodexAppServerState::Running && runtime.child.is_some() {
            return Ok(());
        }

        runtime.state = CodexAppServerState::Starting;
        runtime.last_error = None;
        let spec =
            CodexAppServerLaunchSpec::from_settings(&runtime.settings, self.token_path.clone());
        match self.spawner.validate_support().await {
            Ok(CodexAppServerSupport::Supported) => {}
            Ok(support) => {
                let message = support
                    .unsupported_message()
                    .unwrap_or_else(|| "installed Codex CLI is unsupported".to_string());
                runtime.state = CodexAppServerState::Failed;
                runtime.child = None;
                runtime.last_error = Some(message.clone());
                tracing::warn!(
                    error = %message,
                    "managed Codex App Server compatibility check failed"
                );
                return Err(CodexAppServerError::new(message));
            }
            Err(error) => {
                let message = format!(
                    "failed to verify installed Codex CLI App Server support with `{}`: {error}",
                    spec.command
                );
                runtime.state = CodexAppServerState::Failed;
                runtime.child = None;
                runtime.last_error = Some(message.clone());
                tracing::warn!(
                    error = %message,
                    "managed Codex App Server compatibility check failed"
                );
                return Err(CodexAppServerError::new(message));
            }
        }
        match self.spawner.cleanup_stale_listeners(&spec).await {
            Ok(pids) if !pids.is_empty() => {
                tracing::info!(
                    pids = ?pids,
                    listen_url = spec.listen_url,
                    "cleaned up stale managed Codex App Server listener before startup"
                );
            }
            Ok(_) => {}
            Err(error) => {
                tracing::warn!(
                    error = %error,
                    listen_url = spec.listen_url,
                    "failed to clean up stale managed Codex App Server listeners before startup"
                );
            }
        }

        let mut child = match self.spawner.spawn(spec.clone()).await {
            Ok(child) => child,
            Err(error) => {
                let message = format!(
                    "failed to start managed Codex App Server with `{}`: {error}",
                    spec.command
                );
                runtime.state = CodexAppServerState::Failed;
                runtime.child = None;
                runtime.last_error = Some(message.clone());
                tracing::warn!(error = %message, "managed Codex App Server start failed");
                return Err(CodexAppServerError::new(message));
            }
        };

        if !self.startup_settle.is_zero() {
            tokio::time::sleep(self.startup_settle).await;
        }
        match child.try_wait() {
            Ok(Some(exit)) => {
                let message = format!(
                    "managed Codex App Server exited during startup: {}",
                    exit.description
                );
                runtime.state = CodexAppServerState::Failed;
                runtime.child = None;
                runtime.last_error = Some(message.clone());
                tracing::warn!(error = %message, "managed Codex App Server exited during startup");
                Err(CodexAppServerError::new(message))
            }
            Ok(None) => {
                runtime.state = CodexAppServerState::Running;
                runtime.child = Some(child);
                tracing::info!(
                    listen_url = runtime.settings.listen_url(),
                    "managed Codex App Server started"
                );
                Ok(())
            }
            Err(error) => {
                let message =
                    format!("failed to inspect managed Codex App Server startup: {error}");
                runtime.state = CodexAppServerState::Failed;
                runtime.child = None;
                runtime.last_error = Some(message.clone());
                Err(CodexAppServerError::new(message))
            }
        }
    }

    /// Stop the managed child if it is running.
    pub async fn stop(&self) {
        let mut runtime = self.runtime.lock().await;
        if let Some(mut child) = runtime.child.take()
            && let Err(error) = child.terminate(self.shutdown_timeout).await
        {
            tracing::warn!(error = %error, "failed to terminate managed Codex App Server");
            runtime.last_error = Some(format!("failed to terminate Codex App Server: {error}"));
        }
        runtime.state = if runtime.settings.enabled {
            CodexAppServerState::Stopped
        } else {
            CodexAppServerState::Disabled
        };
    }

    /// Restart or stop the child when server settings change.
    pub async fn reconfigure(
        &self,
        settings: CodexAppServerSettings,
    ) -> Result<(), CodexAppServerError> {
        let unchanged = {
            let runtime = self.runtime.lock().await;
            runtime.settings == settings
        };
        if unchanged {
            return Ok(());
        }

        self.stop().await;
        {
            let mut runtime = self.runtime.lock().await;
            runtime.settings = settings;
            runtime.state = if runtime.settings.enabled {
                CodexAppServerState::Stopped
            } else {
                CodexAppServerState::Disabled
            };
            runtime.last_error = None;
        }
        self.start().await
    }

    /// Return current status and notice if the child exited after startup.
    pub async fn status(&self) -> CodexAppServerStatus {
        let mut runtime = self.runtime.lock().await;
        if let Some(child) = runtime.child.as_mut() {
            match child.try_wait() {
                Ok(Some(exit)) => {
                    runtime.state = CodexAppServerState::Failed;
                    runtime.child = None;
                    runtime.last_error = Some(format!(
                        "managed Codex App Server exited: {}",
                        exit.description
                    ));
                }
                Ok(None) => {}
                Err(error) => {
                    runtime.state = CodexAppServerState::Failed;
                    runtime.child = None;
                    runtime.last_error =
                        Some(format!("failed to inspect Codex App Server: {error}"));
                }
            }
        }
        runtime.status()
    }
}

fn load_or_create_token_file(path: &Path) -> io::Result<String> {
    if let Ok(existing) = std::fs::read_to_string(path) {
        let trimmed = existing.trim();
        if !trimmed.is_empty() {
            harden_token_file_permissions(path)?;
            return Ok(trimmed.to_string());
        }
    }

    let token = generate_bearer_token();
    let parent = path.parent().ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::InvalidInput,
            "Codex App Server token path has no parent directory",
        )
    })?;
    std::fs::create_dir_all(parent)?;

    let mut temp = tempfile::Builder::new()
        .prefix(".codex-app-server-token.")
        .tempfile_in(parent)?;
    temp.write_all(token.as_bytes())?;
    temp.write_all(b"\n")?;
    temp.as_file_mut().sync_all()?;
    temp.persist(path).map_err(|error| error.error)?;

    harden_token_file_permissions(path)?;

    Ok(token)
}

fn harden_token_file_permissions(path: &Path) -> io::Result<()> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))?;
    }
    #[cfg(not(unix))]
    {
        let _ = path;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use std::sync::Mutex;
    use std::sync::atomic::{AtomicUsize, Ordering};

    use super::*;

    #[derive(Default)]
    struct FakeSpawner {
        specs: Mutex<Vec<CodexAppServerLaunchSpec>>,
        terminations: Arc<AtomicUsize>,
        stale_cleanup_count: Arc<AtomicUsize>,
        stale_pids: Mutex<Vec<u32>>,
        fail: bool,
        exit_immediately: bool,
        unsupported: bool,
    }

    #[async_trait]
    impl CodexAppServerSpawner for FakeSpawner {
        async fn validate_support(&self) -> io::Result<CodexAppServerSupport> {
            if self.unsupported {
                Ok(CodexAppServerSupport::Unsupported {
                    version: Some("codex-cli 0.77.0".to_string()),
                    missing_flags: REQUIRED_WS_FLAGS.to_vec(),
                })
            } else {
                Ok(CodexAppServerSupport::Supported)
            }
        }

        async fn cleanup_stale_listeners(
            &self,
            _spec: &CodexAppServerLaunchSpec,
        ) -> io::Result<Vec<u32>> {
            self.stale_cleanup_count.fetch_add(1, Ordering::SeqCst);
            let mut stale_pids = self.stale_pids.lock().unwrap();
            let pids = stale_pids.clone();
            stale_pids.clear();
            Ok(pids)
        }

        async fn spawn(
            &self,
            spec: CodexAppServerLaunchSpec,
        ) -> io::Result<Box<dyn CodexAppServerChild>> {
            self.specs.lock().unwrap().push(spec);
            if self.fail {
                return Err(io::Error::new(io::ErrorKind::NotFound, "missing codex"));
            }
            Ok(Box::new(FakeChild {
                pid: Some(123),
                exit_immediately: self.exit_immediately,
                terminated: false,
                terminations: self.terminations.clone(),
            }))
        }
    }

    struct FakeChild {
        pid: Option<u32>,
        exit_immediately: bool,
        terminated: bool,
        terminations: Arc<AtomicUsize>,
    }

    #[async_trait]
    impl CodexAppServerChild for FakeChild {
        fn id(&self) -> Option<u32> {
            self.pid
        }

        fn try_wait(&mut self) -> io::Result<Option<CodexAppServerExit>> {
            if self.exit_immediately || self.terminated {
                Ok(Some(CodexAppServerExit {
                    description: "exit status: 1".to_string(),
                }))
            } else {
                Ok(None)
            }
        }

        async fn terminate(&mut self, _timeout: Duration) -> io::Result<()> {
            self.terminated = true;
            self.terminations.fetch_add(1, Ordering::SeqCst);
            Ok(())
        }
    }

    fn token_path(dir: &tempfile::TempDir) -> PathBuf {
        dir.path().join("run").join("codex-app-token")
    }

    #[test]
    fn launch_spec_uses_token_file_not_raw_token() {
        let settings = CodexAppServerSettings::default();
        let path = PathBuf::from("/tmp/token-file");
        let spec = CodexAppServerLaunchSpec::from_settings(&settings, path.clone());

        assert_eq!(spec.command, "codex");
        assert_eq!(spec.listen_url, "ws://0.0.0.0:4500");
        assert!(spec.args.contains(&"--ws-auth".to_string()));
        assert!(spec.args.contains(&"capability-token".to_string()));
        assert!(spec.args.contains(&"--ws-token-file".to_string()));
        assert!(spec.args.contains(&path.to_string_lossy().into_owned()));
        assert!(!spec.args.iter().any(|arg| arg.contains("Bearer ")));
    }

    #[test]
    fn stale_pid_parser_matches_only_managed_listener_for_same_token_file() {
        let settings = CodexAppServerSettings::default();
        let token_path = PathBuf::from("/tmp/tron-test/internal/run/codex-app-server-token");
        let spec = CodexAppServerLaunchSpec::from_settings(&settings, token_path);
        let processes = r#"
          123 codex app-server --listen ws://0.0.0.0:4500 --ws-auth capability-token --ws-token-file /tmp/tron-test/internal/run/codex-app-server-token
          124 codex app-server --listen ws://0.0.0.0:4501 --ws-auth capability-token --ws-token-file /tmp/tron-test/internal/run/codex-app-server-token
          125 codex app-server --analytics-default-enabled
          126 /bin/zsh -c ps -axo pid,command
        "#;

        assert_eq!(stale_codex_pids_from_ps(processes, &spec, 999), vec![123]);
        assert!(stale_codex_pids_from_ps(processes, &spec, 123).is_empty());
    }

    #[test]
    fn token_file_round_trips_existing_token() {
        let dir = tempfile::tempdir().unwrap();
        let path = token_path(&dir);
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(&path, "existing-token\n").unwrap();

        assert_eq!(load_or_create_token_file(&path).unwrap(), "existing-token");
    }

    #[cfg(unix)]
    #[test]
    fn existing_token_file_permissions_are_hardened() {
        use std::os::unix::fs::PermissionsExt;

        let dir = tempfile::tempdir().unwrap();
        let path = token_path(&dir);
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(&path, "existing-token\n").unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o644)).unwrap();

        assert_eq!(load_or_create_token_file(&path).unwrap(), "existing-token");

        let mode = std::fs::metadata(&path).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600);
    }

    #[tokio::test]
    async fn disabled_settings_do_not_spawn_child() {
        let dir = tempfile::tempdir().unwrap();
        let spawner = Arc::new(FakeSpawner::default());
        let mut settings = CodexAppServerSettings::default();
        settings.enabled = false;
        let manager = CodexAppServerManager::with_deps(
            settings,
            token_path(&dir),
            spawner.clone(),
            Duration::ZERO,
            Duration::from_millis(1),
        )
        .unwrap();

        manager.start().await.unwrap();
        let status = manager.status().await;

        assert_eq!(status.state, CodexAppServerState::Disabled);
        assert!(status.endpoint.is_none());
        assert!(spawner.specs.lock().unwrap().is_empty());
    }

    #[tokio::test]
    async fn start_spawns_child_and_exposes_endpoint_with_token() {
        let dir = tempfile::tempdir().unwrap();
        let spawner = Arc::new(FakeSpawner::default());
        let manager = CodexAppServerManager::with_deps(
            CodexAppServerSettings::default(),
            token_path(&dir),
            spawner.clone(),
            Duration::ZERO,
            Duration::from_millis(1),
        )
        .unwrap();

        manager.start().await.unwrap();
        let status = manager.status().await;

        assert_eq!(status.state, CodexAppServerState::Running);
        assert_eq!(status.pid, Some(123));
        let endpoint = status.endpoint.expect("running status has endpoint");
        assert_eq!(endpoint.scheme, "ws");
        assert_eq!(endpoint.host, None);
        assert_eq!(endpoint.port, 4500);
        assert_eq!(endpoint.bearer_token.len(), 43);
        assert_eq!(spawner.specs.lock().unwrap().len(), 1);
    }

    #[tokio::test]
    async fn start_cleans_stale_managed_listener_before_spawning_child() {
        let dir = tempfile::tempdir().unwrap();
        let spawner = Arc::new(FakeSpawner {
            stale_pids: Mutex::new(vec![22468]),
            ..Default::default()
        });
        let manager = CodexAppServerManager::with_deps(
            CodexAppServerSettings::default(),
            token_path(&dir),
            spawner.clone(),
            Duration::ZERO,
            Duration::from_millis(1),
        )
        .unwrap();

        manager.start().await.unwrap();

        assert_eq!(spawner.stale_cleanup_count.load(Ordering::SeqCst), 1);
        assert!(spawner.stale_pids.lock().unwrap().is_empty());
        assert_eq!(spawner.specs.lock().unwrap().len(), 1);
    }

    #[tokio::test]
    async fn start_failure_records_failed_status() {
        let dir = tempfile::tempdir().unwrap();
        let spawner = Arc::new(FakeSpawner {
            fail: true,
            ..Default::default()
        });
        let manager = CodexAppServerManager::with_deps(
            CodexAppServerSettings::default(),
            token_path(&dir),
            spawner,
            Duration::ZERO,
            Duration::from_millis(1),
        )
        .unwrap();

        assert!(manager.start().await.is_err());
        let status = manager.status().await;

        assert_eq!(status.state, CodexAppServerState::Failed);
        assert!(status.endpoint.is_none());
        assert!(status.last_error.unwrap().contains("missing codex"));
    }

    #[tokio::test]
    async fn unsupported_codex_cli_fails_before_spawning_child() {
        let dir = tempfile::tempdir().unwrap();
        let spawner = Arc::new(FakeSpawner {
            unsupported: true,
            ..Default::default()
        });
        let manager = CodexAppServerManager::with_deps(
            CodexAppServerSettings::default(),
            token_path(&dir),
            spawner.clone(),
            Duration::ZERO,
            Duration::from_millis(1),
        )
        .unwrap();

        assert!(manager.start().await.is_err());
        let status = manager.status().await;

        assert_eq!(status.state, CodexAppServerState::Failed);
        assert!(status.endpoint.is_none());
        assert!(status.last_error.unwrap().contains("codex-cli 0.77.0"));
        assert!(spawner.specs.lock().unwrap().is_empty());
    }

    #[tokio::test]
    async fn child_exit_after_start_is_reported_as_failed() {
        let dir = tempfile::tempdir().unwrap();
        let spawner = Arc::new(FakeSpawner {
            exit_immediately: true,
            ..Default::default()
        });
        let manager = CodexAppServerManager::with_deps(
            CodexAppServerSettings::default(),
            token_path(&dir),
            spawner,
            Duration::ZERO,
            Duration::from_millis(1),
        )
        .unwrap();

        assert!(manager.start().await.is_err());
        let status = manager.status().await;

        assert_eq!(status.state, CodexAppServerState::Failed);
        assert!(status.last_error.unwrap().contains("exited during startup"));
    }

    #[tokio::test]
    async fn reconfigure_restarts_when_port_changes() {
        let dir = tempfile::tempdir().unwrap();
        let spawner = Arc::new(FakeSpawner::default());
        let manager = CodexAppServerManager::with_deps(
            CodexAppServerSettings::default(),
            token_path(&dir),
            spawner.clone(),
            Duration::ZERO,
            Duration::from_millis(1),
        )
        .unwrap();
        manager.start().await.unwrap();

        let mut next = CodexAppServerSettings::default();
        next.port = 4501;
        manager.reconfigure(next).await.unwrap();

        let status = manager.status().await;
        assert_eq!(status.endpoint.unwrap().port, 4501);
        assert_eq!(spawner.specs.lock().unwrap().len(), 2);
    }

    #[tokio::test]
    async fn stop_terminates_running_child_and_clears_endpoint() {
        let dir = tempfile::tempdir().unwrap();
        let spawner = Arc::new(FakeSpawner::default());
        let manager = CodexAppServerManager::with_deps(
            CodexAppServerSettings::default(),
            token_path(&dir),
            spawner.clone(),
            Duration::ZERO,
            Duration::from_millis(1),
        )
        .unwrap();
        manager.start().await.unwrap();

        manager.stop().await;
        let status = manager.status().await;

        assert_eq!(status.state, CodexAppServerState::Stopped);
        assert!(status.endpoint.is_none());
        assert_eq!(spawner.terminations.load(Ordering::SeqCst), 1);
    }
}
