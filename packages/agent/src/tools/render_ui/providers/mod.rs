//! Render UI provider discovery.

use std::path::PathBuf;
use std::sync::Arc;

use super::provider::RenderUIProvider;

pub mod json_render;
pub mod lazy;
pub mod stub;

/// Discover the best available render UI provider for the given name.
///
/// Defaults to `"json-render"` when `provider_name` is `None`.
pub fn find_render_ui_provider(
    provider_name: Option<&str>,
    executable_path: Option<&str>,
) -> Option<Arc<dyn RenderUIProvider>> {
    match provider_name.unwrap_or("json-render") {
        "json-render" => find_json_render(executable_path),
        unknown => {
            tracing::warn!(
                provider = unknown,
                "unknown render UI provider, falling back to json-render"
            );
            find_json_render(executable_path)
        }
    }
}

/// Discover the json-render provider.
///
/// Discovery order:
/// 1. Explicit `executable_path` from settings
/// 2. `JSON_RENDER_SERVER_PATH` environment variable
/// 3. `json-render-server` on PATH
/// 4. Auto-install via `brew install json-render-server` (macOS only)
fn find_json_render(
    executable_path: Option<&str>,
) -> Option<Arc<dyn RenderUIProvider>> {
    // 1. Check explicit executable path from settings
    if let Some(path) = executable_path {
        let p = PathBuf::from(path);
        if p.is_file() {
            tracing::info!(path = %path, "json-render-server found at explicit path");
            return Some(Arc::new(json_render::JsonRenderProvider::new(p)));
        }
        tracing::warn!(path = %path, "json-render-server executable_path set but not a valid file");
    }

    // 2. Check JSON_RENDER_SERVER_PATH env var
    if let Ok(path) = std::env::var("JSON_RENDER_SERVER_PATH") {
        let p = PathBuf::from(&path);
        if p.is_file() {
            tracing::info!(path = %path, "json-render-server found via env var");
            return Some(Arc::new(json_render::JsonRenderProvider::new(p)));
        }
        tracing::warn!(path = %path, "JSON_RENDER_SERVER_PATH set but not a valid file");
    }

    // 3. Search PATH
    if let Some(path) = which_json_render_server() {
        tracing::info!(path = %path.display(), "json-render-server found on PATH");
        return Some(Arc::new(json_render::JsonRenderProvider::new(path)));
    }

    // 4. Auto-install via brew (macOS only)
    #[cfg(target_os = "macos")]
    if let Some(path) = brew_install_json_render_server() {
        tracing::info!(path = %path.display(), "json-render-server installed via brew");
        return Some(Arc::new(json_render::JsonRenderProvider::new(path)));
    }

    None
}

/// Find `json-render-server` on PATH by searching directories directly.
fn which_json_render_server() -> Option<PathBuf> {
    let path_env = std::env::var("PATH").ok()?;
    find_in_path("json-render-server", &path_env)
}

/// Search for a binary name in the given PATH string.
fn find_in_path(name: &str, path_env: &str) -> Option<PathBuf> {
    for dir in std::env::split_paths(path_env) {
        let candidate = dir.join(name);
        if candidate.is_file() {
            return Some(candidate);
        }
    }
    None
}

/// Install json-render-server via Homebrew. Returns the binary path on success.
#[cfg(target_os = "macos")]
fn brew_install_json_render_server() -> Option<PathBuf> {
    if std::process::Command::new("brew")
        .arg("--version")
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .is_err()
    {
        tracing::debug!("brew not found — skipping json-render-server auto-install");
        return None;
    }

    tracing::info!("json-render-server not found — installing via brew...");
    let status = std::process::Command::new("brew")
        .args(["install", "json-render-server"])
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::piped())
        .status();

    match status {
        Ok(s) if s.success() => {
            tracing::info!("json-render-server installed via brew");
            which_json_render_server()
        }
        Ok(s) => {
            tracing::warn!(exit_code = s.code(), "brew install json-render-server failed");
            None
        }
        Err(e) => {
            tracing::warn!(error = %e, "brew install json-render-server failed to run");
            None
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn find_in_path_finds_binary() {
        let dir = tempfile::tempdir().unwrap();
        let binary = dir.path().join("json-render-server");
        std::fs::write(&binary, "#!/bin/sh\n").unwrap();
        let path_str = dir.path().to_str().unwrap();
        assert_eq!(find_in_path("json-render-server", path_str), Some(binary));
    }

    #[test]
    fn find_in_path_returns_none_when_missing() {
        let dir = tempfile::tempdir().unwrap();
        let path_str = dir.path().to_str().unwrap();
        assert!(find_in_path("json-render-server", path_str).is_none());
    }

    #[test]
    fn find_in_path_searches_multiple_dirs() {
        let dir1 = tempfile::tempdir().unwrap();
        let dir2 = tempfile::tempdir().unwrap();
        let binary = dir2.path().join("json-render-server");
        std::fs::write(&binary, "#!/bin/sh\n").unwrap();
        let path_str = format!(
            "{}:{}",
            dir1.path().display(),
            dir2.path().display()
        );
        assert_eq!(find_in_path("json-render-server", &path_str), Some(binary));
    }

    #[test]
    fn find_in_path_skips_directories_with_same_name() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::create_dir(dir.path().join("json-render-server")).unwrap();
        let path_str = dir.path().to_str().unwrap();
        assert!(find_in_path("json-render-server", path_str).is_none());
    }

    #[test]
    fn find_render_ui_provider_returns_none_without_binary() {
        let result = find_render_ui_provider(None, None);
        assert!(result.is_none());
    }

    #[test]
    fn find_render_ui_provider_unknown_falls_back() {
        // Unknown provider name falls back to json-render discovery
        let result = find_render_ui_provider(Some("nonexistent"), None);
        assert!(result.is_none()); // No binary in test env
    }
}
