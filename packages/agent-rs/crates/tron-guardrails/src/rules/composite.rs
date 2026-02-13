//! Composite rule: combines child rules with AND/OR/NOT logic.
//!
//! Requires a reference to the engine to resolve child rule IDs.

use crate::types::{EvaluationContext, RuleEvaluationResult};

use super::RuleBase;

/// How to combine child rules.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CompositeOperator {
    /// All child rules must trigger.
    And,
    /// Any child rule must trigger.
    Or,
    /// The first child rule must NOT trigger.
    Not,
}

/// A rule that combines child rules with a logical operator.
#[derive(Debug)]
pub struct CompositeRule {
    /// Common rule fields.
    pub base: RuleBase,
    /// How to combine child rules.
    pub operator: CompositeOperator,
    /// IDs of child rules to combine.
    pub child_rule_ids: Vec<String>,
}

impl CompositeRule {
    /// Evaluate this composite rule against the context.
    ///
    /// Requires an optional engine reference to resolve child rule IDs.
    /// If the engine is `None` or a child rule is not found, that child
    /// is treated as not-triggered.
    pub fn evaluate(
        &self,
        ctx: &EvaluationContext,
        engine: Option<&crate::engine::GuardrailEngine>,
    ) -> RuleEvaluationResult {
        let child_results: Vec<RuleEvaluationResult> = self
            .child_rule_ids
            .iter()
            .filter_map(|child_id| {
                let engine = engine?;
                let child_rule = engine.get_rule(child_id)?;
                // Evaluate child without recursive composite resolution
                Some(child_rule.evaluate(ctx, Some(engine)))
            })
            .collect();

        let triggered = match self.operator {
            CompositeOperator::And => {
                !child_results.is_empty() && child_results.iter().all(|r| r.triggered)
            }
            CompositeOperator::Or => child_results.iter().any(|r| r.triggered),
            CompositeOperator::Not => {
                child_results.first().is_some_and(|r| !r.triggered)
            }
        };

        if triggered {
            RuleEvaluationResult::triggered(
                &self.base.id,
                self.base.severity,
                format!("Composite rule {} triggered", self.base.name),
            )
            .with_details(serde_json::json!({
                "childResults": child_results.iter().map(|r| {
                    serde_json::json!({
                        "ruleId": r.rule_id,
                        "triggered": r.triggered,
                    })
                }).collect::<Vec<_>>()
            }))
        } else {
            RuleEvaluationResult::not_triggered(&self.base.id)
        }
    }
}
