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

#[cfg(test)]
pub(crate) use crate::domains::model::providers::shared::provider::ReasoningEffort;
pub(crate) use config::{
    ApiEndpoint, OpenAIApiSettings, OpenAIAuth, OpenAIConfig, TOOL_RESULT_MAX_LENGTH,
    api_endpoint_for_auth_path,
};
#[cfg(test)]
pub(crate) use config::{DEFAULT_BASE_URL, DEFAULT_MODEL, DEFAULT_PLATFORM_BASE_URL};
pub(crate) use models::{
    OpenAIModelProfile, all_openai_model_ids, all_openai_models_api_json_for_auth_path,
    get_openai_model, get_openai_model_profile, openai_model_available_for_auth_path,
    openai_request_model_id,
};
#[cfg(test)]
pub(crate) use models::{all_openai_models_api_json, canonical_openai_model_id};
pub(crate) use responses::{
    MessageContent, OutputItemType, ReasoningConfig, ResponseTextConfig, ResponsesInputItem,
    ResponsesOutputItem, ResponsesRequest, ResponsesResponse, ResponsesSseEvent,
    ResponsesToolEntry, SseEventType,
};
#[cfg(test)]
pub(crate) use responses::{OutputContent, ResponsesUsage};
