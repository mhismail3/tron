//! Pattern rule: matches regex patterns against tool argument values.
//!
//! Used for detecting dangerous command patterns (e.g., `rm -rf /`,
//! fork bombs, raw disk writes).

use regex::Regex;

use crate::guardrails::types::{EvaluationContext, RuleEvaluationResult};

use super::RuleBase;

/// A rule that matches regex patterns against a specific tool argument.
pub struct PatternRule {
    /// Common rule fields.
    pub base: RuleBase,
    /// Which argument to check (e.g., "command" for Bash).
    pub target_argument: String,
    /// Regex patterns to match. First match wins.
    pub patterns: Vec<Regex>,
}

impl PatternRule {
    /// Evaluate this pattern rule against the context.
    pub fn evaluate(&self, ctx: &EvaluationContext) -> RuleEvaluationResult {
        let Some(serde_json::Value::String(value)) =
            ctx.tool_arguments.get(&self.target_argument)
        else {
            return RuleEvaluationResult::not_triggered(&self.base.id);
        };

        for pattern in &self.patterns {
            if pattern.is_match(value) {
                return RuleEvaluationResult::triggered(
                    &self.base.id,
                    self.base.severity,
                    format!(
                        "{}: Potentially destructive command pattern detected",
                        self.base.name
                    ),
                )
                .with_details(serde_json::json!({
                    "matchedPattern": pattern.as_str()
                }));
            }
        }

        RuleEvaluationResult::not_triggered(&self.base.id)
    }
}

impl std::fmt::Debug for PatternRule {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("PatternRule")
            .field("id", &self.base.id)
            .field("target_argument", &self.target_argument)
            .field("pattern_count", &self.patterns.len())
            .finish()
    }
}
