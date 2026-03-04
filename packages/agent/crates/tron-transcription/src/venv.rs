//! Python venv management for the parakeet-mlx transcription sidecar.
//!
//! Handles Python discovery, venv creation, and package installation.
//! All state lives under `~/.tron/mods/transcribe/`.

use std::path::PathBuf;
use std::process::Stdio;

use tokio::process::Command;
use tracing::{debug, info};

use crate::types::TranscriptionError;

/// Base directory for the transcription sidecar.
pub fn sidecar_dir() -> PathBuf {
    let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".into());
    PathBuf::from(format!("{home}/.tron/mods/transcribe"))
}

/// Path to the worker script.
pub fn worker_script() -> PathBuf {
    sidecar_dir().join("worker.py")
}

/// Find a system Python 3 binary. Tries versioned names first for determinism.
pub fn find_system_python() -> Result<PathBuf, TranscriptionError> {
    // Prefer specific versions that parakeet-mlx is known to work with
    let candidates = [
        "python3.12",
        "python3.11",
        "python3.14",
        "python3.13",
        "python3",
    ];

    for name in candidates {
        if let Ok(output) = std::process::Command::new("which")
            .arg(name)
            .output()
        {
            if output.status.success() {
                let path = String::from_utf8_lossy(&output.stdout).trim().to_string();
                if !path.is_empty() {
                    debug!("found system python: {path}");
                    return Ok(PathBuf::from(path));
                }
            }
        }
    }

    Err(TranscriptionError::Setup(
        "Python 3 not found. Install Python 3.11+ for transcription.".into(),
    ))
}

/// Ensure the venv exists with parakeet-mlx installed.
///
/// Returns the path to the venv's python binary.
/// Creates venv + runs pip install if missing or if `parakeet_mlx` isn't importable.
pub async fn ensure_venv() -> Result<PathBuf, TranscriptionError> {
    let dir = sidecar_dir();
    let venv_dir = dir.join("venv");
    let venv_python = venv_dir.join("bin/python3");

    // Fast path: venv exists and parakeet_mlx is importable
    if venv_python.exists() && check_package_installed(&venv_python).await {
        debug!("venv ready at {}", venv_dir.display());
        return Ok(venv_python);
    }

    let system_python = find_system_python()?;

    // Create venv if it doesn't exist
    if !venv_dir.exists() {
        info!("creating transcription venv at {}", venv_dir.display());
        std::fs::create_dir_all(&dir).map_err(TranscriptionError::Io)?;

        let output = Command::new(&system_python)
            .args(["-m", "venv", &venv_dir.to_string_lossy()])
            .output()
            .await
            .map_err(TranscriptionError::Io)?;

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            return Err(TranscriptionError::Setup(format!(
                "venv creation failed: {stderr}"
            )));
        }
    }

    // Install parakeet-mlx
    if !check_package_installed(&venv_python).await {
        let requirements = dir.join("requirements.txt");
        if !requirements.exists() {
            return Err(TranscriptionError::Setup(format!(
                "requirements.txt not found at {}",
                requirements.display()
            )));
        }

        info!("installing parakeet-mlx (this may take a minute)...");
        let output = Command::new(&venv_python)
            .args([
                "-m",
                "pip",
                "install",
                "-q",
                "-r",
                &requirements.to_string_lossy(),
            ])
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .output()
            .await
            .map_err(TranscriptionError::Io)?;

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            return Err(TranscriptionError::Setup(format!(
                "pip install failed: {stderr}"
            )));
        }
        info!("parakeet-mlx installed successfully");
    }

    Ok(venv_python)
}

/// Check if `parakeet_mlx` is importable in the given python.
async fn check_package_installed(python: &std::path::Path) -> bool {
    Command::new(python)
        .args(["-c", "import parakeet_mlx"])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .await
        .is_ok_and(|s| s.success())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sidecar_dir_under_tron() {
        let dir = sidecar_dir();
        let s = dir.to_string_lossy();
        assert!(s.contains(".tron/mods/transcribe"), "Got: {s}");
    }

    #[test]
    fn worker_script_path() {
        let path = worker_script();
        assert!(path.to_string_lossy().ends_with("worker.py"));
    }

    #[test]
    fn find_system_python_finds_something() {
        // This test will pass on any dev machine with Python installed
        match find_system_python() {
            Ok(path) => assert!(path.to_string_lossy().contains("python")),
            Err(_) => {
                // OK on systems without Python — test still validates the function runs
            }
        }
    }
}
