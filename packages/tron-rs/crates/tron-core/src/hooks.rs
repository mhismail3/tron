use serde::{Deserialize, Serialize};

/// All 8 hook types in the agent lifecycle.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq, Hash)]
#[serde(rename_all = "snake_case")]
pub enum HookType {
    /// Blocking — can block/modify tool execution.
    PreToolUse,
    /// Background — fire and forget after tool completes.
    PostToolUse,
    /// Background — agent stopping.
    Stop,
    /// Background — sub-agent stopping.
    SubagentStop,
    /// Background — session created.
    SessionStart,
    /// Background — session ending.
    SessionEnd,
    /// Blocking — can block/modify user prompt.
    UserPromptSubmit,
    /// Blocking — can block compaction.
    PreCompact,
}

/// Result returned by a hook handler.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(tag = "action")]
pub enum HookResult {
    #[serde(rename = "continue")]
    Continue,
    #[serde(rename = "block")]
    Block { reason: String },
    #[serde(rename = "modify")]
    Modify { modifications: serde_json::Value },
}

impl HookType {
    pub fn is_blocking(&self) -> bool {
        matches!(self, Self::PreToolUse | Self::UserPromptSubmit | Self::PreCompact)
    }

    pub fn is_background(&self) -> bool {
        !self.is_blocking()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn blocking_hooks() {
        assert!(HookType::PreToolUse.is_blocking());
        assert!(HookType::UserPromptSubmit.is_blocking());
        assert!(HookType::PreCompact.is_blocking());
    }

    #[test]
    fn background_hooks() {
        assert!(HookType::PostToolUse.is_background());
        assert!(HookType::Stop.is_background());
        assert!(HookType::SubagentStop.is_background());
        assert!(HookType::SessionStart.is_background());
        assert!(HookType::SessionEnd.is_background());
    }

    #[test]
    fn all_hook_types_classified() {
        let all = [
            HookType::PreToolUse,
            HookType::PostToolUse,
            HookType::Stop,
            HookType::SubagentStop,
            HookType::SessionStart,
            HookType::SessionEnd,
            HookType::UserPromptSubmit,
            HookType::PreCompact,
        ];
        let blocking_count = all.iter().filter(|h| h.is_blocking()).count();
        let background_count = all.iter().filter(|h| h.is_background()).count();
        assert_eq!(blocking_count, 3);
        assert_eq!(background_count, 5);
        assert_eq!(all.len(), 8);
    }

    #[test]
    fn hook_type_serde() {
        let all = [
            HookType::PreToolUse,
            HookType::PostToolUse,
            HookType::Stop,
            HookType::SubagentStop,
            HookType::SessionStart,
            HookType::SessionEnd,
            HookType::UserPromptSubmit,
            HookType::PreCompact,
        ];
        for ht in &all {
            let json = serde_json::to_string(ht).unwrap();
            let parsed: HookType = serde_json::from_str(&json).unwrap();
            assert_eq!(*ht, parsed);
        }
    }

    #[test]
    fn hook_result_serde() {
        let results = vec![
            HookResult::Continue,
            HookResult::Block { reason: "disallowed".into() },
            HookResult::Modify {
                modifications: serde_json::json!({"args": {"timeout": 30}}),
            },
        ];
        for r in &results {
            let json = serde_json::to_string(r).unwrap();
            let parsed: HookResult = serde_json::from_str(&json).unwrap();
            let json2 = serde_json::to_string(&parsed).unwrap();
            assert_eq!(json, json2);
        }
    }
}
