//! Effective attachment policy for model inputs.
//!
//! Provider limits, Tron's inline transport budget, and accepted MIME types
//! are combined here so every client receives the same contract and the
//! prompt boundary can enforce it. Clients may transform media to satisfy the
//! policy; they must not invent provider limits locally.

use serde::Serialize;
use serde_json::Value;

use crate::domains::auth::credentials::OpenAIAuthPath;
use crate::domains::model::providers::anthropic::types::get_claude_model;
use crate::domains::model::providers::google::types::get_gemini_model;
use crate::domains::model::providers::kimi::types::get_kimi_model;
use crate::domains::model::providers::minimax::types::get_minimax_model;
use crate::domains::model::providers::ollama::types::get_ollama_model;
use crate::domains::model::providers::openai::types::get_openai_model;
use crate::domains::model::routing::models::registry::strip_provider_prefix;

const INLINE_IMAGE_BUDGET_BYTES: usize = 1_400_000;
const TEXT_DOCUMENT_BUDGET_BYTES: usize = 20 * 1024 * 1024;

const ANTHROPIC_IMAGE_TYPES: &[&str] = &["image/jpeg", "image/png", "image/gif", "image/webp"];
const OPENAI_IMAGE_TYPES: &[&str] = &["image/jpeg", "image/png", "image/gif", "image/webp"];
const GOOGLE_IMAGE_TYPES: &[&str] = &[
    "image/jpeg",
    "image/png",
    "image/webp",
    "image/heic",
    "image/heif",
];
const KIMI_IMAGE_TYPES: &[&str] = &["image/jpeg", "image/png", "image/gif", "image/webp"];
const OLLAMA_IMAGE_TYPES: &[&str] = &["image/jpeg", "image/png", "image/webp"];
const NO_IMAGE_TYPES: &[&str] = &[];

/// Server-authoritative limits for inline attachments sent to one model.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct AttachmentPolicy {
    pub supports_pdf_content: bool,
    pub supports_text_files: bool,
    pub max_image_dimension: u32,
    pub max_image_bytes: usize,
    pub max_document_bytes: usize,
    pub supported_image_mime_types: &'static [&'static str],
}

impl AttachmentPolicy {
    fn for_provider(provider: &str, supports_images: bool, supports_documents: bool) -> Self {
        assert!(
            matches!(
                provider,
                "anthropic" | "openai-codex" | "google" | "kimi" | "minimax" | "ollama"
            ),
            "model catalog provider '{provider}' must define attachment policy"
        );
        let (max_image_dimension, supported_image_mime_types) = if !supports_images {
            (0, NO_IMAGE_TYPES)
        } else {
            match provider {
                "anthropic" => (1_568, ANTHROPIC_IMAGE_TYPES),
                "openai-codex" => (2_048, OPENAI_IMAGE_TYPES),
                "google" => (3_072, GOOGLE_IMAGE_TYPES),
                "kimi" => (4_096, KIMI_IMAGE_TYPES),
                "ollama" => (2_048, OLLAMA_IMAGE_TYPES),
                _ => unreachable!("provider assertion above covers image policies"),
            }
        };

        Self {
            supports_pdf_content: supports_documents,
            supports_text_files: true,
            max_image_dimension,
            max_image_bytes: supports_images
                .then_some(INLINE_IMAGE_BUDGET_BYTES)
                .unwrap_or(0),
            max_document_bytes: if supports_documents {
                match provider {
                    "google" => 50 * 1024 * 1024,
                    _ => TEXT_DOCUMENT_BUDGET_BYTES,
                }
            } else {
                TEXT_DOCUMENT_BUDGET_BYTES
            },
            supported_image_mime_types,
        }
    }

    #[must_use]
    pub(crate) fn accepts_image_mime_type(&self, mime_type: &str) -> bool {
        self.supported_image_mime_types.contains(&mime_type)
    }
}

/// Attach the effective policy to one `model.list` row.
pub(crate) fn decorate_model(mut model: Value) -> Value {
    let provider = model
        .get("provider")
        .and_then(Value::as_str)
        .unwrap_or_default();
    let supports_images = model
        .get("supportsImages")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let supports_documents = model
        .get("supportsDocuments")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let policy = AttachmentPolicy::for_provider(provider, supports_images, supports_documents);

    if let Some(object) = model.as_object_mut() {
        let value = serde_json::to_value(policy).expect("attachment policy must serialize");
        let _ = object.insert("attachmentPolicy".into(), value);
    }
    model
}

/// Resolve the same policy at the prompt validation boundary.
pub(crate) fn for_model(
    model_id: &str,
    openai_auth_path: OpenAIAuthPath,
) -> Option<AttachmentPolicy> {
    let bare = strip_provider_prefix(model_id);
    if let Some(model) = get_claude_model(bare) {
        return Some(AttachmentPolicy::for_provider(
            "anthropic",
            model.supports_images,
            true,
        ));
    }
    if let Some(model) = get_openai_model(bare) {
        let profile = model.profile_for_auth_path(openai_auth_path)?;
        return Some(AttachmentPolicy::for_provider(
            "openai-codex",
            profile.supports_images,
            false,
        ));
    }
    if let Some(model) = get_gemini_model(bare) {
        return Some(AttachmentPolicy::for_provider(
            "google",
            model.supports_images,
            true,
        ));
    }
    if let Some(model) = get_kimi_model(bare) {
        return Some(AttachmentPolicy::for_provider(
            "kimi",
            model.supports_images,
            false,
        ));
    }
    if let Some(model) = get_minimax_model(bare) {
        return Some(AttachmentPolicy::for_provider(
            "minimax",
            model.supports_images,
            false,
        ));
    }
    if let Some(model) = get_ollama_model(bare) {
        return Some(AttachmentPolicy::for_provider(
            "ollama",
            model.supports_images,
            false,
        ));
    }
    if model_id.starts_with("ollama/") {
        return Some(AttachmentPolicy::for_provider("ollama", false, false));
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decoration_emits_effective_provider_policy() {
        let model = decorate_model(serde_json::json!({
            "provider": "google",
            "supportsImages": true,
            "supportsDocuments": true
        }));

        assert_eq!(model["attachmentPolicy"]["maxImageDimension"], 3_072);
        assert_eq!(model["attachmentPolicy"]["supportsPdfContent"], true);
        assert_eq!(model["attachmentPolicy"]["supportsTextFiles"], true);
        assert_eq!(
            model["attachmentPolicy"]["maxImageBytes"],
            INLINE_IMAGE_BUDGET_BYTES
        );
        assert_eq!(
            model["attachmentPolicy"]["maxDocumentBytes"],
            50 * 1024 * 1024
        );
        assert_eq!(
            model["attachmentPolicy"]["supportedImageMimeTypes"],
            serde_json::json!(GOOGLE_IMAGE_TYPES)
        );
    }

    #[test]
    fn non_vision_model_has_no_image_budget_or_formats() {
        let policy = AttachmentPolicy::for_provider("minimax", false, false);
        assert_eq!(policy.max_image_dimension, 0);
        assert_eq!(policy.max_image_bytes, 0);
        assert!(policy.supported_image_mime_types.is_empty());
        assert_eq!(policy.max_document_bytes, TEXT_DOCUMENT_BUDGET_BYTES);
    }

    #[test]
    fn unknown_explicit_ollama_model_is_text_only_until_discovered() {
        let policy = for_model("ollama/example-local:8b", OpenAIAuthPath::ChatGptCodex)
            .expect("explicit Ollama provider policy");
        assert_eq!(policy.max_image_bytes, 0);
        assert!(policy.supported_image_mime_types.is_empty());
        assert!(!policy.supports_pdf_content);
    }
}
