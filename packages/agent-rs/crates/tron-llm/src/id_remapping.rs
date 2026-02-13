//! # Tool Call ID Remapping
//!
//! When switching providers mid-session, tool call IDs from one provider
//! (e.g., Anthropic's `toolu_01abc...`) may not be recognized by another
//! (e.g., `OpenAI` expects `call_...`). This module handles the mapping.
//!
//! The approach: scan all existing tool calls, generate synthetic IDs in the
//! target format for any that don't match, and use the mapping during message
//! conversion.

use std::collections::HashMap;

/// ID format for tool calls.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum IdFormat {
    /// Anthropic format: `toolu_...`
    Anthropic,
    /// `OpenAI` format: `call_...`
    OpenAi,
}

/// Check if a tool call ID is in Anthropic format (`toolu_` prefix).
pub fn is_anthropic_id(id: &str) -> bool {
    id.starts_with("toolu_")
}

/// Check if a tool call ID is in `OpenAI` format (`call_` prefix).
pub fn is_openai_id(id: &str) -> bool {
    id.starts_with("call_")
}

/// Determine the format of a tool call ID.
pub fn detect_id_format(id: &str) -> Option<IdFormat> {
    if is_anthropic_id(id) {
        Some(IdFormat::Anthropic)
    } else if is_openai_id(id) {
        Some(IdFormat::OpenAi)
    } else {
        None
    }
}

/// Build a mapping from original tool call IDs to target-format IDs.
///
/// Only IDs that don't already match the target format are remapped.
/// Synthetic IDs are generated as `toolu_remap_N` or `call_remap_N`.
///
/// Returns an empty map if all IDs already match the target format.
pub fn build_tool_call_id_mapping(
    tool_call_ids: &[&str],
    target_format: IdFormat,
) -> HashMap<String, String> {
    let mut mapping = HashMap::new();
    let mut remap_counter = 0u32;

    for &id in tool_call_ids {
        let needs_remap = match target_format {
            IdFormat::Anthropic => !is_anthropic_id(id),
            IdFormat::OpenAi => !is_openai_id(id),
        };

        if needs_remap {
            let synthetic = match target_format {
                IdFormat::Anthropic => format!("toolu_remap_{remap_counter}"),
                IdFormat::OpenAi => format!("call_remap_{remap_counter}"),
            };
            let _ = mapping.insert(id.to_string(), synthetic);
            remap_counter += 1;
        }
    }

    mapping
}

/// Remap a tool call ID using a previously built mapping.
///
/// Returns the mapped ID if found, or the original ID unchanged.
pub fn remap_tool_call_id<'a, S: std::hash::BuildHasher>(id: &'a str, mapping: &'a HashMap<String, String, S>) -> &'a str {
    mapping.get(id).map_or(id, |v| v.as_str())
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    // ── Format Detection ─────────────────────────────────────────────────

    #[test]
    fn detect_anthropic_format() {
        assert!(is_anthropic_id("toolu_01abc123"));
        assert!(!is_anthropic_id("call_abc123"));
        assert!(!is_anthropic_id("random_id"));
    }

    #[test]
    fn detect_openai_format() {
        assert!(is_openai_id("call_abc123"));
        assert!(!is_openai_id("toolu_01abc123"));
        assert!(!is_openai_id("random_id"));
    }

    #[test]
    fn detect_format_enum() {
        assert_eq!(detect_id_format("toolu_01abc"), Some(IdFormat::Anthropic));
        assert_eq!(detect_id_format("call_xyz"), Some(IdFormat::OpenAi));
        assert_eq!(detect_id_format("unknown_id"), None);
    }

    // ── Build Mapping ────────────────────────────────────────────────────

    #[test]
    fn build_mapping_all_match_target() {
        let ids = vec!["toolu_01abc", "toolu_02def"];
        let mapping = build_tool_call_id_mapping(&ids, IdFormat::Anthropic);
        assert!(mapping.is_empty());
    }

    #[test]
    fn build_mapping_needs_remap_to_anthropic() {
        let ids = vec!["call_abc", "toolu_01def", "call_xyz"];
        let mapping = build_tool_call_id_mapping(&ids, IdFormat::Anthropic);

        assert_eq!(mapping.len(), 2);
        assert_eq!(mapping["call_abc"], "toolu_remap_0");
        assert_eq!(mapping["call_xyz"], "toolu_remap_1");
        assert!(!mapping.contains_key("toolu_01def"));
    }

    #[test]
    fn build_mapping_needs_remap_to_openai() {
        let ids = vec!["toolu_01abc", "call_def", "toolu_02ghi"];
        let mapping = build_tool_call_id_mapping(&ids, IdFormat::OpenAi);

        assert_eq!(mapping.len(), 2);
        assert_eq!(mapping["toolu_01abc"], "call_remap_0");
        assert_eq!(mapping["toolu_02ghi"], "call_remap_1");
        assert!(!mapping.contains_key("call_def"));
    }

    #[test]
    fn build_mapping_empty_input() {
        let ids: Vec<&str> = vec![];
        let mapping = build_tool_call_id_mapping(&ids, IdFormat::Anthropic);
        assert!(mapping.is_empty());
    }

    #[test]
    fn build_mapping_unknown_format_ids() {
        let ids = vec!["random_123", "another_456"];
        let mapping = build_tool_call_id_mapping(&ids, IdFormat::Anthropic);
        assert_eq!(mapping.len(), 2);
        assert_eq!(mapping["random_123"], "toolu_remap_0");
        assert_eq!(mapping["another_456"], "toolu_remap_1");
    }

    // ── Remap ID ─────────────────────────────────────────────────────────

    #[test]
    fn remap_found_in_mapping() {
        let mut mapping = HashMap::new();
        let _ = mapping.insert("call_abc".to_string(), "toolu_remap_0".to_string());

        assert_eq!(remap_tool_call_id("call_abc", &mapping), "toolu_remap_0");
    }

    #[test]
    fn remap_not_in_mapping_returns_original() {
        let mapping = HashMap::new();
        assert_eq!(remap_tool_call_id("toolu_01abc", &mapping), "toolu_01abc");
    }

    #[test]
    fn remap_empty_mapping_returns_original() {
        let mapping = HashMap::new();
        assert_eq!(remap_tool_call_id("any_id", &mapping), "any_id");
    }

    // ── Integration: build + remap ───────────────────────────────────────

    #[test]
    fn roundtrip_build_and_remap() {
        let ids = vec!["call_foo", "toolu_01bar", "call_baz"];
        let mapping = build_tool_call_id_mapping(&ids, IdFormat::Anthropic);

        // OpenAI IDs get remapped
        assert_eq!(remap_tool_call_id("call_foo", &mapping), "toolu_remap_0");
        assert_eq!(remap_tool_call_id("call_baz", &mapping), "toolu_remap_1");

        // Anthropic ID stays the same
        assert_eq!(remap_tool_call_id("toolu_01bar", &mapping), "toolu_01bar");
    }
}
