//! Guardrail settings.
//!
//! Optional safety rules for tool execution — pattern matching, path
//! protection, resource limits, and audit configuration.

use std::collections::HashMap;

use serde::{Deserialize, Serialize};
use serde_json::Value;

/// Optional guardrail configuration.
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct GuardrailSettings {
    /// Per-rule overrides keyed by rule ID.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub rules: Option<HashMap<String, GuardrailRuleOverride>>,
    /// Custom guardrail rules (user-defined).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub custom_rules: Option<Vec<CustomGuardrailRule>>,
    /// Audit logging configuration.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub audit: Option<GuardrailAuditSettings>,
}

/// Override for a built-in guardrail rule.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct GuardrailRuleOverride {
    /// Whether the rule is enabled.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub enabled: Option<bool>,
    /// Additional rule-specific overrides (open-ended).
    #[serde(flatten)]
    pub extra: HashMap<String, Value>,
}

/// Guardrail severity level.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum GuardrailSeverity {
    /// Block the action entirely.
    Block,
    /// Warn the user but allow the action.
    Warn,
    /// Log the action for audit review.
    Audit,
}

/// Guardrail rule tier.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum GuardrailTier {
    /// Core rules (cannot be overridden by user).
    Core,
    /// Standard rules (can be adjusted).
    Standard,
    /// User-defined custom rules.
    Custom,
}

/// Type of guardrail rule.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum GuardrailRuleType {
    /// Regex pattern matching on tool arguments.
    Pattern,
    /// File path protection via glob patterns.
    Path,
    /// Numeric resource limits.
    Resource,
    /// Context-aware rules.
    Context,
}

/// A user-defined guardrail rule.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CustomGuardrailRule {
    /// Unique rule identifier.
    pub id: String,
    /// Rule type.
    #[serde(rename = "type")]
    pub rule_type: GuardrailRuleType,
    /// Rule tier (cannot be `Core`).
    pub tier: GuardrailTier,
    /// Action severity when triggered.
    pub severity: GuardrailSeverity,
    /// Tool names this rule applies to (empty = all tools).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tools: Option<Vec<String>>,
    /// Execution priority (lower = earlier).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub priority: Option<i32>,
    /// Descriptive tags.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tags: Option<Vec<String>>,
    /// Target argument name for pattern rules.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub target_argument: Option<String>,
    /// Regex patterns for pattern rules.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub patterns: Option<Vec<String>>,
    /// Protected path globs for path rules.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub protected_paths: Option<Vec<String>>,
    /// Maximum numeric value for resource rules.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub max_value: Option<f64>,
}

/// Guardrail audit settings.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct GuardrailAuditSettings {
    /// Whether audit logging is enabled.
    pub enabled: bool,
    /// Maximum number of audit entries to retain.
    pub max_entries: usize,
}

impl Default for GuardrailAuditSettings {
    fn default() -> Self {
        Self {
            enabled: true,
            max_entries: 1000,
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn guardrail_settings_default_is_empty() {
        let g = GuardrailSettings::default();
        assert!(g.rules.is_none());
        assert!(g.custom_rules.is_none());
        assert!(g.audit.is_none());
    }

    #[test]
    fn guardrail_severity_serde() {
        for (sev, expected) in [
            (GuardrailSeverity::Block, "\"block\""),
            (GuardrailSeverity::Warn, "\"warn\""),
            (GuardrailSeverity::Audit, "\"audit\""),
        ] {
            let json = serde_json::to_string(&sev).unwrap();
            assert_eq!(json, expected);
            let back: GuardrailSeverity = serde_json::from_str(&json).unwrap();
            assert_eq!(back, sev);
        }
    }

    #[test]
    fn guardrail_tier_serde() {
        for (tier, expected) in [
            (GuardrailTier::Core, "\"core\""),
            (GuardrailTier::Standard, "\"standard\""),
            (GuardrailTier::Custom, "\"custom\""),
        ] {
            let json = serde_json::to_string(&tier).unwrap();
            assert_eq!(json, expected);
        }
    }

    #[test]
    fn guardrail_rule_type_serde() {
        for (rt, expected) in [
            (GuardrailRuleType::Pattern, "\"pattern\""),
            (GuardrailRuleType::Path, "\"path\""),
            (GuardrailRuleType::Resource, "\"resource\""),
            (GuardrailRuleType::Context, "\"context\""),
        ] {
            let json = serde_json::to_string(&rt).unwrap();
            assert_eq!(json, expected);
        }
    }

    #[test]
    fn custom_guardrail_rule_serde() {
        let rule = CustomGuardrailRule {
            id: "no-sudo".to_string(),
            rule_type: GuardrailRuleType::Pattern,
            tier: GuardrailTier::Standard,
            severity: GuardrailSeverity::Block,
            tools: Some(vec!["Bash".to_string()]),
            priority: Some(10),
            tags: None,
            target_argument: Some("command".to_string()),
            patterns: Some(vec![r"^sudo\s+".to_string()]),
            protected_paths: None,
            max_value: None,
        };

        let json = serde_json::to_value(&rule).unwrap();
        assert_eq!(json["type"], "pattern");
        assert_eq!(json["tier"], "standard");
        assert_eq!(json["severity"], "block");
        assert_eq!(json["targetArgument"], "command");

        let back: CustomGuardrailRule = serde_json::from_value(json).unwrap();
        assert_eq!(back.id, "no-sudo");
        assert_eq!(back.patterns.unwrap()[0], r"^sudo\s+");
    }

    #[test]
    fn guardrail_settings_full_json() {
        let json = serde_json::json!({
            "rules": {
                "dangerous-rm": {
                    "enabled": false
                }
            },
            "customRules": [{
                "id": "no-secrets",
                "type": "path",
                "tier": "custom",
                "severity": "block",
                "protectedPaths": ["**/.env", "**/secrets/**"]
            }],
            "audit": {
                "enabled": true,
                "maxEntries": 500
            }
        });

        let g: GuardrailSettings = serde_json::from_value(json).unwrap();
        assert!(g.rules.is_some());
        let rules = g.rules.unwrap();
        assert!(rules.contains_key("dangerous-rm"));
        assert_eq!(rules["dangerous-rm"].enabled, Some(false));

        assert!(g.custom_rules.is_some());
        let custom = g.custom_rules.unwrap();
        assert_eq!(custom.len(), 1);
        assert_eq!(custom[0].id, "no-secrets");
        assert_eq!(custom[0].rule_type, GuardrailRuleType::Path);

        assert!(g.audit.is_some());
        assert_eq!(g.audit.unwrap().max_entries, 500);
    }

    #[test]
    fn guardrail_audit_defaults() {
        let a = GuardrailAuditSettings::default();
        assert!(a.enabled);
        assert_eq!(a.max_entries, 1000);
    }

    #[test]
    fn rule_override_with_extra_fields() {
        let json = serde_json::json!({
            "enabled": true,
            "customThreshold": 42,
            "description": "test rule"
        });

        let o: GuardrailRuleOverride = serde_json::from_value(json).unwrap();
        assert_eq!(o.enabled, Some(true));
        assert_eq!(o.extra["customThreshold"], 42);
        assert_eq!(o.extra["description"], "test rule");
    }
}
