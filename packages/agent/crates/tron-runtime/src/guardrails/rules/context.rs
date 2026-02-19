//! Context rule: evaluates an arbitrary predicate on the evaluation context.
//!
//! Useful for session-state-dependent rules that can't be expressed as
//! simple pattern or path matching.

use crate::guardrails::types::{EvaluationContext, RuleEvaluationResult};

use super::RuleBase;

/// A rule that evaluates an arbitrary predicate on the context.
///
/// The condition closure captures whatever state it needs and returns
/// `true` if the rule should trigger.
pub struct ContextRule {
    /// Common rule fields.
    pub base: RuleBase,
    /// Condition function. Returns `true` if the rule should trigger.
    pub condition: Box<dyn Fn(&EvaluationContext) -> bool + Send + Sync>,
    /// Message to show when blocked.
    pub block_message: String,
}

impl ContextRule {
    /// Evaluate this context rule against the context.
    pub fn evaluate(&self, ctx: &EvaluationContext) -> RuleEvaluationResult {
        if (self.condition)(ctx) {
            RuleEvaluationResult::triggered(&self.base.id, self.base.severity, &self.block_message)
        } else {
            RuleEvaluationResult::not_triggered(&self.base.id)
        }
    }
}

impl std::fmt::Debug for ContextRule {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ContextRule")
            .field("id", &self.base.id)
            .field("block_message", &self.block_message)
            .field("condition", &"<fn>")
            .finish()
    }
}
