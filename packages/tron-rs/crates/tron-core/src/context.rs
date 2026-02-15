use std::path::PathBuf;

use serde::{Deserialize, Serialize};

use crate::messages::Message;
use crate::tools::ToolDefinition;

/// The complete context sent to a provider. Every field is a first-class concern.
#[derive(Clone, Debug)]
pub struct LlmContext {
    pub messages: Vec<Message>,
    pub system_blocks: Vec<SystemBlock>,
    pub tools: Vec<ToolDefinition>,
    pub working_directory: PathBuf,
}

impl LlmContext {
    /// Create an empty context (useful for testing).
    pub fn empty() -> Self {
        Self {
            messages: Vec::new(),
            system_blocks: Vec::new(),
            tools: Vec::new(),
            working_directory: PathBuf::from("/tmp"),
        }
    }
}

/// A system prompt block with cache-TTL classification.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct SystemBlock {
    pub content: String,
    pub stability: Stability,
    pub label: SystemBlockLabel,
}

/// Cache-TTL classification for system blocks.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum Stability {
    /// Content rarely changes — cache for 1 hour.
    Stable,
    /// Content changes frequently — cache for 5 minutes (default ephemeral).
    Volatile,
}

/// Labels for tracking what's in the context (debugging, token attribution).
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum SystemBlockLabel {
    CorePrompt,
    WorkingDirectory,
    StaticRules,
    DynamicRules,
    MemoryContent,
    SkillContext,
    SubagentResults,
    TaskContext,
    Custom(String),
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn system_block_label_serde() {
        let labels = vec![
            SystemBlockLabel::CorePrompt,
            SystemBlockLabel::StaticRules,
            SystemBlockLabel::Custom("my-block".into()),
        ];
        for label in &labels {
            let json = serde_json::to_string(label).unwrap();
            let parsed: SystemBlockLabel = serde_json::from_str(&json).unwrap();
            let json2 = serde_json::to_string(&parsed).unwrap();
            assert_eq!(json, json2);
        }
    }

    #[test]
    fn stability_serde() {
        let json = serde_json::to_string(&Stability::Stable).unwrap();
        assert_eq!(json, r#""stable""#);
        let json = serde_json::to_string(&Stability::Volatile).unwrap();
        assert_eq!(json, r#""volatile""#);
    }
}
