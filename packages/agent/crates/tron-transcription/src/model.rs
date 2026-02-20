//! Model file management — download from `HuggingFace` and path resolution.

use std::path::{Path, PathBuf};

#[cfg(feature = "ort")]
use crate::types::{ResultExt, TranscriptionError};
#[cfg(feature = "ort")]
use tracing::{debug, info, warn};

/// `HuggingFace` repository for the ONNX parakeet model.
#[cfg(feature = "ort")]
const HF_REPO: &str = "istupakov/parakeet-tdt-0.6b-v3-onnx";

/// Typed paths for the 5 required model files.
///
/// Replaces the previous `HashMap<String, PathBuf>` approach — all fields are
/// known at compile time so there's no need for dynamic lookup.
pub struct ModelPaths {
    /// Mel-spectrogram preprocessor (`nemo128.onnx`).
    pub preprocessor: PathBuf,
    /// Encoder model (`encoder-model.onnx`).
    pub encoder: PathBuf,
    /// Encoder external data (`encoder-model.onnx.data`).
    pub encoder_data: PathBuf,
    /// Decoder + joint network (`decoder_joint-model.onnx`).
    pub decoder_joint: PathBuf,
    /// Token vocabulary (`vocab.txt`).
    pub vocab: PathBuf,
}

impl ModelPaths {
    /// All required model filenames.
    pub const NAMES: &[&str] = &[
        "nemo128.onnx",
        "encoder-model.onnx",
        "encoder-model.onnx.data",
        "decoder_joint-model.onnx",
        "vocab.txt",
    ];

    /// Construct paths for all model files under `dir`.
    pub fn from_dir(dir: impl AsRef<Path>) -> Self {
        let dir = dir.as_ref();
        Self {
            preprocessor: dir.join("nemo128.onnx"),
            encoder: dir.join("encoder-model.onnx"),
            encoder_data: dir.join("encoder-model.onnx.data"),
            decoder_joint: dir.join("decoder_joint-model.onnx"),
            vocab: dir.join("vocab.txt"),
        }
    }

    /// Check if all 5 required files exist.
    pub fn all_exist(&self) -> bool {
        self.preprocessor.exists()
            && self.encoder.exists()
            && self.encoder_data.exists()
            && self.decoder_joint.exists()
            && self.vocab.exists()
    }
}

/// Default model cache directory under ~/.tron/mods/transcribe/onnx/.
pub fn default_model_dir() -> PathBuf {
    let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".into());
    PathBuf::from(format!("{home}/.tron/mods/transcribe/onnx"))
}

/// Check if all required model files exist locally.
pub fn is_model_cached(model_dir: impl AsRef<Path>) -> bool {
    ModelPaths::from_dir(model_dir).all_exist()
}

/// Download model files from `HuggingFace` if not already cached.
///
/// Uses `hf-hub` to download from the `istupakov/parakeet-tdt-0.6b-v3-onnx` repo.
/// Files are stored in `HuggingFace`'s cache, then symlinked/copied to `model_dir`.
#[cfg(feature = "ort")]
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
        .model("task join")?
}

#[cfg(feature = "ort")]
fn download_model_files(model_dir: &Path) -> Result<(), TranscriptionError> {
    let api = hf_hub::api::sync::Api::new().model("HF API init")?;
    let repo = api.model(HF_REPO.to_string());

    for &filename in ModelPaths::NAMES {
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
                    let _ = std::fs::copy(&cached_path, &target)
                        .model(&format!("copy {filename}"))?;
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
#[cfg(feature = "ort")]
pub fn load_vocab(vocab_path: &Path) -> Result<Vec<String>, TranscriptionError> {
    let content = std::fs::read_to_string(vocab_path).model("read vocab.txt")?;
    Ok(content.lines().map(String::from).collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn model_paths_from_dir_constructs_all_paths() {
        let paths = ModelPaths::from_dir("/tmp/test");
        assert_eq!(paths.preprocessor, PathBuf::from("/tmp/test/nemo128.onnx"));
        assert_eq!(
            paths.encoder,
            PathBuf::from("/tmp/test/encoder-model.onnx")
        );
        assert_eq!(
            paths.encoder_data,
            PathBuf::from("/tmp/test/encoder-model.onnx.data")
        );
        assert_eq!(
            paths.decoder_joint,
            PathBuf::from("/tmp/test/decoder_joint-model.onnx")
        );
        assert_eq!(paths.vocab, PathBuf::from("/tmp/test/vocab.txt"));
    }

    #[test]
    fn model_paths_all_exist_empty_dir() {
        let tmp = tempfile::tempdir().unwrap();
        let paths = ModelPaths::from_dir(tmp.path());
        assert!(!paths.all_exist());
    }

    #[test]
    fn model_paths_all_exist_partial() {
        let tmp = tempfile::tempdir().unwrap();
        std::fs::write(tmp.path().join("nemo128.onnx"), b"").unwrap();
        std::fs::write(tmp.path().join("encoder-model.onnx"), b"").unwrap();
        let paths = ModelPaths::from_dir(tmp.path());
        assert!(!paths.all_exist());
    }

    #[test]
    fn model_paths_all_exist_complete() {
        let tmp = tempfile::tempdir().unwrap();
        for name in ModelPaths::NAMES {
            std::fs::write(tmp.path().join(name), b"").unwrap();
        }
        let paths = ModelPaths::from_dir(tmp.path());
        assert!(paths.all_exist());
    }

    #[test]
    fn model_paths_names_matches_all_required_files() {
        assert_eq!(ModelPaths::NAMES.len(), 5);
        assert!(ModelPaths::NAMES.contains(&"nemo128.onnx"));
        assert!(ModelPaths::NAMES.contains(&"encoder-model.onnx"));
        assert!(ModelPaths::NAMES.contains(&"encoder-model.onnx.data"));
        assert!(ModelPaths::NAMES.contains(&"decoder_joint-model.onnx"));
        assert!(ModelPaths::NAMES.contains(&"vocab.txt"));
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
}
