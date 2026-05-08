use super::payload::inject_into_payload;
use super::{Map, SUBAGENT_RESULTS_MARKER};
use serde_json::Value;
use serde_json::json;

/// Back-fill `messageKind` into `message.user` events whose content starts
/// with the subagent results marker. Skips events that already have a
/// `messageKind` (tagged on the live path) and events where `content` is an
/// array (images/attachments) rather than a string.
pub(super) fn enrich_subagent_result_messages(events: &mut [Value]) {
    for event in events.iter_mut() {
        if event.get("type").and_then(Value::as_str) != Some("message.user") {
            continue;
        }

        let payload = match event.get("payload") {
            Some(p) => p,
            None => continue,
        };

        // Already tagged on the live path — skip.
        if payload.get("messageKind").is_some() {
            continue;
        }

        // Only match string content (not array content blocks from images).
        let content = match payload.get("content").and_then(Value::as_str) {
            Some(s) => s,
            None => continue,
        };

        if !content.starts_with(SUBAGENT_RESULTS_MARKER) {
            continue;
        }

        // Count subagent sections: each starts with "## [" (e.g. "## [+] Sub-Agent:").
        let count = content.matches("## [").count().max(1);

        let mut fields = Map::new();
        let _ = fields.insert("messageKind".into(), json!("subagent_results_delivered"));
        let _ = fields.insert("subagentCount".into(), json!(count));
        inject_into_payload(event, fields);
    }
}
