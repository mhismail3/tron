//! Error types for the guardrail system.

use thiserror::Error;

/// Errors that can occur during guardrail operations.
#[derive(Debug, Error)]
pub enum GuardrailError {
    /// Attempted to unregister a core rule.
    #[error("cannot unregister core rule: {rule_id}")]
    CoreRuleProtected {
        /// The ID of the core rule.
        rule_id: String,
    },

    /// Rule not found.
    #[error("rule not found: {rule_id}")]
    RuleNotFound {
        /// The ID of the missing rule.
        rule_id: String,
    },

    /// Invalid rule configuration.
    #[error("invalid rule configuration: {message}")]
    InvalidRule {
        /// Description of the configuration error.
        message: String,
    },

    /// Regex compilation error.
    #[error("regex compilation error: {0}")]
    Regex(#[from] regex::Error),
}
