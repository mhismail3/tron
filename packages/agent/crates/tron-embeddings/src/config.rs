//! Embedding configuration.

use serde::{Deserialize, Serialize};
use tron_settings::types::MemoryEmbeddingSettings;

/// Full embedding dimensions before Matryoshka truncation.
const FULL_DIMENSIONS: usize = 1024;

/// Configuration for the embedding system.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct EmbeddingConfig {
    /// Whether embeddings are enabled.
    pub enabled: bool,
    /// ONNX model identifier.
    pub model: String,
    /// Quantization dtype.
    pub dtype: String,
    /// Output dimensions (after Matryoshka truncation).
    pub dimensions: usize,
    /// Full model output dimensions (before truncation).
    pub full_dimensions: usize,
    /// Local model cache directory (may contain `~`).
    pub cache_dir: String,
    /// Maximum tokens for workspace lesson injection.
    pub max_workspace_lessons_tokens: usize,
    /// Maximum tokens for cross-project memory injection.
    pub max_cross_project_tokens: usize,
    /// Top-K results for cross-project search.
    pub cross_project_top_k: usize,
}

impl Default for EmbeddingConfig {
    fn default() -> Self {
        Self::from_settings(&MemoryEmbeddingSettings::default())
    }
}

impl EmbeddingConfig {
    /// Create config from settings.
    pub fn from_settings(s: &MemoryEmbeddingSettings) -> Self {
        Self {
            enabled: s.enabled,
            model: s.model.clone(),
            dtype: s.dtype.clone(),
            dimensions: s.dimensions,
            full_dimensions: FULL_DIMENSIONS,
            cache_dir: s.cache_dir.clone(),
            max_workspace_lessons_tokens: s.max_workspace_lessons_tokens,
            max_cross_project_tokens: s.max_cross_project_tokens,
            cross_project_top_k: s.cross_project_top_k,
        }
    }

    /// Resolve the cache directory, expanding `~/` to the home directory.
    pub fn resolved_cache_dir(&self) -> String {
        if self.cache_dir.starts_with("~/") {
            if let Ok(home) = std::env::var("HOME") {
                return format!("{}{}", home, &self.cache_dir[1..]);
            }
        }
        self.cache_dir.clone()
    }

    /// Create a disabled config (for testing or when embeddings are off).
    pub fn disabled() -> Self {
        Self {
            enabled: false,
            ..Self::default()
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_config_matches_typescript() {
        let config = EmbeddingConfig::default();
        assert!(config.enabled);
        assert_eq!(config.model, "onnx-community/Qwen3-Embedding-0.6B-ONNX");
        assert_eq!(config.dtype, "q4");
        assert_eq!(config.dimensions, 512);
        assert_eq!(config.full_dimensions, 1024);
        assert_eq!(config.cache_dir, "~/.tron/mods/models");
        assert_eq!(config.max_workspace_lessons_tokens, 2000);
        assert_eq!(config.max_cross_project_tokens, 1000);
        assert_eq!(config.cross_project_top_k, 5);
    }

    #[test]
    fn from_settings_copies_all_fields() {
        let settings = MemoryEmbeddingSettings {
            enabled: false,
            model: "custom-model".to_string(),
            dtype: "q8".to_string(),
            dimensions: 256,
            cache_dir: "/tmp/models".to_string(),
            max_workspace_lessons_tokens: 500,
            max_cross_project_tokens: 250,
            cross_project_top_k: 3,
        };
        let config = EmbeddingConfig::from_settings(&settings);
        assert!(!config.enabled);
        assert_eq!(config.model, "custom-model");
        assert_eq!(config.dtype, "q8");
        assert_eq!(config.dimensions, 256);
        assert_eq!(config.full_dimensions, 1024);
        assert_eq!(config.cache_dir, "/tmp/models");
        assert_eq!(config.max_workspace_lessons_tokens, 500);
        assert_eq!(config.max_cross_project_tokens, 250);
        assert_eq!(config.cross_project_top_k, 3);
    }

    #[test]
    fn resolved_cache_dir_expands_tilde() {
        let config = EmbeddingConfig::default();
        let resolved = config.resolved_cache_dir();
        assert!(
            !resolved.starts_with('~'),
            "tilde should be expanded: {resolved}"
        );
        assert!(resolved.ends_with("/.tron/mods/models"));
    }

    #[test]
    fn resolved_cache_dir_absolute_passthrough() {
        let config = EmbeddingConfig {
            cache_dir: "/absolute/path".to_string(),
            ..EmbeddingConfig::default()
        };
        assert_eq!(config.resolved_cache_dir(), "/absolute/path");
    }

    #[test]
    fn serde_roundtrip() {
        let config = EmbeddingConfig::default();
        let json = serde_json::to_string(&config).unwrap();
        let parsed: EmbeddingConfig = serde_json::from_str(&json).unwrap();
        assert_eq!(config.model, parsed.model);
        assert_eq!(config.dimensions, parsed.dimensions);
        assert_eq!(config.full_dimensions, parsed.full_dimensions);
    }

    #[test]
    fn serde_camel_case() {
        let config = EmbeddingConfig::default();
        let value: serde_json::Value = serde_json::to_value(&config).unwrap();
        assert!(value.get("cacheDir").is_some());
        assert!(value.get("fullDimensions").is_some());
        assert!(value.get("crossProjectTopK").is_some());
        assert!(value.get("cache_dir").is_none());
    }

    #[test]
    fn partial_json_with_defaults() {
        let json = r#"{"enabled": false}"#;
        let config: EmbeddingConfig = serde_json::from_str(json).unwrap();
        assert!(!config.enabled);
        assert_eq!(config.dimensions, 512);
        assert_eq!(config.full_dimensions, 1024);
    }

    #[test]
    fn disabled_config() {
        let config = EmbeddingConfig::disabled();
        assert!(!config.enabled);
        assert_eq!(config.dimensions, 512);
    }
}
