//! Synchronous rule engine that evaluates capability invocations against safety rules
//! before execution. Three tiers: core (immutable, always active), standard
//! (can be disabled by settings), custom (user-defined). Five rule types:
//! pattern, path, resource, context, composite. Three severities: block
//! (stop execution), warn (log + continue), audit (silent log).

pub mod audit;
pub mod core_rules;
pub mod engine;
pub mod errors;
pub mod rules;
pub mod types;

// Re-export main public API
pub use engine::GuardrailEngine;
pub use errors::GuardrailError;
pub use rules::GuardrailRule;
pub use types::{
    EvaluationContext, GuardrailEngineOptions, RuleOverride, RuleTier, Scope, Severity,
};

#[cfg(test)]
mod tests;
