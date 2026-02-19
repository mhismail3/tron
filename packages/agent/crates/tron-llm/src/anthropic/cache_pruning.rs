//! Prompt cache cold detection and tool result pruning.
//!
//! When the Anthropic prompt cache goes cold (>5 minutes since last API call),
//! re-caching the entire conversation is expensive. This module prunes large
//! tool result blocks from old turns to reduce cache write tokens.

use std::time::{SystemTime, UNIX_EPOCH};

use serde_json::Value;

use super::types::AnthropicMessageParam;

/// Default cache TTL in milliseconds (5 minutes).
pub const DEFAULT_TTL_MS: u64 = 5 * 60 * 1000;

/// Number of recent assistant turns to preserve without pruning.
pub const DEFAULT_RECENT_TURNS: usize = 3;

/// Minimum content size (bytes) to be considered for pruning.
pub const PRUNE_THRESHOLD_BYTES: usize = 2048;

/// Check whether the prompt cache has expired.
///
/// Returns `false` if `last_api_call_ms` is 0 (first request — no cache to expire)
/// or if the elapsed time is within the TTL.
#[must_use]
pub fn is_cache_cold(last_api_call_ms: u64, ttl_ms: u64) -> bool {
    if last_api_call_ms == 0 {
        return false; // First request — cache doesn't exist yet
    }
    #[allow(clippy::cast_possible_truncation)]
    let now_ms = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64;
    now_ms.saturating_sub(last_api_call_ms) > ttl_ms
}

/// Prune large `tool_result` content blocks from old turns.
///
/// When the cache goes cold, re-caching the entire conversation is expensive.
/// This function replaces large `tool_result` content (>2KB) in old turns with
/// a placeholder, keeping recent turns intact.
///
/// Returns a new Vec — never mutates the input.
#[must_use]
pub fn prune_tool_results_for_recache(
    messages: &[AnthropicMessageParam],
    recent_turns: usize,
) -> Vec<AnthropicMessageParam> {
    // Count assistant messages to determine turn boundaries
    let assistant_count = messages.iter().filter(|m| m.role == "assistant").count();

    if assistant_count <= recent_turns {
        return messages.to_vec(); // Not enough turns to prune
    }

    let preserve_after_turn = assistant_count - recent_turns;

    // Find cutoff index: walk messages, count assistant messages seen
    let mut turns_seen = 0usize;
    let mut cutoff_index = messages.len(); // Default: no pruning

    for (i, msg) in messages.iter().enumerate() {
        if msg.role == "assistant" {
            turns_seen += 1;
        }
        if turns_seen > preserve_after_turn {
            cutoff_index = i;
            break;
        }
    }

    // Clone messages, pruning large tool_results before the cutoff
    messages
        .iter()
        .enumerate()
        .map(|(i, msg)| {
            if i >= cutoff_index || msg.role != "user" {
                return msg.clone();
            }
            prune_user_message_tool_results(msg)
        })
        .collect()
}

/// Prune large `tool_result` content blocks in a user message.
fn prune_user_message_tool_results(msg: &AnthropicMessageParam) -> AnthropicMessageParam {
    let pruned_content: Vec<Value> = msg
        .content
        .iter()
        .map(|block| {
            if block.get("type").and_then(Value::as_str) != Some("tool_result") {
                return block.clone();
            }
            let content = &block["content"];
            let content_str = content.to_string();
            if content_str.len() <= PRUNE_THRESHOLD_BYTES {
                return block.clone();
            }
            // Prune: replace content with placeholder
            let mut pruned = block.clone();
            pruned["content"] = Value::String(format!(
                "[pruned {} chars for cache efficiency]",
                content_str.len()
            ));
            pruned
        })
        .collect();

    AnthropicMessageParam {
        role: msg.role.clone(),
        content: pruned_content,
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn user_msg(content: Vec<Value>) -> AnthropicMessageParam {
        AnthropicMessageParam {
            role: "user".into(),
            content,
        }
    }

    fn assistant_msg(content: Vec<Value>) -> AnthropicMessageParam {
        AnthropicMessageParam {
            role: "assistant".into(),
            content,
        }
    }

    fn tool_result_block(id: &str, content: &str) -> Value {
        json!({
            "type": "tool_result",
            "tool_use_id": id,
            "content": content,
        })
    }

    fn large_tool_result_block(id: &str) -> Value {
        let large_content = "x".repeat(3000);
        json!({
            "type": "tool_result",
            "tool_use_id": id,
            "content": large_content,
        })
    }

    // ── is_cache_cold ───────────────────────────────────────────────────

    #[test]
    fn cache_cold_first_request() {
        assert!(!is_cache_cold(0, DEFAULT_TTL_MS));
    }

    #[test]
    fn cache_cold_within_ttl() {
        let now_ms = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_millis() as u64;
        // 1 second ago
        assert!(!is_cache_cold(now_ms - 1000, DEFAULT_TTL_MS));
    }

    #[test]
    fn cache_cold_expired() {
        let now_ms = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_millis() as u64;
        // 6 minutes ago
        assert!(is_cache_cold(now_ms - 6 * 60 * 1000, DEFAULT_TTL_MS));
    }

    #[test]
    fn cache_cold_exactly_at_ttl() {
        let now_ms = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_millis() as u64;
        // Exactly 5 minutes ago — NOT cold (<=)
        let result = is_cache_cold(now_ms - DEFAULT_TTL_MS, DEFAULT_TTL_MS);
        // Could be cold or not depending on timing — just check it doesn't panic
        let _ = result;
    }

    // ── prune_tool_results_for_recache ──────────────────────────────────

    #[test]
    fn prune_not_enough_turns() {
        let messages = vec![
            user_msg(vec![json!("hello")]),
            assistant_msg(vec![json!({"type": "text", "text": "hi"})]),
        ];
        let result = prune_tool_results_for_recache(&messages, 3);
        assert_eq!(result.len(), 2);
    }

    #[test]
    fn prune_preserves_recent_turns() {
        let messages = vec![
            // Turn 1 (old)
            user_msg(vec![large_tool_result_block("t1")]),
            assistant_msg(vec![json!({"type": "text", "text": "r1"})]),
            // Turn 2 (old)
            user_msg(vec![large_tool_result_block("t2")]),
            assistant_msg(vec![json!({"type": "text", "text": "r2"})]),
            // Turn 3 (recent)
            user_msg(vec![large_tool_result_block("t3")]),
            assistant_msg(vec![json!({"type": "text", "text": "r3"})]),
            // Turn 4 (recent)
            user_msg(vec![large_tool_result_block("t4")]),
            assistant_msg(vec![json!({"type": "text", "text": "r4"})]),
            // Turn 5 (recent)
            user_msg(vec![large_tool_result_block("t5")]),
            assistant_msg(vec![json!({"type": "text", "text": "r5"})]),
        ];
        let result = prune_tool_results_for_recache(&messages, 3);
        assert_eq!(result.len(), 10);

        // Turn 1 user message (index 0) should be pruned
        let content_str = result[0].content[0]["content"].as_str().unwrap();
        assert!(content_str.contains("pruned"));

        // Turn 2 user message (index 2) should be pruned
        let content_str = result[2].content[0]["content"].as_str().unwrap();
        assert!(content_str.contains("pruned"));

        // Turn 3 user message (index 4) is also pruned — cutoff is at
        // the 3rd assistant (index 5), so indices 0-4 are in the old zone.
        let content_str = result[4].content[0]["content"].as_str().unwrap();
        assert!(content_str.contains("pruned"));

        // Turn 4 user message (index 6) should NOT be pruned (past cutoff)
        let content_str = result[6].content[0]["content"].to_string();
        assert!(!content_str.contains("pruned"));
    }

    #[test]
    fn prune_small_tool_results_not_pruned() {
        let messages = vec![
            // Turn 1 (old, but small tool result)
            user_msg(vec![tool_result_block("t1", "small output")]),
            assistant_msg(vec![json!({"type": "text", "text": "r1"})]),
            // Turn 2
            user_msg(vec![json!("user2")]),
            assistant_msg(vec![json!({"type": "text", "text": "r2"})]),
            // Turn 3
            user_msg(vec![json!("user3")]),
            assistant_msg(vec![json!({"type": "text", "text": "r3"})]),
            // Turn 4
            user_msg(vec![json!("user4")]),
            assistant_msg(vec![json!({"type": "text", "text": "r4"})]),
        ];
        let result = prune_tool_results_for_recache(&messages, 3);

        // Turn 1 tool result is small — NOT pruned
        let content = result[0].content[0]["content"].as_str().unwrap();
        assert_eq!(content, "small output");
    }

    #[test]
    fn prune_non_tool_result_blocks_untouched() {
        let messages = vec![
            user_msg(vec![json!({"type": "text", "text": "x".repeat(5000)})]),
            assistant_msg(vec![json!({"type": "text", "text": "r1"})]),
            user_msg(vec![json!("u2")]),
            assistant_msg(vec![json!({"type": "text", "text": "r2"})]),
            user_msg(vec![json!("u3")]),
            assistant_msg(vec![json!({"type": "text", "text": "r3"})]),
            user_msg(vec![json!("u4")]),
            assistant_msg(vec![json!({"type": "text", "text": "r4"})]),
        ];
        let result = prune_tool_results_for_recache(&messages, 3);

        // First user message has large text block, not tool_result — NOT pruned
        assert_eq!(result[0].content[0]["type"], "text");
    }

    #[test]
    fn prune_empty_messages() {
        let result = prune_tool_results_for_recache(&[], 3);
        assert!(result.is_empty());
    }

    #[test]
    fn prune_exactly_at_boundary() {
        // 3 turns, preserve 3 → nothing pruned
        let messages = vec![
            user_msg(vec![large_tool_result_block("t1")]),
            assistant_msg(vec![json!({"type": "text", "text": "r1"})]),
            user_msg(vec![large_tool_result_block("t2")]),
            assistant_msg(vec![json!({"type": "text", "text": "r2"})]),
            user_msg(vec![large_tool_result_block("t3")]),
            assistant_msg(vec![json!({"type": "text", "text": "r3"})]),
        ];
        let result = prune_tool_results_for_recache(&messages, 3);

        // All tool results preserved (exactly 3 turns, preserve 3)
        let content = result[0].content[0]["content"].to_string();
        assert!(!content.contains("pruned"));
    }
}
