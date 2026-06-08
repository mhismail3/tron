//! Model presets and server-owned routing presentation.
//!
//! Callers may request an exact model, but retained client shells can use these
//! presets so the server discloses the concrete selected model and any hosted
//! route without client policy logic.

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::domains::model::providers::models::model_ids::{
    CLAUDE_OPUS_4_7, CLAUDE_SONNET_4_6, GEMMA4_26B,
};
use crate::domains::model::providers::models::registry::{
    detect_provider_from_model, strip_provider_prefix,
};
use crate::shared::protocol::messages::Provider;

/// User-facing model presets.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ModelPreset {
    /// Prefer a local model for this flow, using hosted route only when
    /// local execution is unavailable.
    LocalWhenPossible,
    /// Use the profile's normal default model.
    Balanced,
    /// Use the profile's deepest supported hosted model.
    Deep,
}

impl ModelPreset {
    /// Product label shown in chat, Console, and generated UI.
    #[must_use]
    pub const fn label(self) -> &'static str {
        match self {
            Self::LocalWhenPossible => "Local when possible",
            Self::Balanced => "Balanced",
            Self::Deep => "Deep",
        }
    }

    /// Whether this preset is an explicit local-model opt-in.
    #[must_use]
    pub const fn local_opt_in(self) -> bool {
        matches!(self, Self::LocalWhenPossible)
    }
}

/// Local availability observation used by `Local when possible`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LocalModelAvailability {
    /// Whether a preferred local model can be used now.
    pub available: bool,
    /// Concrete local model to select when available.
    pub model: String,
    /// Human-readable reason when unavailable.
    pub unavailable_reason: Option<String>,
}

impl LocalModelAvailability {
    /// Conservative unavailable default. Product callers only get a local model
    /// when they explicitly observed availability for this flow.
    #[must_use]
    pub fn unavailable(reason: impl Into<String>) -> Self {
        Self {
            available: false,
            model: preferred_local_model(),
            unavailable_reason: Some(reason.into()),
        }
    }
}

/// Inputs that constrain model preset routing for one flow.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ModelRoutingPolicy {
    /// Profile/session default hosted model.
    pub default_model: String,
    /// Local model observation.
    pub local: LocalModelAvailability,
}

impl ModelRoutingPolicy {
    /// Build from the current settings snapshot.
    #[must_use]
    pub fn from_settings(settings: &crate::domains::settings::types::TronSettings) -> Self {
        Self {
            default_model: settings.server.default_model.clone(),
            local: LocalModelAvailability::unavailable("Local model is unavailable for this flow."),
        }
    }

    /// Attach local availability observed at the execution boundary.
    #[must_use]
    pub fn with_local(mut self, local: LocalModelAvailability) -> Self {
        self.local = local;
        self
    }
}

/// Server-owned routing presentation carried by resources and events.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ModelRoutingPresentation {
    /// Requested preset, if this route came from a preset.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub preset: Option<ModelPreset>,
    /// Product label for the preset.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub preset_label: Option<String>,
    /// `pending` before execution, `selected` after the concrete model is known.
    pub selection_status: String,
    /// Whether this flow explicitly opted into local model routing.
    pub local_opt_in: bool,
    /// Concrete selected model after routing.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub selected_model: Option<String>,
    /// Server-derived display label for the concrete model.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub selected_model_label: Option<String>,
    /// `local` or `hosted` after routing.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub model_class: Option<String>,
    /// Whether a hosted route was used for a local opt-in preset.
    pub hosted_route_used: bool,
    /// Product label for hosted-route state.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub hosted_route_label: Option<String>,
    /// Plain reason for the hosted route.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub hosted_route_reason: Option<String>,
}

impl ModelRoutingPresentation {
    /// Pending presentation before route resolution.
    #[must_use]
    pub fn pending(preset: ModelPreset) -> Self {
        Self {
            preset: Some(preset),
            preset_label: Some(preset.label().to_owned()),
            selection_status: "pending".to_owned(),
            local_opt_in: preset.local_opt_in(),
            selected_model: None,
            selected_model_label: None,
            model_class: None,
            hosted_route_used: false,
            hosted_route_label: None,
            hosted_route_reason: None,
        }
    }

    /// Convert to JSON for generated UI/resources.
    #[must_use]
    pub fn to_value(&self) -> Value {
        serde_json::to_value(self).expect("model routing presentation serializes")
    }
}

/// Resolve the route for a model call.
#[must_use]
pub fn resolve_model_route(
    exact_model: Option<&str>,
    preset: Option<ModelPreset>,
    policy: &ModelRoutingPolicy,
    default_model: &str,
) -> ModelRoutingPresentation {
    if let Some(model) = exact_model.filter(|value| !value.trim().is_empty()) {
        return selected_presentation(preset, model, false, None);
    }

    match preset.unwrap_or(ModelPreset::Balanced) {
        ModelPreset::LocalWhenPossible if policy.local.available => selected_presentation(
            Some(ModelPreset::LocalWhenPossible),
            &policy.local.model,
            false,
            None,
        ),
        ModelPreset::LocalWhenPossible => selected_presentation(
            Some(ModelPreset::LocalWhenPossible),
            default_model,
            true,
            Some(
                policy
                    .local
                    .unavailable_reason
                    .clone()
                    .unwrap_or_else(|| "Local model is unavailable for this flow.".to_owned()),
            ),
        ),
        ModelPreset::Balanced => {
            selected_presentation(Some(ModelPreset::Balanced), default_model, false, None)
        }
        ModelPreset::Deep => selected_presentation(
            Some(ModelPreset::Deep),
            preferred_deep_model(default_model),
            false,
            None,
        ),
    }
}

/// Preferred local model id with explicit provider prefix.
#[must_use]
pub fn preferred_local_model() -> String {
    format!("ollama/{GEMMA4_26B}")
}

/// Observe local Ollama availability for preset routing.
pub async fn observe_local_model_availability() -> LocalModelAvailability {
    let models =
        crate::domains::model::providers::ollama::types::all_ollama_models_api_json_with_availability(
            None,
        )
        .await;
    let preferred = [
        GEMMA4_26B,
        crate::domains::model::providers::models::model_ids::GEMMA4_E4B,
    ];
    for id in preferred {
        if models.iter().any(|model| {
            model.get("id").and_then(Value::as_str) == Some(id)
                && model
                    .get("available")
                    .and_then(Value::as_bool)
                    .unwrap_or(false)
        }) {
            return LocalModelAvailability {
                available: true,
                model: format!("ollama/{id}"),
                unavailable_reason: None,
            };
        }
    }
    let reason = models
        .iter()
        .find_map(|model| model.get("unavailableReason").and_then(Value::as_str))
        .unwrap_or("Local model is unavailable for this flow.");
    LocalModelAvailability::unavailable(reason)
}

fn selected_presentation(
    preset: Option<ModelPreset>,
    model: &str,
    hosted_route_used: bool,
    hosted_route_reason: Option<String>,
) -> ModelRoutingPresentation {
    let model_class = if model_is_local(model) {
        "local"
    } else {
        "hosted"
    };
    ModelRoutingPresentation {
        preset,
        preset_label: preset.map(|preset| preset.label().to_owned()),
        selection_status: "selected".to_owned(),
        local_opt_in: preset.is_some_and(ModelPreset::local_opt_in),
        selected_model: Some(model.to_owned()),
        selected_model_label: Some(model_display_name(model)),
        model_class: Some(model_class.to_owned()),
        hosted_route_used,
        hosted_route_label: hosted_route_used.then(|| "Hosted route".to_owned()),
        hosted_route_reason,
    }
}

fn preferred_deep_model(default_model: &str) -> &str {
    if crate::domains::model::providers::models::registry::is_model_supported(CLAUDE_OPUS_4_7) {
        CLAUDE_OPUS_4_7
    } else if crate::domains::model::providers::models::registry::is_model_supported(
        CLAUDE_SONNET_4_6,
    ) {
        CLAUDE_SONNET_4_6
    } else {
        default_model
    }
}

fn model_is_local(model: &str) -> bool {
    detect_provider_from_model(model) == Some(Provider::Ollama)
}

fn model_display_name(model: &str) -> String {
    let bare = strip_provider_prefix(model);
    if let Some(info) = crate::domains::model::providers::anthropic::types::get_claude_model(bare) {
        return info.name.to_owned();
    }
    if let Some(info) = crate::domains::model::providers::openai::types::get_openai_model(bare) {
        return info.name.to_owned();
    }
    if let Some(info) = crate::domains::model::providers::google::types::get_gemini_model(bare) {
        return info.name.to_owned();
    }
    if let Some(info) = crate::domains::model::providers::minimax::types::get_minimax_model(bare) {
        return info.name.to_owned();
    }
    if let Some(info) = crate::domains::model::providers::kimi::types::get_kimi_model(bare) {
        return info.name.to_owned();
    }
    if let Some(info) = crate::domains::model::providers::ollama::types::get_ollama_model(bare) {
        return info.name.to_owned();
    }
    model.to_owned()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn local_when_possible_uses_local_model_when_available() {
        let policy = ModelRoutingPolicy {
            default_model: CLAUDE_SONNET_4_6.to_owned(),
            local: LocalModelAvailability {
                available: true,
                model: preferred_local_model(),
                unavailable_reason: None,
            },
        };

        let route = resolve_model_route(
            None,
            Some(ModelPreset::LocalWhenPossible),
            &policy,
            &policy.default_model,
        );

        assert_eq!(route.selected_model.as_deref(), Some("ollama/gemma4:26b"));
        assert_eq!(route.model_class.as_deref(), Some("local"));
        assert!(!route.hosted_route_used);
        assert!(route.local_opt_in);
    }

    #[test]
    fn local_when_possible_discloses_hosted_route_when_unavailable() {
        let policy = ModelRoutingPolicy {
            default_model: CLAUDE_SONNET_4_6.to_owned(),
            local: LocalModelAvailability::unavailable("Ollama is not running."),
        };

        let route = resolve_model_route(
            None,
            Some(ModelPreset::LocalWhenPossible),
            &policy,
            &policy.default_model,
        );

        assert_eq!(route.selected_model.as_deref(), Some(CLAUDE_SONNET_4_6));
        assert_eq!(route.model_class.as_deref(), Some("hosted"));
        assert!(route.hosted_route_used);
        assert_eq!(route.hosted_route_label.as_deref(), Some("Hosted route"));
        assert_eq!(
            route.hosted_route_reason.as_deref(),
            Some("Ollama is not running.")
        );
    }
}
