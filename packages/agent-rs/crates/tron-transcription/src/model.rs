//! Model file management — download from `HuggingFace` and path resolution.

use std::collections::HashMap;
use std::path::{Path, PathBuf};

use tracing::{debug, info, warn};

use crate::types::TranscriptionError;

/// `HuggingFace` repository for the ONNX parakeet model.
const HF_REPO: &str = "istupakov/parakeet-tdt-0.6b-v3-onnx";

/// Required model files and their purposes.
const MODEL_FILES: &[&str] = &[
    "nemo128.onnx",
    "encoder-model.onnx",
    "encoder-model.onnx.data",
    "decoder_joint-model.onnx",
    "vocab.txt",
];

/// Default model cache directory under ~/.tron/mods/transcribe/onnx/.
pub fn default_model_dir() -> PathBuf {
    let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".into());
    PathBuf::from(format!("{home}/.tron/mods/transcribe/onnx"))
}

/// Returns a map of filename → full path for all required model files.
pub fn model_files(model_dir: impl AsRef<Path>) -> HashMap<String, PathBuf> {
    let dir = model_dir.as_ref();
    MODEL_FILES
        .iter()
        .map(|&name| (name.to_string(), dir.join(name)))
        .collect()
}

/// Check if all required model files exist locally.
pub fn is_model_cached(model_dir: impl AsRef<Path>) -> bool {
    let files = model_files(&model_dir);
    files.values().all(|p| p.exists())
}

/// Download model files from `HuggingFace` if not already cached.
///
/// Uses `hf-hub` to download from the `istupakov/parakeet-tdt-0.6b-v3-onnx` repo.
/// Files are stored in `HuggingFace`'s cache, then symlinked/copied to `model_dir`.
pub async fn ensure_model(model_dir: impl AsRef<Path>) -> Result<(), TranscriptionError> {
    let model_dir = model_dir.as_ref().to_path_buf();

    if is_model_cached(&model_dir) {
        debug!("model files already cached at {}", model_dir.display());
        return Ok(());
    }

    info!("downloading parakeet-tdt model from HuggingFace...");
    std::fs::create_dir_all(&model_dir).map_err(TranscriptionError::Io)?;

    // Run download on blocking thread (hf-hub uses sync HTTP)
    let dir = model_dir.clone();
    tokio::task::spawn_blocking(move || download_model_files(&dir))
        .await
        .map_err(|e| TranscriptionError::ModelNotAvailable(format!("task join error: {e}")))?
}

fn download_model_files(model_dir: &Path) -> Result<(), TranscriptionError> {
    let api = hf_hub::api::sync::Api::new()
        .map_err(|e| TranscriptionError::ModelNotAvailable(format!("HF API init: {e}")))?;
    let repo = api.model(HF_REPO.to_string());

    for &filename in MODEL_FILES {
        let target = model_dir.join(filename);
        if target.exists() {
            debug!("skipping {filename} (already exists)");
            continue;
        }

        info!("downloading {filename}...");
        match repo.get(filename) {
            Ok(cached_path) => {
                // hf-hub caches to its own dir; copy to our model dir
                if cached_path != target {
                    let _ = std::fs::copy(&cached_path, &target).map_err(|e| {
                        TranscriptionError::ModelNotAvailable(format!(
                            "failed to copy {filename}: {e}"
                        ))
                    })?;
                }
                debug!("downloaded {filename}");
            }
            Err(e) => {
                warn!("failed to download {filename}: {e}");
                return Err(TranscriptionError::ModelNotAvailable(format!(
                    "download failed for {filename}: {e}"
                )));
            }
        }
    }

    info!("all model files ready at {}", model_dir.display());
    Ok(())
}

/// Load vocabulary from vocab.txt (one token per line).
pub fn load_vocab(vocab_path: &Path) -> Result<Vec<String>, TranscriptionError> {
    let content = std::fs::read_to_string(vocab_path).map_err(|e| {
        TranscriptionError::ModelNotAvailable(format!("failed to read vocab.txt: {e}"))
    })?;
    Ok(content.lines().map(String::from).collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn model_dir_structure() {
        let expected = [
            "nemo128.onnx",
            "encoder-model.onnx",
            "decoder_joint-model.onnx",
            "vocab.txt",
        ];
        let files = model_files(PathBuf::from("/tmp/test"));
        for name in &expected {
            assert!(files.contains_key(*name), "Missing model file: {name}");
        }
    }

    #[test]
    fn default_model_dir_under_tron() {
        let dir = default_model_dir();
        let s = dir.to_string_lossy();
        assert!(s.contains(".tron/mods/transcribe/onnx"), "Got: {s}");
    }

    #[test]
    fn is_model_cached_returns_false_for_empty_dir() {
        let tmp = tempfile::tempdir().unwrap();
        assert!(!is_model_cached(tmp.path()));
    }

    #[test]
    fn model_files_returns_all_required() {
        let files = model_files("/tmp/test");
        assert_eq!(files.len(), MODEL_FILES.len());
    }
}
