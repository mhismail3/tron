//! Browser provider discovery and auto-setup.

use std::path::PathBuf;
use std::sync::Arc;

use super::provider::BrowserProvider;

pub mod agent_browser;
pub mod stub;

/// Discover the best available browser provider, installing prerequisites if needed.
///
/// Discovery order:
/// 1. Explicit `executable_path` from settings
/// 2. `AGENT_BROWSER_PATH` environment variable
/// 3. `agent-browser` on PATH
/// 4. Auto-install via `brew install agent-browser` (macOS only)
///
/// Once a binary is found, runs `agent-browser install` to ensure Chrome for
/// Testing is downloaded (idempotent — fast no-op if already present).
pub fn find_browser_provider(
    stream_port: u16,
    executable_path: Option<&str>,
    headed: bool,
) -> Option<Arc<dyn BrowserProvider>> {
    // 1. Check explicit executable path from settings
    if let Some(path) = executable_path {
        let p = PathBuf::from(path);
        if p.is_file() {
            ensure_browser_installed(&p);
            return Some(Arc::new(agent_browser::AgentBrowserProvider::new(
                p,
                stream_port,
                headed,
            )));
        }
        tracing::warn!(path = %path, "browser executable_path set but not a valid file");
    }

    // 2. Check AGENT_BROWSER_PATH env var
    if let Ok(path) = std::env::var("AGENT_BROWSER_PATH") {
        let p = PathBuf::from(&path);
        if p.is_file() {
            ensure_browser_installed(&p);
            return Some(Arc::new(agent_browser::AgentBrowserProvider::new(
                p,
                stream_port,
                headed,
            )));
        }
        tracing::warn!(path = %path, "AGENT_BROWSER_PATH set but not a valid file");
    }

    // 3. Search PATH
    if let Some(path) = which_agent_browser() {
        ensure_browser_installed(&path);
        return Some(Arc::new(agent_browser::AgentBrowserProvider::new(
            path,
            stream_port,
            headed,
        )));
    }

    // 4. Auto-install via brew (macOS only)
    #[cfg(target_os = "macos")]
    if let Some(path) = brew_install_agent_browser() {
        ensure_browser_installed(&path);
        return Some(Arc::new(agent_browser::AgentBrowserProvider::new(
            path,
            stream_port,
            headed,
        )));
    }

    None
}

/// Find `agent-browser` on PATH.
fn which_agent_browser() -> Option<PathBuf> {
    let output = std::process::Command::new("which")
        .arg("agent-browser")
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let path = String::from_utf8_lossy(&output.stdout).trim().to_string();
    if path.is_empty() {
        return None;
    }
    Some(PathBuf::from(path))
}

/// Install agent-browser via Homebrew. Returns the binary path on success.
#[cfg(target_os = "macos")]
fn brew_install_agent_browser() -> Option<PathBuf> {
    // Check if brew is available
    if std::process::Command::new("brew")
        .arg("--version")
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .is_err()
    {
        tracing::debug!("brew not found — skipping agent-browser auto-install");
        return None;
    }

    tracing::info!("agent-browser not found — installing via brew...");
    let status = std::process::Command::new("brew")
        .args(["install", "agent-browser"])
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::piped())
        .status();

    match status {
        Ok(s) if s.success() => {
            tracing::info!("agent-browser installed via brew");
            which_agent_browser()
        }
        Ok(s) => {
            tracing::warn!(exit_code = s.code(), "brew install agent-browser failed");
            None
        }
        Err(e) => {
            tracing::warn!(error = %e, "brew install agent-browser failed to run");
            None
        }
    }
}

/// Run `agent-browser install` to ensure Chrome for Testing is downloaded.
/// Idempotent — exits quickly if already installed.
fn ensure_browser_installed(binary: &PathBuf) {
    tracing::debug!("ensuring Chrome for Testing is installed...");
    match std::process::Command::new(binary)
        .arg("install")
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::piped())
        .status()
    {
        Ok(s) if s.success() => {
            tracing::debug!("Chrome for Testing ready");
        }
        Ok(s) => {
            tracing::warn!(
                exit_code = s.code(),
                "agent-browser install exited non-zero (browser may not work)"
            );
        }
        Err(e) => {
            tracing::warn!(error = %e, "agent-browser install failed to run");
        }
    }
}
