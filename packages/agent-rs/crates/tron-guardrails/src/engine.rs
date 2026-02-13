//! Guardrail evaluation engine.
//!
//! The central engine that manages rule registration, evaluation ordering,
//! and audit logging. Evaluates tool calls against registered rules and
//! returns block/warn/audit decisions.

use std::collections::HashMap;
use std::time::Instant;

use tracing::{debug, warn};

use crate::audit::AuditLogger;
use crate::core_rules::{default_rules, is_core_rule};
use crate::rules::GuardrailRule;
use crate::types::{
    AuditEntryParams, EvaluationContext, GuardrailEngineOptions, GuardrailEvaluation,
    RuleEvaluationResult,
};

/// Main guardrail evaluation engine.
///
/// Holds registered rules, evaluates tool calls against them in priority order,
/// and optionally logs all evaluations to an audit logger.
pub struct GuardrailEngine {
    rules: HashMap<String, GuardrailRule>,
    audit_logger: Option<AuditLogger>,
    rule_overrides: HashMap<String, crate::types::RuleOverride>,
}

impl GuardrailEngine {
    /// Create a new guardrail engine with default rules and the given options.
    pub fn new(options: GuardrailEngineOptions) -> Self {
        let audit_logger = if options.enable_audit.unwrap_or(true) {
            Some(AuditLogger::new(options.max_audit_entries))
        } else {
            None
        };

        let mut engine = Self {
            rules: HashMap::new(),
            audit_logger,
            rule_overrides: options.rule_overrides,
        };

        // Register default rules
        for rule in default_rules() {
            engine.register_rule(rule);
        }

        // Register custom rules
        for rule in options.custom_rules {
            engine.register_rule(rule);
        }

        debug!(rule_count = engine.rules.len(), "GuardrailEngine initialized");

        engine
    }

    /// Register a rule.
    ///
    /// Non-core rules cannot be registered with core tier.
    pub fn register_rule(&mut self, rule: GuardrailRule) {
        let base = rule.base();
        if base.tier == crate::types::RuleTier::Core && !is_core_rule(&base.id) {
            warn!(rule_id = %base.id, "Attempted to register non-core rule as core");
            return;
        }

        let id = base.id.clone();
        debug!(rule_id = %id, tier = %base.tier, "Rule registered");
        let _ = self.rules.insert(id, rule);
    }

    /// Unregister a rule by ID.
    ///
    /// Core rules cannot be unregistered. Returns `true` if the rule was
    /// successfully removed, `false` if not found or core-protected.
    pub fn unregister_rule(&mut self, rule_id: &str) -> bool {
        if is_core_rule(rule_id) {
            warn!(rule_id, "Cannot unregister core rule");
            return false;
        }
        self.rules.remove(rule_id).is_some()
    }

    /// Get a rule by ID.
    pub fn get_rule(&self, rule_id: &str) -> Option<&GuardrailRule> {
        self.rules.get(rule_id)
    }

    /// Get all registered rules.
    pub fn get_rules(&self) -> Vec<&GuardrailRule> {
        self.rules.values().collect()
    }

    /// Check if a rule is enabled, accounting for overrides.
    pub fn is_rule_enabled(&self, rule_id: &str) -> bool {
        let Some(rule) = self.rules.get(rule_id) else {
            return false;
        };

        // Core rules are always enabled
        if rule.base().tier == crate::types::RuleTier::Core {
            return true;
        }

        // Check user overrides
        if let Some(override_) = self.rule_overrides.get(rule_id) {
            if let Some(enabled) = override_.enabled {
                return enabled;
            }
        }

        rule.base().enabled
    }

    /// Evaluate a tool call against all applicable rules.
    ///
    /// Returns a [`GuardrailEvaluation`] with block/warn/audit decisions.
    /// All applicable rules are evaluated (even after a block), for comprehensive
    /// audit logging.
    pub fn evaluate(&mut self, ctx: &EvaluationContext) -> GuardrailEvaluation {
        let start = Instant::now();
        let mut triggered_rules: Vec<RuleEvaluationResult> = Vec::new();
        let mut warnings: Vec<String> = Vec::new();
        let mut blocked = false;
        let mut block_reason: Option<String> = None;

        // Get applicable rules sorted by priority (higher first)
        let applicable_rule_ids = self.get_applicable_rule_ids(&ctx.tool_name);

        for rule_id in applicable_rule_ids {
            if !self.is_rule_enabled(&rule_id) {
                continue;
            }

            let result = self.evaluate_rule(&rule_id, ctx);

            if result.triggered {
                if result.severity == Some(crate::types::Severity::Block) {
                    blocked = true;
                    if block_reason.is_none() {
                        block_reason = result.reason.clone().or_else(|| {
                            Some(format!("Blocked by rule: {rule_id}"))
                        });
                    }
                } else if result.severity == Some(crate::types::Severity::Warn) {
                    let warning = result
                        .reason
                        .clone()
                        .unwrap_or_else(|| format!("Warning from rule: {rule_id}"));
                    warnings.push(warning);
                }
                // 'audit' severity just logs, no action

                triggered_rules.push(result);
            }
        }

        let evaluation = GuardrailEvaluation {
            blocked,
            block_reason,
            triggered_rules,
            has_warnings: !warnings.is_empty(),
            warnings,
            timestamp: chrono::Utc::now().to_rfc3339(),
            duration_ms: u64::try_from(start.elapsed().as_millis()).unwrap_or(u64::MAX),
        };

        // Log to audit
        if let Some(audit) = &mut self.audit_logger {
            let _ = audit.log(AuditEntryParams {
                session_id: ctx.session_id.clone(),
                tool_name: ctx.tool_name.clone(),
                tool_call_id: ctx.tool_call_id.clone(),
                tool_arguments: Some(ctx.tool_arguments.clone()),
                evaluation: evaluation.clone(),
            });
        }

        evaluation
    }

    /// Get a reference to the audit logger, if enabled.
    pub fn audit_logger(&self) -> Option<&AuditLogger> {
        self.audit_logger.as_ref()
    }

    /// Get a mutable reference to the audit logger, if enabled.
    pub fn audit_logger_mut(&mut self) -> Option<&mut AuditLogger> {
        self.audit_logger.as_mut()
    }

    /// Get rule IDs applicable to a specific tool, sorted by priority (descending).
    fn get_applicable_rule_ids(&self, tool_name: &str) -> Vec<String> {
        let mut applicable: Vec<(&String, i32)> = self
            .rules
            .iter()
            .filter(|(_, rule)| {
                let base = rule.base();
                base.tools.is_empty() || base.tools.iter().any(|t| t == tool_name)
            })
            .map(|(id, rule)| (id, rule.base().priority))
            .collect();

        // Sort by priority descending
        applicable.sort_by(|a, b| b.1.cmp(&a.1));

        applicable.into_iter().map(|(id, _)| id.clone()).collect()
    }

    /// Evaluate a single rule by ID.
    fn evaluate_rule(&self, rule_id: &str, ctx: &EvaluationContext) -> RuleEvaluationResult {
        let Some(rule) = self.rules.get(rule_id) else {
            return RuleEvaluationResult::not_triggered(rule_id);
        };

        rule.evaluate(ctx, Some(self))
    }
}

impl std::fmt::Debug for GuardrailEngine {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("GuardrailEngine")
            .field("rule_count", &self.rules.len())
            .field("audit_enabled", &self.audit_logger.is_some())
            .field("override_count", &self.rule_overrides.len())
            .finish()
    }
}
