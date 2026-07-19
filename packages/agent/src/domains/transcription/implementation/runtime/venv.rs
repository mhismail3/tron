//! Python venv management for the Parakeet MLX transcription sidecar.

use std::path::PathBuf;
use std::process::Stdio;

use tokio::process::Command;
use tracing::{debug, info};

use crate::domains::transcription::TranscriptionError;
use crate::shared::foundation::paths;

const PARAKEET_MLX_VERSION: &str = "0.5.2";

/// Locate a non-system Python suitable for creating the transcription venv.
pub fn find_system_python() -> Result<PathBuf, TranscriptionError> {
    let homebrew_prefix = "/opt/homebrew/bin";
    let versioned = ["python3.12", "python3.11", "python3.13", "python3.14"];

    for name in versioned {
        let abs = PathBuf::from(format!("{homebrew_prefix}/{name}"));
        if abs.exists() {
            debug!("found homebrew python: {}", abs.display());
            return Ok(abs);
        }
    }

    let candidates = [
        "python3.12",
        "python3.11",
        "python3.14",
        "python3.13",
        "python3",
    ];

    for name in candidates {
        if let Ok(output) = std::process::Command::new("which").arg(name).output()
            && output.status.success()
        {
            let path = String::from_utf8_lossy(&output.stdout).trim().to_string();
            if !path.is_empty() {
                let p = PathBuf::from(&path);
                if p.starts_with("/usr/bin") {
                    debug!("skipping system python without pip: {path}");
                    continue;
                }
                debug!("found system python: {path}");
                return Ok(p);
            }
        }
    }

    Err(TranscriptionError::Setup(
        "Python 3.10+ not found. Install via: brew install python".into(),
    ))
}

/// Install bundled sidecar assets and return a Python with `parakeet-mlx`.
pub async fn ensure_venv() -> Result<PathBuf, TranscriptionError> {
    install_bundled_sidecar_assets()?;

    let venv_dir = paths::transcription_venv_dir();
    let venv_python = venv_dir.join("bin/python3");

    if venv_python.exists() && check_package_installed(&venv_python).await {
        debug!("transcription venv ready at {}", venv_dir.display());
        return Ok(venv_python);
    }

    let system_python = find_system_python()?;
    let requirements = paths::transcription_requirements_path();
    if !requirements.exists() {
        return Err(TranscriptionError::Setup(format!(
            "requirements.txt not found at {}",
            requirements.display()
        )));
    }

    // INVARIANT: The venv is disposable runtime state while the model cache is
    // a sibling directory. Rebuilding an unhealthy venv must never delete or
    // redownload the independently owned model cache.
    info!(
        python = %system_python.display(),
        venv = %venv_dir.display(),
        "rebuilding unhealthy transcription venv"
    );
    std::fs::create_dir_all(paths::transcription_dir()).map_err(TranscriptionError::Io)?;
    let output = Command::new(&system_python)
        .args(["-m", "venv", "--clear", &venv_dir.to_string_lossy()])
        .output()
        .await
        .map_err(|error| {
            TranscriptionError::Setup(format!(
                "failed to launch {} to rebuild the transcription venv: {error}",
                system_python.display()
            ))
        })?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(TranscriptionError::Setup(format!(
            "venv rebuild failed with {}: {stderr}",
            system_python.display()
        )));
    }

    info!("installing pinned parakeet-mlx transcription dependencies");
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
        .map_err(|error| {
            TranscriptionError::Setup(format!(
                "failed to launch the rebuilt transcription venv: {error}"
            ))
        })?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(TranscriptionError::Setup(format!(
            "pip install failed: {stderr}"
        )));
    }

    if !check_package_installed(&venv_python).await {
        return Err(TranscriptionError::Setup(format!(
            "rebuilt transcription venv failed the parakeet-mlx {PARAKEET_MLX_VERSION} import health check"
        )));
    }

    Ok(venv_python)
}

fn install_bundled_sidecar_assets() -> Result<(), TranscriptionError> {
    std::fs::create_dir_all(paths::transcription_dir()).map_err(TranscriptionError::Io)?;
    std::fs::write(
        paths::transcription_worker_script(),
        include_str!("../sidecar/worker.py"),
    )
    .map_err(TranscriptionError::Io)?;
    std::fs::write(
        paths::transcription_requirements_path(),
        include_str!("../sidecar/requirements.txt"),
    )
    .map_err(TranscriptionError::Io)?;
    Ok(())
}

async fn check_package_installed(python: &std::path::Path) -> bool {
    Command::new(python)
        .args([
            "-c",
            "import importlib.metadata, parakeet_mlx, sys; sys.exit(0 if importlib.metadata.version('parakeet-mlx') == sys.argv[1] else 1)",
            PARAKEET_MLX_VERSION,
        ])
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
    fn bundled_requirement_pins_the_health_checked_version() {
        assert_eq!(
            include_str!("../sidecar/requirements.txt").trim(),
            format!("parakeet-mlx=={PARAKEET_MLX_VERSION}")
        );
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn dangling_venv_python_fails_health_check_instead_of_appearing_ready() {
        use std::os::unix::fs::symlink;

        let temporary = tempfile::tempdir().expect("temporary directory");
        let dangling_python = temporary.path().join("python3");
        symlink(
            temporary.path().join("removed-homebrew-python"),
            &dangling_python,
        )
        .expect("dangling interpreter symlink");

        assert!(!check_package_installed(&dangling_python).await);
    }
}
