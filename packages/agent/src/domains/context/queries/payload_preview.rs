use crate::shared::server::errors::CapabilityError;
use serde_json::Value;
use serde_json::json;

pub(super) fn load_payload_preview(
    conn: &rusqlite::Connection,
    blob_id: &str,
) -> Result<Option<Value>, CapabilityError> {
    let content =
        crate::domains::session::event_store::sqlite::repositories::blob::BlobRepo::get_content(
            conn, blob_id,
        )
        .map_err(|error| CapabilityError::Internal {
            message: format!("audit payload blob lookup error: {error}"),
        })?;
    let Some(content) = content else {
        return Ok(None);
    };
    let mut value = serde_json::from_slice::<Value>(&content).unwrap_or_else(|_| {
        json!({
            "unparsedText": String::from_utf8_lossy(&content),
        })
    });
    redact_json_for_audit(&mut value);
    Ok(Some(value))
}

fn redact_json_for_audit(value: &mut Value) {
    match value {
        Value::Object(map) => {
            for (key, child) in map {
                if is_sensitive_key(key) {
                    *child = Value::String("[REDACTED]".into());
                } else {
                    redact_json_for_audit(child);
                }
            }
        }
        Value::Array(items) => {
            for item in items {
                redact_json_for_audit(item);
            }
        }
        Value::String(text) if text.len() > 500 => {
            text.truncate(500);
            text.push_str("...[truncated]");
        }
        _ => {}
    }
}

fn is_sensitive_key(key: &str) -> bool {
    let key = key.to_ascii_lowercase();
    [
        "token",
        "secret",
        "api_key",
        "apikey",
        "authorization",
        "bearer",
        "password",
        "credential",
    ]
    .iter()
    .any(|needle| key.contains(needle))
}

pub(super) fn parse_json_value(content: &str) -> Value {
    serde_json::from_str(content).unwrap_or_else(|_| json!({ "unparsed": content }))
}

pub(super) fn sql_error(error: rusqlite::Error) -> CapabilityError {
    CapabilityError::Internal {
        message: format!("context audit query failed: {error}"),
    }
}
