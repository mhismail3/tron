//! Resource rule: enforces numeric bounds on tool argument values.
//!
//! Used for limits like maximum bash timeout.

use crate::guardrails::types::{EvaluationContext, RuleEvaluationResult};

use super::RuleBase;

/// A rule that enforces numeric bounds on a specific tool argument.
#[derive(Debug)]
pub struct ResourceRule {
    /// Common rule fields.
    pub base: RuleBase,
    /// Which argument to check (e.g., "timeout").
    pub target_argument: String,
    /// Maximum allowed value.
    pub max_value: Option<f64>,
    /// Minimum allowed value.
    pub min_value: Option<f64>,
}

impl ResourceRule {
    /// Evaluate this resource rule against the context.
    pub fn evaluate(&self, ctx: &EvaluationContext) -> RuleEvaluationResult {
        let value = match ctx.tool_arguments.get(&self.target_argument) {
            Some(serde_json::Value::Number(n)) => {
                if let Some(f) = n.as_f64() {
                    f
                } else {
                    return RuleEvaluationResult::not_triggered(&self.base.id);
                }
            }
            _ => return RuleEvaluationResult::not_triggered(&self.base.id),
        };

        if let Some(max) = self.max_value {
            if value > max {
                return RuleEvaluationResult::triggered(
                    &self.base.id,
                    self.base.severity,
                    format!(
                        "{}: Value {} exceeds maximum {}",
                        self.base.name, value, max
                    ),
                )
                .with_details(serde_json::json!({
                    "value": value,
                    "maxValue": max,
                }));
            }
        }

        if let Some(min) = self.min_value {
            if value < min {
                return RuleEvaluationResult::triggered(
                    &self.base.id,
                    self.base.severity,
                    format!(
                        "{}: Value {} below minimum {}",
                        self.base.name, value, min
                    ),
                )
                .with_details(serde_json::json!({
                    "value": value,
                    "minValue": min,
                }));
            }
        }

        RuleEvaluationResult::not_triggered(&self.base.id)
    }
}
