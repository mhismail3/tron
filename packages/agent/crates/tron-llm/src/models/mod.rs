//! # Models
//!
//! Model registry, ID constants, and type definitions for all LLM providers.

pub mod model_ids;
pub mod registry;
pub mod types;

pub use model_ids::*;
pub use registry::{
    all_model_ids, detect_provider_from_model, is_model_supported, model_supports_images,
    strip_provider_prefix,
};
#[allow(deprecated)]
pub use types::{
    ModelCapabilities, ModelCategory, ModelInfo, ModelTier, ProviderType, calculate_cost,
    format_context_window, format_model_pricing,
};
