use tron_core::provider::EffortLevel;

/// Information about a Claude model's capabilities and pricing.
#[derive(Clone, Debug)]
pub struct ClaudeModelInfo {
    pub name: &'static str,
    pub display_name: &'static str,
    pub context_window: usize,
    pub max_output: usize,
    pub supports_thinking: bool,
    pub supports_adaptive_thinking: bool,
    pub supports_effort: bool,
    pub effort_levels: &'static [EffortLevel],
    pub requires_thinking_beta_headers: bool,
    pub input_cost_per_mtok: f64,
    pub output_cost_per_mtok: f64,
    pub cache_read_cost_per_mtok: f64,
    pub cache_write_cost_per_mtok: f64,
}

impl ClaudeModelInfo {
    pub fn calculate_cost(
        &self,
        input_tokens: u32,
        output_tokens: u32,
        cache_read_tokens: u32,
        cache_creation_tokens: u32,
    ) -> f64 {
        let input = input_tokens as f64 / 1_000_000.0 * self.input_cost_per_mtok;
        let output = output_tokens as f64 / 1_000_000.0 * self.output_cost_per_mtok;
        let cache_read = cache_read_tokens as f64 / 1_000_000.0 * self.cache_read_cost_per_mtok;
        let cache_write = cache_creation_tokens as f64 / 1_000_000.0 * self.cache_write_cost_per_mtok;
        input + output + cache_read + cache_write
    }
}

pub static CLAUDE_OPUS_4_6: ClaudeModelInfo = ClaudeModelInfo {
    name: "claude-opus-4-6",
    display_name: "Claude Opus 4.6",
    context_window: 200_000,
    max_output: 128_000,
    supports_thinking: true,
    supports_adaptive_thinking: true,
    supports_effort: true,
    effort_levels: &[EffortLevel::Low, EffortLevel::Medium, EffortLevel::High, EffortLevel::Max],
    requires_thinking_beta_headers: false,
    input_cost_per_mtok: 15.0,
    output_cost_per_mtok: 75.0,
    cache_read_cost_per_mtok: 1.5,
    cache_write_cost_per_mtok: 18.75,
};

pub static CLAUDE_SONNET_4_5: ClaudeModelInfo = ClaudeModelInfo {
    name: "claude-sonnet-4-5-20250929",
    display_name: "Claude Sonnet 4.5",
    context_window: 200_000,
    max_output: 128_000,
    supports_thinking: true,
    supports_adaptive_thinking: false,
    supports_effort: true,
    effort_levels: &[EffortLevel::Low, EffortLevel::Medium, EffortLevel::High],
    requires_thinking_beta_headers: true,
    input_cost_per_mtok: 3.0,
    output_cost_per_mtok: 15.0,
    cache_read_cost_per_mtok: 0.3,
    cache_write_cost_per_mtok: 3.75,
};

pub static CLAUDE_HAIKU_4_5: ClaudeModelInfo = ClaudeModelInfo {
    name: "claude-haiku-4-5-20251001",
    display_name: "Claude Haiku 4.5",
    context_window: 200_000,
    max_output: 128_000,
    supports_thinking: true,
    supports_adaptive_thinking: false,
    supports_effort: true,
    effort_levels: &[EffortLevel::Low, EffortLevel::Medium, EffortLevel::High],
    requires_thinking_beta_headers: true,
    input_cost_per_mtok: 0.80,
    output_cost_per_mtok: 4.0,
    cache_read_cost_per_mtok: 0.08,
    cache_write_cost_per_mtok: 1.0,
};

static ALL_MODELS: &[&ClaudeModelInfo] = &[
    &CLAUDE_OPUS_4_6,
    &CLAUDE_SONNET_4_5,
    &CLAUDE_HAIKU_4_5,
];

pub fn find_model(name: &str) -> Option<&'static ClaudeModelInfo> {
    ALL_MODELS.iter().find(|m| m.name == name).copied()
}

pub fn default_model() -> &'static ClaudeModelInfo {
    &CLAUDE_SONNET_4_5
}

pub fn all_models() -> &'static [&'static ClaudeModelInfo] {
    ALL_MODELS
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn find_known_models() {
        assert!(find_model("claude-opus-4-6").is_some());
        assert!(find_model("claude-sonnet-4-5-20250929").is_some());
        assert!(find_model("claude-haiku-4-5-20251001").is_some());
        assert!(find_model("nonexistent").is_none());
    }

    #[test]
    fn opus_supports_adaptive() {
        let m = find_model("claude-opus-4-6").unwrap();
        assert!(m.supports_adaptive_thinking);
        assert!(!m.requires_thinking_beta_headers);
    }

    #[test]
    fn sonnet_requires_beta_headers() {
        let m = find_model("claude-sonnet-4-5-20250929").unwrap();
        assert!(!m.supports_adaptive_thinking);
        assert!(m.requires_thinking_beta_headers);
    }

    #[test]
    fn cost_calculation() {
        let m = &CLAUDE_SONNET_4_5;
        let cost = m.calculate_cost(1_000_000, 500_000, 200_000, 100_000);
        // input: 1M * 3.0/1M = 3.0
        // output: 500K * 15.0/1M = 7.5
        // cache_read: 200K * 0.3/1M = 0.06
        // cache_write: 100K * 3.75/1M = 0.375
        let expected = 3.0 + 7.5 + 0.06 + 0.375;
        assert!((cost - expected).abs() < 0.001, "got {cost}, expected {expected}");
    }

    #[test]
    fn all_models_listed() {
        assert_eq!(all_models().len(), 3);
    }

    #[test]
    fn default_model_is_sonnet() {
        assert_eq!(default_model().name, "claude-sonnet-4-5-20250929");
    }
}
