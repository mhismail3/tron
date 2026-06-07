use crate::domains::session::event_store::EventStore;
use crate::shared::server::context::run_blocking_task;
use crate::shared::server::errors::CapabilityError;
use serde_json::Value;
use std::sync::Arc;

/// Build the JSON payload for a `message.user` event.
///
/// When the prompt includes images or attachments, the payload is enriched
/// so that session resume can reconstruct client UI and the LLM can see
/// previously-sent images in reconstructed history.
///
/// The optional `extra_metadata` object is merged into the payload (top-level
/// fields like `messageKind`, `confirmationDecision`, `answerCount` used by
/// interactive capability handlers so iOS can render chips from structured data).
pub fn build_user_event_payload(
    prompt: &str,
    images: Option<&[Value]>,
    attachments: Option<&[Value]>,
    extra_metadata: Option<&Value>,
) -> Value {
    let has_images = images.is_some_and(|v| !v.is_empty());
    let has_attachments = attachments.is_some_and(|v| !v.is_empty());

    let (content, image_count) = if !has_images && !has_attachments {
        (Value::String(prompt.to_owned()), None)
    } else {
        let mut blocks = vec![serde_json::json!({"type": "text", "text": prompt})];
        let mut img_count: i64 = 0;

        if let Some(imgs) = images {
            for img in imgs {
                let data = img.get("data").and_then(|v| v.as_str());
                let mime = img
                    .get("mediaType")
                    .or_else(|| img.get("mimeType"))
                    .and_then(|v| v.as_str());
                if let (Some(d), Some(m)) = (data, mime) {
                    blocks.push(serde_json::json!({
                        "type": "image",
                        "data": d,
                        "mimeType": m,
                    }));
                    img_count += 1;
                }
            }
        }

        if let Some(atts) = attachments {
            for att in atts {
                let data = att.get("data").and_then(|v| v.as_str());
                let mime = att.get("mimeType").and_then(|v| v.as_str());
                if let (Some(d), Some(m)) = (data, mime) {
                    if m.starts_with("image/") {
                        blocks.push(serde_json::json!({
                            "type": "image",
                            "data": d,
                            "mimeType": m,
                        }));
                        img_count += 1;
                    } else {
                        let mut block = serde_json::json!({
                            "type": "document",
                            "data": d,
                            "mimeType": m,
                        });
                        if let Some(name) = att.get("fileName").and_then(|v| v.as_str()) {
                            block["fileName"] = Value::String(name.to_owned());
                        }
                        blocks.push(block);
                    }
                }
            }
        }

        if blocks.len() == 1 {
            (Value::String(prompt.to_owned()), None)
        } else {
            let count = if img_count > 0 { Some(img_count) } else { None };
            (Value::Array(blocks), count)
        }
    };

    let mut payload = serde_json::json!({ "content": content });
    if let Some(c) = image_count {
        payload["imageCount"] = Value::Number(c.into());
    }
    if let Some(Value::Object(extra)) = extra_metadata {
        if let Value::Object(ref mut obj) = payload {
            for (k, v) in extra {
                let _ = obj.insert(k.clone(), v.clone());
            }
        }
    }
    payload
}

pub fn build_user_content_override(
    prompt: &str,
    model: &str,
    images: Option<&[Value]>,
    attachments: Option<&[Value]>,
) -> Option<crate::shared::messages::UserMessageContent> {
    let has_images = images.is_some_and(|v| !v.is_empty());
    let has_attachments = attachments.is_some_and(|v| !v.is_empty());
    if !has_images && !has_attachments {
        return None;
    }

    let mut blocks = vec![crate::shared::content::UserContent::Text {
        text: prompt.to_owned(),
    }];

    if let Some(imgs) = images {
        for img in imgs {
            if let (Some(data), Some(media_type)) = (
                img.get("data").and_then(|v| v.as_str()),
                img.get("mediaType")
                    .or_else(|| img.get("mimeType"))
                    .and_then(|v| v.as_str()),
            ) {
                blocks.push(crate::shared::content::UserContent::Image {
                    data: data.to_owned(),
                    mime_type: media_type.to_owned(),
                });
            }
        }
    }

    if let Some(atts) = attachments {
        for att in atts {
            if let (Some(data), Some(mime)) = (
                att.get("data").and_then(|v| v.as_str()),
                att.get("mimeType").and_then(|v| v.as_str()),
            ) {
                let file_name = att
                    .get("fileName")
                    .and_then(|v| v.as_str())
                    .map(String::from);
                if mime.starts_with("image/") {
                    blocks.push(crate::shared::content::UserContent::Image {
                        data: data.to_owned(),
                        mime_type: mime.to_owned(),
                    });
                } else {
                    let extracted_text =
                        crate::shared::document_extractor::extract_text(data, mime);
                    blocks.push(crate::shared::content::UserContent::Document {
                        data: data.to_owned(),
                        mime_type: mime.to_owned(),
                        file_name,
                        extracted_text,
                    });
                }
            }
        }
    }

    if !crate::domains::model::providers::model_supports_images(model) {
        blocks.retain(|block| !matches!(block, crate::shared::content::UserContent::Image { .. }));
    }

    (blocks.len() > 1).then_some(crate::shared::messages::UserMessageContent::Blocks(blocks))
}

pub async fn persist_user_message_event(
    event_store: Arc<EventStore>,
    session_id: String,
    payload: Value,
) -> Result<(), CapabilityError> {
    run_blocking_task("agent.prompt.persist_user", move || {
        let _ = event_store.append(&crate::domains::session::event_store::AppendOptions {
            session_id: &session_id,
            event_type: crate::domains::session::event_store::EventType::MessageUser,
            payload,
            parent_id: None,
            sequence: None,
        });
        Ok(())
    })
    .await
}
