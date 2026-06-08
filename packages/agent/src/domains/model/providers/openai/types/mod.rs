//! OpenAI provider configuration, model registry, and Responses wire DTOs.
//!
//! The large provider-native surfaces are split by ownership: endpoint/auth
//! config, auth-path-aware model metadata, and Responses API request/SSE DTOs.
//! Code outside the OpenAI provider should consume the canonical provider trait
//! and stream/capability events, not these wire shapes directly.

mod config;
mod models;
mod responses;

#[cfg(test)]
mod tests;

pub use crate::domains::model::providers::shared::provider::ReasoningEffort;
pub use config::{
    ApiEndpoint, DEFAULT_BASE_URL, DEFAULT_MAX_OUTPUT_TOKENS, DEFAULT_MODEL,
    DEFAULT_PLATFORM_BASE_URL, OpenAIApiSettings, OpenAIAuth, OpenAIAuthPath, OpenAIConfig,
    TOOL_RESULT_MAX_LENGTH,
};
pub use models::{
    OPENAI_MODELS, OpenAIModelInfo, OpenAIModelProfile, all_openai_model_ids,
    all_openai_models_api_json, all_openai_models_api_json_for_auth_path,
    canonical_openai_model_id, get_openai_model, get_openai_model_profile,
    openai_model_available_for_auth_path, openai_request_model_id, strip_openai_provider_prefix,
};
pub use responses::{
    MessageContent, OutputContent, OutputItemType, ReasoningConfig, ResponseTextConfig,
    ResponsesInputItem, ResponsesOutputItem, ResponsesRequest, ResponsesResponse,
    ResponsesSseEvent, ResponsesToolEntry, ResponsesUsage, SseEventType,
};
