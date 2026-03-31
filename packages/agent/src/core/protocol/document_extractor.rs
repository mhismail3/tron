//! Text extraction from document attachments.
//!
//! Handles text-based formats only (plain text, JSON). Binary formats like PDF
//! are not extracted here — that's a separate future effort.

use base64::Engine;
use serde_json::Value;

/// Extract readable text from a base64-encoded document.
///
/// Returns `Some(text)` for text-based formats, `None` for binary formats.
pub fn extract_text(base64_data: &str, mime_type: &str) -> Option<String> {
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(base64_data)
        .ok()?;
    match mime_type {
        "text/plain" => String::from_utf8(bytes).ok(),
        "application/json" => serde_json::from_slice::<Value>(&bytes)
            .ok()
            .and_then(|v| serde_json::to_string_pretty(&v).ok()),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use base64::Engine;

    fn encode(data: &[u8]) -> String {
        base64::engine::general_purpose::STANDARD.encode(data)
    }

    #[test]
    fn extract_plain_text() {
        let b64 = encode(b"Hello, world!");
        assert_eq!(extract_text(&b64, "text/plain"), Some("Hello, world!".into()));
    }

    #[test]
    fn extract_json_pretty_prints() {
        let b64 = encode(br#"{"key":"value","num":42}"#);
        let result = extract_text(&b64, "application/json").unwrap();
        assert!(result.contains("\"key\": \"value\""));
        assert!(result.contains("\"num\": 42"));
    }

    #[test]
    fn extract_json_array() {
        let b64 = encode(b"[1,2,3]");
        let result = extract_text(&b64, "application/json").unwrap();
        assert!(result.contains("1"));
    }

    #[test]
    fn extract_invalid_utf8_returns_none() {
        let b64 = encode(&[0xFF, 0xFE, 0x00, 0x01]);
        assert_eq!(extract_text(&b64, "text/plain"), None);
    }

    #[test]
    fn extract_malformed_json_returns_none() {
        let b64 = encode(b"{not json}");
        assert_eq!(extract_text(&b64, "application/json"), None);
    }

    #[test]
    fn extract_pdf_returns_none() {
        let b64 = encode(b"%PDF-1.4 fake pdf data");
        assert_eq!(extract_text(&b64, "application/pdf"), None);
    }

    #[test]
    fn extract_unknown_mime_returns_none() {
        let b64 = encode(b"some data");
        assert_eq!(extract_text(&b64, "application/octet-stream"), None);
    }

    #[test]
    fn extract_empty_text() {
        let b64 = encode(b"");
        assert_eq!(extract_text(&b64, "text/plain"), Some(String::new()));
    }

    #[test]
    fn extract_invalid_base64_returns_none() {
        assert_eq!(extract_text("!!!not-base64!!!", "text/plain"), None);
    }
}
