//! Offline embedding provider for capability search.
//!
//! The capability registry owns search policy and index persistence, while this
//! module owns the local embedding model boundary. Production builds embed the
//! first-party ONNX/tokenizer asset bytes in the agent binary so semantic search
//! never depends on runtime downloads or mutable files under `~/.tron`.

use std::sync::Arc;

pub(crate) trait EmbeddingProvider: Send + Sync {
    fn model_id(&self) -> &'static str;
    fn dimensions(&self) -> usize;
    fn embed(&self, texts: &[String]) -> Result<Vec<Vec<f32>>, String>;
}

pub(crate) fn default_embedding_provider() -> Arc<dyn EmbeddingProvider> {
    #[cfg(test)]
    {
        Arc::new(HashEmbeddingProvider::new(64))
    }
    #[cfg(not(test))]
    {
        Arc::new(BundledFastEmbedProvider::new())
    }
}

#[cfg(test)]
pub(crate) struct HashEmbeddingProvider {
    dimensions: usize,
}

#[cfg(test)]
impl HashEmbeddingProvider {
    pub(crate) fn new(dimensions: usize) -> Self {
        Self { dimensions }
    }
}

#[cfg(test)]
impl EmbeddingProvider for HashEmbeddingProvider {
    fn model_id(&self) -> &'static str {
        "test:hash"
    }

    fn dimensions(&self) -> usize {
        self.dimensions
    }

    fn embed(&self, texts: &[String]) -> Result<Vec<Vec<f32>>, String> {
        Ok(texts
            .iter()
            .map(|text| hash_embedding(text, self.dimensions))
            .collect())
    }
}

#[cfg(test)]
fn hash_embedding(text: &str, dims: usize) -> Vec<f32> {
    use sha2::{Digest, Sha256};

    let mut out = vec![0.0; dims];
    for token in text
        .split(|c: char| !c.is_ascii_alphanumeric() && c != '_' && c != ':')
        .filter(|token| !token.is_empty())
        .map(|token| token.to_ascii_lowercase())
    {
        let mut hasher = Sha256::new();
        hasher.update(token.as_bytes());
        let digest = hasher.finalize();
        let idx = usize::from(digest[0]) % dims;
        out[idx] += 1.0;
    }
    out
}

#[cfg(not(test))]
pub(crate) struct BundledFastEmbedProvider {
    model: std::sync::Mutex<Option<fastembed::TextEmbedding>>,
}

#[cfg(not(test))]
impl BundledFastEmbedProvider {
    const MODEL_ID: &'static str =
        "fastembed:Qdrant/all-MiniLM-L6-v2-onnx@5f1b8cd78bc4fb444dd171e59b18f3a3af89a079";
    const DIMENSIONS: usize = 384;

    pub(crate) fn new() -> Self {
        Self {
            model: std::sync::Mutex::new(None),
        }
    }

    fn load_model(&self) -> Result<fastembed::TextEmbedding, String> {
        let onnx_file = embedded_asset(
            "model.onnx",
            include_bytes!(
                "../../../assets/capability-search/embeddings/all-MiniLM-L6-v2/model.onnx"
            ),
            include_str!(
                "../../../assets/capability-search/embeddings/all-MiniLM-L6-v2/model.sha256"
            ),
        )?;
        let tokenizer_files = fastembed::TokenizerFiles {
            tokenizer_file: embedded_asset(
                "tokenizer.json",
                include_bytes!(
                    "../../../assets/capability-search/embeddings/all-MiniLM-L6-v2/tokenizer.json"
                ),
                "da0e79933b9ed51798a3ae27893d3c5fa4a201126cef75586296df9b4d2c62a0",
            )?,
            config_file: embedded_asset(
                "config.json",
                include_bytes!(
                    "../../../assets/capability-search/embeddings/all-MiniLM-L6-v2/config.json"
                ),
                "1b4d8e2a3988377ed8b519a31d8d31025a25f1c5f8606998e8014111438efcd7",
            )?,
            special_tokens_map_file: embedded_asset(
                "special_tokens_map.json",
                include_bytes!(
                    "../../../assets/capability-search/embeddings/all-MiniLM-L6-v2/special_tokens_map.json"
                ),
                "5d5b662e421ea9fac075174bb0688ee0d9431699900b90662acd44b2a350503a",
            )?,
            tokenizer_config_file: embedded_asset(
                "tokenizer_config.json",
                include_bytes!(
                    "../../../assets/capability-search/embeddings/all-MiniLM-L6-v2/tokenizer_config.json"
                ),
                "bd2e06a5b20fd1b13ca988bedc8763d332d242381b4fbc98f8fead4524158f79",
            )?,
        };
        let model = fastembed::UserDefinedEmbeddingModel::new(onnx_file, tokenizer_files)
            .with_pooling(fastembed::Pooling::Mean);
        fastembed::TextEmbedding::try_new_from_user_defined(
            model,
            fastembed::InitOptionsUserDefined::new(),
        )
        .map_err(|error| format!("load embedded fastembed model: {error}"))
    }
}

#[cfg(not(test))]
impl EmbeddingProvider for BundledFastEmbedProvider {
    fn model_id(&self) -> &'static str {
        Self::MODEL_ID
    }

    fn dimensions(&self) -> usize {
        Self::DIMENSIONS
    }

    fn embed(&self, texts: &[String]) -> Result<Vec<Vec<f32>>, String> {
        let mut guard = self
            .model
            .lock()
            .map_err(|_| "fastembed model mutex poisoned".to_owned())?;
        if guard.is_none() {
            *guard = Some(self.load_model()?);
        }
        let model = guard
            .as_mut()
            .ok_or_else(|| "embedded fastembed model unavailable".to_owned())?;
        model
            .embed(texts, None)
            .map_err(|error| format!("fastembed failed: {error}"))
    }
}

#[cfg(not(test))]
fn embedded_asset(
    name: &str,
    bytes: &'static [u8],
    expected_sha256: &str,
) -> Result<Vec<u8>, String> {
    let expected = expected_sha256.trim();
    let actual = sha256_hex(bytes);
    if actual != expected {
        return Err(format!(
            "embedded capability embedding asset {name} digest mismatch: expected {expected}, got {actual}"
        ));
    }
    Ok(bytes.to_vec())
}

#[cfg(not(test))]
fn sha256_hex(bytes: &[u8]) -> String {
    use sha2::{Digest, Sha256};

    let mut hasher = Sha256::new();
    hasher.update(bytes);
    let digest = hasher.finalize();
    digest.iter().map(|byte| format!("{byte:02x}")).collect()
}

#[cfg(test)]
mod tests {
    use std::path::PathBuf;

    fn asset_dir() -> PathBuf {
        PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("assets")
            .join("capability-search")
            .join("embeddings")
            .join("all-MiniLM-L6-v2")
    }

    fn read_asset(name: &str, expected_sha256: &str) -> Vec<u8> {
        let bytes = std::fs::read(asset_dir().join(name)).expect("capability embedding asset");
        assert_eq!(test_sha256_hex(&bytes), expected_sha256.trim(), "{name}");
        bytes
    }

    fn test_sha256_hex(bytes: &[u8]) -> String {
        use sha2::{Digest, Sha256};

        let mut hasher = Sha256::new();
        hasher.update(bytes);
        let digest = hasher.finalize();
        digest.iter().map(|byte| format!("{byte:02x}")).collect()
    }

    #[test]
    fn repo_fastembed_assets_load_and_embed_without_network() {
        let model_sha =
            std::fs::read_to_string(asset_dir().join("model.sha256")).expect("model sha");
        let model = fastembed::UserDefinedEmbeddingModel::new(
            read_asset("model.onnx", &model_sha),
            fastembed::TokenizerFiles {
                tokenizer_file: read_asset(
                    "tokenizer.json",
                    "da0e79933b9ed51798a3ae27893d3c5fa4a201126cef75586296df9b4d2c62a0",
                ),
                config_file: read_asset(
                    "config.json",
                    "1b4d8e2a3988377ed8b519a31d8d31025a25f1c5f8606998e8014111438efcd7",
                ),
                special_tokens_map_file: read_asset(
                    "special_tokens_map.json",
                    "5d5b662e421ea9fac075174bb0688ee0d9431699900b90662acd44b2a350503a",
                ),
                tokenizer_config_file: read_asset(
                    "tokenizer_config.json",
                    "bd2e06a5b20fd1b13ca988bedc8763d332d242381b4fbc98f8fead4524158f79",
                ),
            },
        )
        .with_pooling(fastembed::Pooling::Mean);
        let mut embedding =
            fastembed::TextEmbedding::try_new_from_user_defined(model, Default::default())
                .expect("load repo-owned capability embedding model");
        let vectors = embedding
            .embed(vec!["read a file from the workspace"], None)
            .expect("embed capability search text");
        assert_eq!(vectors.len(), 1);
        assert_eq!(vectors[0].len(), 384);
        assert!(vectors[0].iter().any(|value| *value != 0.0));
    }
}
