use crate::domains::session::event_store::EventStore;
use crate::shared::server::context::run_blocking_task;
use crate::shared::server::errors::CapabilityError;
use serde_json::Value;
use std::sync::Arc;

/// Build the JSON payload for a `message.user` event.
///
/// When the prompt includes attachments, the payload is enriched so that
/// session resume can reconstruct client UI and the LLM can see previously-sent
/// images and documents in reconstructed history.
///
pub fn build_user_event_payload(prompt: &str, attachments: Option<&[Value]>) -> Value {
    let has_attachments = attachments.is_some_and(|v| !v.is_empty());

    let (content, image_count) = if !has_attachments {
        (Value::String(prompt.to_owned()), None)
    } else {
        let mut blocks = vec![serde_json::json!({"type": "text", "text": prompt})];
        let mut img_count: i64 = 0;

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
    payload
}

pub fn build_user_content_override(
    prompt: &str,
    model: &str,
    attachments: Option<&[Value]>,
) -> Option<crate::shared::protocol::messages::UserMessageContent> {
    let has_attachments = attachments.is_some_and(|v| !v.is_empty());
    if !has_attachments {
        return None;
    }

    let mut blocks = vec![crate::shared::protocol::content::UserContent::Text {
        text: prompt.to_owned(),
    }];

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
                    blocks.push(crate::shared::protocol::content::UserContent::Image {
                        data: data.to_owned(),
                        mime_type: mime.to_owned(),
                    });
                } else {
                    let extracted_text =
                        crate::shared::protocol::document_extractor::extract_text(data, mime);
                    blocks.push(crate::shared::protocol::content::UserContent::Document {
                        data: data.to_owned(),
                        mime_type: mime.to_owned(),
                        file_name,
                        extracted_text,
                    });
                }
            }
        }
    }

    if !crate::domains::model::routing::models::registry::model_supports_images(model) {
        blocks.retain(|block| {
            !matches!(
                block,
                crate::shared::protocol::content::UserContent::Image { .. }
            )
        });
    }

    (blocks.len() > 1)
        .then_some(crate::shared::protocol::messages::UserMessageContent::Blocks(blocks))
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::shared::protocol::content::UserContent;
    use crate::shared::protocol::messages::UserMessageContent;

    #[test]
    fn user_event_payload_projects_images_from_unified_attachments() {
        let attachments = vec![
            serde_json::json!({
                "data": "aW1hZ2U=",
                "mimeType": "image/png",
                "fileName": "shot.png"
            }),
            serde_json::json!({
                "data": "ZG9j",
                "mimeType": "application/pdf",
                "fileName": "note.pdf"
            }),
        ];

        let payload = build_user_event_payload("hello", Some(&attachments));

        assert_eq!(payload["imageCount"], 1);
        let blocks = payload["content"].as_array().expect("content blocks");
        assert_eq!(blocks[0]["type"], "text");
        assert_eq!(blocks[1]["type"], "image");
        assert_eq!(blocks[1]["mimeType"], "image/png");
        assert_eq!(blocks[2]["type"], "document");
        assert_eq!(blocks[2]["fileName"], "note.pdf");
    }

    #[test]
    fn user_content_override_uses_unified_attachments_for_multimodal_blocks() {
        let attachments = vec![
            serde_json::json!({
                "data": "aW1hZ2U=",
                "mimeType": "image/png"
            }),
            serde_json::json!({
                "data": "cGxhaW4gdGV4dA==",
                "mimeType": "text/plain",
                "fileName": "note.txt"
            }),
        ];

        let Some(UserMessageContent::Blocks(blocks)) =
            build_user_content_override("hello", "anthropic/claude-opus-4-6", Some(&attachments))
        else {
            panic!("expected multimodal content blocks");
        };

        assert!(matches!(blocks[0], UserContent::Text { .. }));
        assert!(matches!(blocks[1], UserContent::Image { .. }));
        assert!(matches!(blocks[2], UserContent::Document { .. }));
    }
}
