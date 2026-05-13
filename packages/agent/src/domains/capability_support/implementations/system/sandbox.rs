//! Sandbox execution environment for safe command execution.
//!
//! Two modes:
//! 1. **Lightweight** (`sandbox: true`): Creates a temporary directory, copies specified
//!    files in, runs the command there. No OS-level isolation, but prevents accidental
//!    host modification by constraining the working directory.
//!
//! 2. **Docker** (`sandbox: "docker"`): Runs the command inside a Docker container with
//!    configurable image, mounts, network, and user mapping.

use std::path::{Path, PathBuf};

use tracing::debug;
use uuid::Uuid;

use crate::domains::capability_support::implementations::errors::CapabilityExecutionError;

/// Tron scratch directory for sandbox workspaces.
fn scratch_dir() -> PathBuf {
    crate::shared::paths::scratch_dir()
}

/// Configuration for a lightweight sandbox.
#[derive(Clone, Debug, Default)]
pub struct SandboxConfig {
    /// Files/dirs to copy into the sandbox (source paths).
    pub copy_paths: Vec<String>,
    /// Read-only mount paths (symlinked into sandbox).
    pub readonly_mounts: Vec<String>,
}

/// Configuration for a Docker sandbox.
#[derive(Clone, Debug)]
pub struct DockerSandboxConfig {
    /// Docker image to use.
    pub image: String,
    /// Volume mounts: (`host_path`, `container_path`, "ro" | "rw").
    pub mounts: Vec<(String, String, String)>,
    /// Whether to enable network access.
    pub network: bool,
    /// Working directory inside the container.
    pub workdir: Option<String>,
    /// Environment variables for the container.
    pub env: Vec<(String, String)>,
}

impl Default for DockerSandboxConfig {
    fn default() -> Self {
        Self {
            image: "ubuntu:latest".to_string(),
            mounts: Vec::new(),
            network: false,
            workdir: None,
            env: Vec::new(),
        }
    }
}

/// A created sandbox workspace (lightweight mode).
pub struct SandboxWorkspace {
    /// Path to the temporary sandbox directory.
    pub path: PathBuf,
    /// Whether cleanup should happen on drop.
    cleanup: bool,
}

impl Drop for SandboxWorkspace {
    fn drop(&mut self) {
        if self.cleanup {
            // Remove .active marker synchronously to prevent leak on early return/panic.
            // The directory itself is left for cleanup_stale_sandboxes (async removal).
            let marker = self.path.join(".active");
            let _ = std::fs::remove_file(marker);
        }
    }
}

impl SandboxWorkspace {
    /// Create a new lightweight sandbox workspace.
    pub async fn create(config: &SandboxConfig) -> Result<Self, CapabilityExecutionError> {
        let id = Uuid::now_v7();
        let sandbox_path = scratch_dir().join(format!("sandbox-{id}"));

        tokio::fs::create_dir_all(&sandbox_path)
            .await
            .map_err(|e| CapabilityExecutionError::Internal {
                message: format!("Failed to create sandbox directory: {e}"),
            })?;

        debug!(path = %sandbox_path.display(), "created sandbox workspace");

        // Copy specified files into sandbox
        for src in &config.copy_paths {
            let src_path = Path::new(src);
            if src_path.exists() {
                let dest = sandbox_path.join(src_path.file_name().unwrap_or_default());
                if src_path.is_dir() {
                    copy_dir_recursive(src_path, &dest).await?;
                } else {
                    let _ = tokio::fs::copy(src_path, &dest).await.map_err(|e| {
                        CapabilityExecutionError::Internal {
                            message: format!("Failed to copy {src} into sandbox: {e}"),
                        }
                    })?;
                }
            }
        }

        // Create symlinks for read-only mounts
        for mount in &config.readonly_mounts {
            let mount_path = Path::new(mount);
            if mount_path.exists() {
                let link = sandbox_path.join(mount_path.file_name().unwrap_or_default());
                tokio::fs::symlink(mount_path, &link).await.map_err(|e| {
                    CapabilityExecutionError::Internal {
                        message: format!("Failed to mount {mount} into sandbox: {e}"),
                    }
                })?;
            }
        }

        // Write .active marker to prevent cleanup_stale_sandboxes from removing this sandbox
        let marker = sandbox_path.join(".active");
        let _ = tokio::fs::write(&marker, b"").await;

        Ok(Self {
            path: sandbox_path,
            cleanup: true,
        })
    }

    /// Keep the sandbox (don't clean up on drop).
    pub fn keep(&mut self) {
        self.cleanup = false;
    }

    /// Explicitly clean up the sandbox directory.
    pub async fn cleanup(self) -> Result<(), CapabilityExecutionError> {
        // Remove .active marker before cleanup
        let marker = self.path.join(".active");
        let _ = tokio::fs::remove_file(&marker).await;

        if self.path.exists() {
            tokio::fs::remove_dir_all(&self.path).await.map_err(|e| {
                CapabilityExecutionError::Internal {
                    message: format!("Failed to cleanup sandbox: {e}"),
                }
            })?;
            debug!(path = %self.path.display(), "cleaned up sandbox");
        }
        Ok(())
    }
}

/// Build a Docker run command string.
pub fn build_docker_command(command: &str, config: &DockerSandboxConfig) -> String {
    let mut parts = vec!["docker".to_string(), "run".to_string(), "--rm".to_string()];

    // User mapping to match host user
    parts.push("--user".to_string());
    parts.push("$(id -u):$(id -g)".to_string());

    // Network
    if !config.network {
        parts.push("--network=none".to_string());
    }

    // Working directory
    if let Some(ref wd) = config.workdir {
        parts.push("-w".to_string());
        parts.push(wd.clone());
    }

    // Volume mounts
    for (host, container, mode) in &config.mounts {
        parts.push("-v".to_string());
        parts.push(format!("{host}:{container}:{mode}"));
    }

    // Environment variables
    for (key, value) in &config.env {
        parts.push("-e".to_string());
        parts.push(format!("{key}={value}"));
    }

    // Image
    parts.push(config.image.clone());

    // Command — escape single quotes to prevent shell injection
    parts.push("sh".to_string());
    parts.push("-c".to_string());
    parts.push(format!("'{}'", command.replace('\'', "'\\''")));

    parts.join(" ")
}

/// Check if Docker CLI is available and the daemon is running.
pub async fn check_docker_available() -> Result<(), String> {
    let output = tokio::process::Command::new("docker")
        .arg("info")
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::piped())
        .output()
        .await;

    match output {
        Ok(o) if o.status.success() => Ok(()),
        Ok(o) => {
            let stderr = String::from_utf8_lossy(&o.stderr);
            if stderr.contains("Cannot connect") || stderr.contains("Is the docker daemon running") {
                Err("Docker Desktop is installed but not running. Start it from Applications.".into())
            } else {
                Err(format!("Docker error: {}", stderr.trim()))
            }
        }
        Err(_) => Err(
            "Docker CLI not found. Install Docker Desktop from https://www.docker.com/products/docker-desktop/".into(),
        ),
    }
}

/// Recursively copy a directory.
async fn copy_dir_recursive(src: &Path, dest: &Path) -> Result<(), CapabilityExecutionError> {
    tokio::fs::create_dir_all(dest)
        .await
        .map_err(|e| CapabilityExecutionError::Internal {
            message: format!("Failed to create dir {}: {e}", dest.display()),
        })?;

    let mut entries =
        tokio::fs::read_dir(src)
            .await
            .map_err(|e| CapabilityExecutionError::Internal {
                message: format!("Failed to read dir {}: {e}", src.display()),
            })?;

    while let Some(entry) =
        entries
            .next_entry()
            .await
            .map_err(|e| CapabilityExecutionError::Internal {
                message: format!("Failed to read entry: {e}"),
            })?
    {
        let entry_path = entry.path();
        let dest_path = dest.join(entry.file_name());

        if entry_path.is_dir() {
            Box::pin(copy_dir_recursive(&entry_path, &dest_path)).await?;
        } else {
            let _ = tokio::fs::copy(&entry_path, &dest_path)
                .await
                .map_err(|e| CapabilityExecutionError::Internal {
                    message: format!("Failed to copy file: {e}"),
                })?;
        }
    }

    Ok(())
}

/// Clean up stale sandbox directories (older than 24 hours).
pub async fn cleanup_stale_sandboxes() {
    let scratch = scratch_dir();
    if !scratch.exists() {
        return;
    }

    let cutoff = std::time::SystemTime::now() - std::time::Duration::from_secs(24 * 60 * 60);

    if let Ok(mut entries) = tokio::fs::read_dir(&scratch).await {
        while let Ok(Some(entry)) = entries.next_entry().await {
            let name = entry.file_name().to_string_lossy().to_string();
            if !name.starts_with("sandbox-") {
                continue;
            }
            // Skip sandboxes with .active marker (still in use)
            if entry.path().join(".active").exists() {
                debug!(path = %entry.path().display(), "skipping active sandbox");
                continue;
            }
            if let Ok(meta) = entry.metadata().await
                && let Ok(modified) = meta.modified()
                && modified < cutoff
            {
                let _ = tokio::fs::remove_dir_all(entry.path()).await;
                debug!(path = %entry.path().display(), "cleaned stale sandbox");
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn sandbox_creates_temp_dir() {
        let workspace = SandboxWorkspace::create(&SandboxConfig::default())
            .await
            .unwrap();
        assert!(workspace.path.exists());
        assert!(workspace.path.is_dir());
        let path_str = workspace.path.to_string_lossy().to_string();
        assert!(path_str.contains("sandbox-"));
        workspace.cleanup().await.unwrap();
    }

    #[tokio::test]
    async fn sandbox_cleanup_after_success() {
        let workspace = SandboxWorkspace::create(&SandboxConfig::default())
            .await
            .unwrap();
        let path = workspace.path.clone();
        assert!(path.exists());
        workspace.cleanup().await.unwrap();
        assert!(!path.exists());
    }

    #[tokio::test]
    async fn sandbox_copies_files() {
        // Create a temp file to copy
        let tmp = std::env::temp_dir().join(format!("sandbox-test-{}", Uuid::now_v7()));
        tokio::fs::write(&tmp, b"test content").await.unwrap();

        let config = SandboxConfig {
            copy_paths: vec![tmp.to_string_lossy().to_string()],
            readonly_mounts: Vec::new(),
        };
        let workspace = SandboxWorkspace::create(&config).await.unwrap();

        let copied = workspace.path.join(tmp.file_name().unwrap());
        assert!(copied.exists());
        let content = tokio::fs::read_to_string(&copied).await.unwrap();
        assert_eq!(content, "test content");

        workspace.cleanup().await.unwrap();
        let _ = tokio::fs::remove_file(&tmp).await;
    }

    #[test]
    fn docker_command_basic() {
        let config = DockerSandboxConfig::default();
        let cmd = build_docker_command("echo hello", &config);
        assert!(cmd.contains("docker run --rm"));
        assert!(cmd.contains("ubuntu:latest"));
        assert!(cmd.contains("echo hello"));
    }

    #[test]
    fn docker_command_no_network() {
        let config = DockerSandboxConfig {
            network: false,
            ..Default::default()
        };
        let cmd = build_docker_command("ls", &config);
        assert!(cmd.contains("--network=none"));
    }

    #[test]
    fn docker_command_with_mounts() {
        let config = DockerSandboxConfig {
            mounts: vec![("/host/path".into(), "/container/path".into(), "ro".into())],
            ..Default::default()
        };
        let cmd = build_docker_command("ls", &config);
        assert!(cmd.contains("-v /host/path:/container/path:ro"));
    }

    #[test]
    fn docker_command_with_env() {
        let config = DockerSandboxConfig {
            env: vec![("FOO".into(), "bar".into())],
            ..Default::default()
        };
        let cmd = build_docker_command("ls", &config);
        assert!(cmd.contains("-e FOO=bar"));
    }

    #[test]
    fn docker_command_with_workdir() {
        let config = DockerSandboxConfig {
            workdir: Some("/app".into()),
            ..Default::default()
        };
        let cmd = build_docker_command("ls", &config);
        assert!(cmd.contains("-w /app"));
    }

    #[test]
    fn docker_command_custom_image() {
        let config = DockerSandboxConfig {
            image: "node:20-alpine".into(),
            ..Default::default()
        };
        let cmd = build_docker_command("node -v", &config);
        assert!(cmd.contains("node:20-alpine"));
    }

    #[test]
    fn docker_command_user_mapping() {
        let config = DockerSandboxConfig::default();
        let cmd = build_docker_command("ls", &config);
        assert!(cmd.contains("--user $(id -u):$(id -g)"));
    }

    #[tokio::test]
    async fn sandbox_cleanup_after_failure() {
        let workspace = SandboxWorkspace::create(&SandboxConfig::default())
            .await
            .unwrap();
        let path = workspace.path.clone();
        // Simulate failure by just checking cleanup still works
        assert!(path.exists());
        workspace.cleanup().await.unwrap();
        assert!(!path.exists());
    }

    // ── Docker command shell injection tests ───────────────────

    #[test]
    fn docker_command_escapes_single_quotes() {
        let config = DockerSandboxConfig::default();
        let cmd = build_docker_command("echo 'hello world'", &config);
        assert!(cmd.contains("'echo '\\''hello world'\\'''"));
    }

    #[test]
    fn docker_command_prevents_injection() {
        let config = DockerSandboxConfig::default();
        let cmd = build_docker_command("'; rm -rf /; echo '", &config);
        // Each single quote in the input is escaped as '\'' (end-quote, literal-quote, start-quote)
        // Full sh -c arg: ''\''; rm -rf /; echo '\'''
        let expected_arg = "''\\''; rm -rf /; echo '\\'''";
        assert!(
            cmd.ends_with(&format!("sh -c {expected_arg}")),
            "Expected injection-safe escaping, got: {cmd}"
        );
    }

    #[test]
    fn docker_command_backslashes_unchanged() {
        let config = DockerSandboxConfig::default();
        let cmd = build_docker_command("echo \"foo\\\\bar\"", &config);
        assert!(cmd.contains("foo\\\\bar"));
    }

    #[test]
    fn docker_command_double_quotes_pass_through() {
        let config = DockerSandboxConfig::default();
        let cmd = build_docker_command("echo \"hello\"", &config);
        assert!(cmd.contains("echo \"hello\""));
    }

    #[test]
    fn docker_command_dollar_signs_preserved() {
        let config = DockerSandboxConfig::default();
        let cmd = build_docker_command("echo $HOME", &config);
        assert!(cmd.contains("echo $HOME"));
    }

    #[test]
    fn docker_command_empty_string() {
        let config = DockerSandboxConfig::default();
        let cmd = build_docker_command("", &config);
        assert!(cmd.contains("sh -c ''"));
    }

    #[test]
    fn docker_command_newlines_preserved() {
        let config = DockerSandboxConfig::default();
        let cmd = build_docker_command("echo foo\nbar", &config);
        assert!(cmd.contains("echo foo\nbar"));
    }

    #[test]
    fn docker_command_null_bytes_handled() {
        let config = DockerSandboxConfig::default();
        let cmd = build_docker_command("echo foo\0bar", &config);
        // Should not panic — null bytes pass through
        assert!(cmd.contains("sh -c"));
    }

    #[tokio::test]
    async fn sandbox_mounts_readonly_dir() {
        // Create a temp directory to mount
        let mount_dir = std::env::temp_dir().join(format!("sandbox-mount-{}", Uuid::now_v7()));
        tokio::fs::create_dir_all(&mount_dir).await.unwrap();
        tokio::fs::write(mount_dir.join("file.txt"), b"mounted content")
            .await
            .unwrap();

        let config = SandboxConfig {
            copy_paths: Vec::new(),
            readonly_mounts: vec![mount_dir.to_string_lossy().to_string()],
        };
        let workspace = SandboxWorkspace::create(&config).await.unwrap();

        // The mount should appear as a symlink in the sandbox
        let link = workspace.path.join(mount_dir.file_name().unwrap());
        assert!(link.exists());
        // Should be able to read through the symlink
        let content = tokio::fs::read_to_string(link.join("file.txt"))
            .await
            .unwrap();
        assert_eq!(content, "mounted content");

        workspace.cleanup().await.unwrap();
        let _ = tokio::fs::remove_dir_all(&mount_dir).await;
    }

    #[tokio::test]
    async fn sandbox_creates_active_marker() {
        let workspace = SandboxWorkspace::create(&SandboxConfig::default())
            .await
            .unwrap();
        let marker = workspace.path.join(".active");
        assert!(marker.exists(), ".active marker should exist after create");
        workspace.cleanup().await.unwrap();
    }

    #[tokio::test]
    async fn sandbox_cleanup_removes_marker() {
        let workspace = SandboxWorkspace::create(&SandboxConfig::default())
            .await
            .unwrap();
        let path = workspace.path.clone();
        let marker = path.join(".active");
        assert!(marker.exists());
        workspace.cleanup().await.unwrap();
        assert!(!marker.exists());
        assert!(!path.exists());
    }

    #[tokio::test]
    async fn sandbox_path_is_under_scratch_dir() {
        let workspace = SandboxWorkspace::create(&SandboxConfig::default())
            .await
            .unwrap();
        let path_str = workspace.path.to_string_lossy().to_string();
        let expected = format!(
            ".tron/{}/{}/sandbox-",
            crate::shared::paths::dirs::WORKSPACE,
            crate::shared::paths::dirs::SCRATCH
        );
        assert!(path_str.contains(&expected));
        workspace.cleanup().await.unwrap();
    }

    #[tokio::test]
    async fn sandbox_keep_prevents_cleanup() {
        let mut workspace = SandboxWorkspace::create(&SandboxConfig::default())
            .await
            .unwrap();
        let path = workspace.path.clone();
        workspace.keep();
        // Drop without cleanup — path should still exist
        drop(workspace);
        assert!(path.exists());
        // Manual cleanup
        let _ = tokio::fs::remove_dir_all(&path).await;
    }
}
