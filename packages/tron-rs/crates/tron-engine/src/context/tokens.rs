use tron_core::context::SystemBlock;
use tron_core::messages::{
    AssistantContent, Message, ToolResultContent, UserContent,
};
use tron_core::tools::ToolDefinition;

/// Estimate token count for text content.
/// Approximation: chars / 4.
pub fn estimate_text_tokens(text: &str) -> u32 {
    (text.len() as u32).div_ceil(4)
}

/// Estimate tokens for a base64 image.
/// Approximation: (width * height) / 750, minimum 85.
pub fn estimate_image_tokens(base64_data: &str) -> u32 {
    // Without dimensions, estimate from base64 size.
    // Base64 encodes ~3/4 of original bytes. A rough image pixel estimate:
    // original_bytes ≈ base64.len() * 3/4
    // pixels ≈ original_bytes / 3 (RGB)
    // tokens ≈ pixels / 750
    let estimated_bytes = (base64_data.len() * 3) / 4;
    let estimated_pixels = estimated_bytes / 3;
    let tokens = estimated_pixels as u32 / 750;
    tokens.max(85)
}

/// Estimate tokens for a single message.
pub fn estimate_message_tokens(msg: &Message) -> u32 {
    match msg {
        Message::User(user) => {
            let mut total = 4u32; // overhead
            for content in &user.content {
                total += match content {
                    UserContent::Text { text } => estimate_text_tokens(text),
                    UserContent::Image { data, .. } => estimate_image_tokens(data),
                    UserContent::Document { data, .. } => estimate_text_tokens(data),
                };
            }
            total
        }
        Message::Assistant(assistant) => {
            let mut total = 4u32;
            for content in &assistant.content {
                total += match content {
                    AssistantContent::Text { text } => estimate_text_tokens(text),
                    AssistantContent::Thinking { text, .. } => estimate_text_tokens(text),
                    AssistantContent::ToolCall(tc) => {
                        estimate_text_tokens(&tc.name)
                            + estimate_text_tokens(&tc.arguments.to_string())
                    }
                };
            }
            total
        }
        Message::ToolResult(result) => {
            let mut total = 4u32;
            for content in &result.content {
                total += match content {
                    ToolResultContent::Text { text } => estimate_text_tokens(text),
                    ToolResultContent::Image { data, .. } => estimate_image_tokens(data),
                };
            }
            total
        }
    }
}

/// Estimate tokens for system blocks.
pub fn estimate_system_tokens(blocks: &[SystemBlock]) -> u32 {
    blocks.iter().map(|b| estimate_text_tokens(&b.content)).sum()
}

/// Estimate tokens for tool definitions.
pub fn estimate_tool_tokens(tools: &[ToolDefinition]) -> u32 {
    tools
        .iter()
        .map(|t| {
            estimate_text_tokens(&t.name)
                + estimate_text_tokens(&t.description)
                + estimate_text_tokens(&t.parameters_schema.to_string())
        })
        .sum()
}

/// Context usage threshold levels.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ThresholdLevel {
    Normal,   // 0-50%
    Warning,  // 50-70%
    Alert,    // 70-85%
    Critical, // 85-95%
    Exceeded, // 95%+
}

impl ThresholdLevel {
    pub fn from_usage(used: u32, total: u32) -> Self {
        if total == 0 {
            return Self::Exceeded;
        }
        let pct = (used as f64 / total as f64) * 100.0;
        if pct >= 95.0 {
            Self::Exceeded
        } else if pct >= 85.0 {
            Self::Critical
        } else if pct >= 70.0 {
            Self::Alert
        } else if pct >= 50.0 {
            Self::Warning
        } else {
            Self::Normal
        }
    }

    pub fn should_compact(&self) -> bool {
        matches!(self, Self::Alert | Self::Critical | Self::Exceeded)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tron_core::context::{Stability, SystemBlockLabel};

    #[test]
    fn text_token_estimation() {
        assert_eq!(estimate_text_tokens(""), 0); // (0 + 3) / 4 = 0 (integer division rounds down)
        assert_eq!(estimate_text_tokens("hello world"), 3); // 11 chars / 4 ≈ 3
        assert_eq!(estimate_text_tokens("a".repeat(400).as_str()), 100);
    }

    #[test]
    fn image_token_estimation_minimum() {
        assert_eq!(estimate_image_tokens(""), 85); // minimum
        assert_eq!(estimate_image_tokens("abc"), 85); // still minimum for tiny data
    }

    #[test]
    fn message_token_estimation() {
        let msg = Message::user_text("hello world");
        let tokens = estimate_message_tokens(&msg);
        assert!(tokens > 0);
        assert!(tokens < 100); // sanity check
    }

    #[test]
    fn system_tokens() {
        let blocks = vec![
            SystemBlock {
                content: "You are an AI assistant.".into(),
                stability: Stability::Stable,
                label: SystemBlockLabel::CorePrompt,
            },
            SystemBlock {
                content: "Working directory: /tmp".into(),
                stability: Stability::Stable,
                label: SystemBlockLabel::WorkingDirectory,
            },
        ];
        let tokens = estimate_system_tokens(&blocks);
        assert!(tokens > 0);
    }

    #[test]
    fn threshold_levels() {
        assert_eq!(ThresholdLevel::from_usage(0, 200000), ThresholdLevel::Normal);
        assert_eq!(ThresholdLevel::from_usage(100000, 200000), ThresholdLevel::Warning);
        assert_eq!(ThresholdLevel::from_usage(140000, 200000), ThresholdLevel::Alert);
        assert_eq!(ThresholdLevel::from_usage(170000, 200000), ThresholdLevel::Critical);
        assert_eq!(ThresholdLevel::from_usage(195000, 200000), ThresholdLevel::Exceeded);
    }

    #[test]
    fn should_compact_at_alert() {
        assert!(!ThresholdLevel::Normal.should_compact());
        assert!(!ThresholdLevel::Warning.should_compact());
        assert!(ThresholdLevel::Alert.should_compact());
        assert!(ThresholdLevel::Critical.should_compact());
        assert!(ThresholdLevel::Exceeded.should_compact());
    }

    #[test]
    fn zero_total_is_exceeded() {
        assert_eq!(ThresholdLevel::from_usage(0, 0), ThresholdLevel::Exceeded);
    }
}
