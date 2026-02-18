//! Guardrail rule types and evaluation dispatch.
//!
//! All rule types share a common [`RuleBase`] with identification, severity,
//! scope, and filtering metadata. The [`GuardrailRule`] enum dispatches
//! evaluation to the appropriate rule-type-specific logic.

pub mod composite;
pub mod context;
pub mod path;
pub mod pattern;
pub mod resource;

use crate::guardrails::types::{
    EvaluationContext, RuleEvaluationResult, RuleTier, Scope, Severity,
};

/// Common base fields shared by all rule types.
#[derive(Debug, Clone)]
pub struct RuleBase {
    /// Unique identifier (e.g., "core.destructive-commands").
    pub id: String,
    /// Human-readable name.
    pub name: String,
    /// Description of what this rule protects against.
    pub description: String,
    /// Severity when rule is triggered.
    pub severity: Severity,
    /// Where this rule applies (global or tool-specific).
    pub scope: Scope,
    /// Core rules cannot be disabled.
    pub tier: RuleTier,
    /// Tools this rule applies to. Empty means all tools.
    pub tools: Vec<String>,
    /// Higher priority rules are evaluated first.
    pub priority: i32,
    /// Whether rule is enabled (ignored for core tier).
    pub enabled: bool,
    /// Tags for categorization.
    pub tags: Vec<String>,
}

/// Union of all guardrail rule types.
///
/// Each variant wraps a specific rule type that implements its own
/// evaluation logic. The `evaluate` method dispatches to the appropriate
/// implementation.
pub enum GuardrailRule {
    /// Matches regex patterns against tool argument values.
    Pattern(pattern::PatternRule),
    /// Protects filesystem paths with glob patterns.
    Path(path::PathRule),
    /// Enforces numeric bounds on argument values.
    Resource(resource::ResourceRule),
    /// Evaluates an arbitrary predicate on the context.
    Context(context::ContextRule),
    /// Combines child rules with AND/OR/NOT logic.
    Composite(composite::CompositeRule),
}

impl GuardrailRule {
    /// Get the common base fields for this rule.
    pub fn base(&self) -> &RuleBase {
        match self {
            Self::Pattern(r) => &r.base,
            Self::Path(r) => &r.base,
            Self::Resource(r) => &r.base,
            Self::Context(r) => &r.base,
            Self::Composite(r) => &r.base,
        }
    }

    /// Evaluate this rule against the given context.
    ///
    /// For composite rules, the optional `engine` reference is needed
    /// to resolve child rule IDs. For all other rule types, `engine` is ignored.
    pub fn evaluate(
        &self,
        ctx: &EvaluationContext,
        engine: Option<&crate::guardrails::engine::GuardrailEngine>,
    ) -> RuleEvaluationResult {
        match self {
            Self::Pattern(r) => r.evaluate(ctx),
            Self::Path(r) => r.evaluate(ctx),
            Self::Resource(r) => r.evaluate(ctx),
            Self::Context(r) => r.evaluate(ctx),
            Self::Composite(r) => r.evaluate(ctx, engine),
        }
    }
}

impl std::fmt::Debug for GuardrailRule {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Pattern(r) => f.debug_tuple("Pattern").field(&r.base.id).finish(),
            Self::Path(r) => f.debug_tuple("Path").field(&r.base.id).finish(),
            Self::Resource(r) => f.debug_tuple("Resource").field(&r.base.id).finish(),
            Self::Context(r) => f.debug_tuple("Context").field(&r.base.id).finish(),
            Self::Composite(r) => f.debug_tuple("Composite").field(&r.base.id).finish(),
        }
    }
}
