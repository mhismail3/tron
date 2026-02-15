use std::pin::Pin;

use async_trait::async_trait;
use futures::Stream;

use crate::context::LlmContext;
use crate::errors::GatewayError;
use crate::stream::StreamEvent;

/// Options controlling LLM generation behavior.
#[derive(Clone, Debug)]
pub struct StreamOptions {
    pub max_tokens: Option<u32>,
    pub temperature: Option<f64>,
    pub thinking: ThinkingConfig,
    pub effort_level: Option<EffortLevel>,
    pub stop_sequences: Vec<String>,
}

impl Default for StreamOptions {
    fn default() -> Self {
        Self {
            max_tokens: None,
            temperature: None,
            thinking: ThinkingConfig::Adaptive,
            effort_level: None,
            stop_sequences: Vec::new(),
        }
    }
}

#[derive(Clone, Debug, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ThinkingConfig {
    Disabled,
    Adaptive,
    Budget { tokens: u32 },
}

#[derive(Clone, Debug, serde::Serialize, serde::Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum EffortLevel {
    Low,
    Medium,
    High,
    Max,
}

/// Trait implemented by each LLM provider (Anthropic, OpenAI, Google).
#[async_trait]
pub trait LlmProvider: Send + Sync {
    fn name(&self) -> &str;
    fn model(&self) -> &str;
    fn context_window(&self) -> usize;
    fn supports_thinking(&self) -> bool;
    fn supports_tools(&self) -> bool;

    async fn stream(
        &self,
        context: &LlmContext,
        options: &StreamOptions,
    ) -> Result<Pin<Box<dyn Stream<Item = StreamEvent> + Send>>, GatewayError>;
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stream_options_defaults() {
        let opts = StreamOptions::default();
        assert!(opts.max_tokens.is_none());
        assert!(opts.temperature.is_none());
        assert!(matches!(opts.thinking, ThinkingConfig::Adaptive));
        assert!(opts.effort_level.is_none());
        assert!(opts.stop_sequences.is_empty());
    }

    #[test]
    fn thinking_config_serde() {
        let configs = vec![
            ThinkingConfig::Disabled,
            ThinkingConfig::Adaptive,
            ThinkingConfig::Budget { tokens: 10000 },
        ];
        for cfg in &configs {
            let json = serde_json::to_string(cfg).unwrap();
            let parsed: ThinkingConfig = serde_json::from_str(&json).unwrap();
            let json2 = serde_json::to_string(&parsed).unwrap();
            assert_eq!(json, json2);
        }
    }

    #[test]
    fn effort_level_serde() {
        let levels = vec![EffortLevel::Low, EffortLevel::Medium, EffortLevel::High, EffortLevel::Max];
        for lvl in &levels {
            let json = serde_json::to_string(lvl).unwrap();
            let parsed: EffortLevel = serde_json::from_str(&json).unwrap();
            assert_eq!(*lvl, parsed);
        }
    }
}
