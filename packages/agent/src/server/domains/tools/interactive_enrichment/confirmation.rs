use super::CONFIRMATION_MARKER;
use serde_json::Map;
use serde_json::Value;
use serde_json::json;

/// Parse a `[Confirmation response]`-prefixed user message into
/// `{toolStatus, confirmationDecision, confirmationNote}`.
///
/// Matches the iOS `GetConfirmationDetector.parseConfirmationResponse`
/// semantics exactly, including:
/// - case-sensitive `Decision: Approved` check
/// - unparseable decisions default to `denied`
/// - empty `Note:` is treated as absent
pub(super) fn parse_confirmation(user_msg: Option<&str>) -> Map<String, Value> {
    let mut out = Map::new();
    let Some(msg) = user_msg else {
        let _ = out.insert("toolStatus".into(), json!("pending"));
        return out;
    };
    if !msg.contains(CONFIRMATION_MARKER) {
        let _ = out.insert("toolStatus".into(), json!("superseded"));
        return out;
    }

    let mut decision: Option<String> = None;
    let mut note: Option<String> = None;
    for raw_line in msg.lines() {
        let line = raw_line.trim();
        if let Some(rest) = line.strip_prefix("Decision:") {
            decision = Some(rest.trim().to_string());
        } else if let Some(rest) = line.strip_prefix("Note:") {
            let trimmed = rest.trim();
            if !trimmed.is_empty() {
                note = Some(trimmed.to_string());
            }
        }
    }

    let status = match decision.as_deref() {
        Some("Approved") => "approved",
        _ => "denied",
    };
    let _ = out.insert("toolStatus".into(), json!(status));
    if let Some(d) = decision {
        let _ = out.insert("confirmationDecision".into(), json!(d));
    }
    if let Some(n) = note {
        let _ = out.insert("confirmationNote".into(), json!(n));
    }
    out
}
