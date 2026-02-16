//! # tron-guardrails
//!
//! Synchronous rule engine that evaluates tool calls against safety rules
//! before execution. Three tiers: core (immutable, always active), standard
//! (can be disabled by settings), custom (user-defined). Five rule types:
//! pattern, path, resource, context, composite. Three severities: block
//! (stop execution), warn (log + continue), audit (silent log).
//!
//! ## Quick Start
//!
//! ```
//! use tron_guardrails::{GuardrailEngine, GuardrailEngineOptions, EvaluationContext};
//!
//! let mut engine = GuardrailEngine::new(GuardrailEngineOptions::default());
//! let ctx = EvaluationContext {
//!     tool_name: "Bash".into(),
//!     tool_arguments: serde_json::json!({"command": "ls -la"}),
//!     session_id: None,
//!     tool_call_id: None,
//! };
//! let result = engine.evaluate(&ctx);
//! assert!(!result.blocked);
//! ```

#![deny(unsafe_code)]

pub mod audit;
pub mod core_rules;
pub mod engine;
pub mod errors;
pub mod rules;
pub mod types;

// Re-export main public API
pub use audit::AuditLogger;
pub use core_rules::{default_rules, is_core_rule, CORE_RULE_IDS};
pub use engine::GuardrailEngine;
pub use errors::GuardrailError;
pub use rules::GuardrailRule;
pub use types::{
    AuditEntry, AuditEntryParams, AuditStats, EvaluationContext, GuardrailEngineOptions,
    GuardrailEvaluation, RuleEvaluationResult, RuleOverride, RuleTier, Scope, Severity,
};

#[cfg(test)]
mod tests {
    use super::*;
    use crate::rules::composite::{CompositeOperator, CompositeRule};
    use crate::rules::context::ContextRule;
    use crate::rules::pattern::PatternRule;
    use crate::rules::resource::ResourceRule;
    use crate::rules::RuleBase;
    use std::collections::HashMap;

    // =========================================================================
    // Helper functions
    // =========================================================================

    fn make_bash_ctx(command: &str) -> EvaluationContext {
        EvaluationContext {
            tool_name: "Bash".into(),
            tool_arguments: serde_json::json!({"command": command}),
            session_id: Some("test-session".into()),
            tool_call_id: Some("call-1".into()),
        }
    }

    fn make_write_ctx(file_path: &str) -> EvaluationContext {
        EvaluationContext {
            tool_name: "Write".into(),
            tool_arguments: serde_json::json!({"file_path": file_path, "content": "test"}),
            session_id: Some("test-session".into()),
            tool_call_id: Some("call-1".into()),
        }
    }

    fn make_edit_ctx(file_path: &str) -> EvaluationContext {
        EvaluationContext {
            tool_name: "Edit".into(),
            tool_arguments: serde_json::json!({"file_path": file_path}),
            session_id: None,
            tool_call_id: None,
        }
    }

    fn make_read_ctx(file_path: &str) -> EvaluationContext {
        EvaluationContext {
            tool_name: "Read".into(),
            tool_arguments: serde_json::json!({"file_path": file_path}),
            session_id: None,
            tool_call_id: None,
        }
    }

    fn default_engine() -> GuardrailEngine {
        GuardrailEngine::new(GuardrailEngineOptions::default())
    }

    // =========================================================================
    // types.rs tests
    // =========================================================================

    #[test]
    fn severity_serde_roundtrip() {
        for (variant, expected) in [
            (Severity::Block, "\"block\""),
            (Severity::Warn, "\"warn\""),
            (Severity::Audit, "\"audit\""),
        ] {
            let json = serde_json::to_string(&variant).unwrap();
            assert_eq!(json, expected);
            let back: Severity = serde_json::from_str(&json).unwrap();
            assert_eq!(back, variant);
        }
    }

    #[test]
    fn rule_tier_serde_roundtrip() {
        for (variant, expected) in [
            (RuleTier::Core, "\"core\""),
            (RuleTier::Standard, "\"standard\""),
            (RuleTier::Custom, "\"custom\""),
        ] {
            let json = serde_json::to_string(&variant).unwrap();
            assert_eq!(json, expected);
            let back: RuleTier = serde_json::from_str(&json).unwrap();
            assert_eq!(back, variant);
        }
    }

    #[test]
    fn scope_serde_roundtrip() {
        for (variant, expected) in [
            (Scope::Global, "\"global\""),
            (Scope::Tool, "\"tool\""),
        ] {
            let json = serde_json::to_string(&variant).unwrap();
            assert_eq!(json, expected);
            let back: Scope = serde_json::from_str(&json).unwrap();
            assert_eq!(back, variant);
        }
    }

    #[test]
    fn evaluation_context_serde_roundtrip() {
        let ctx = EvaluationContext {
            tool_name: "Bash".into(),
            tool_arguments: serde_json::json!({"command": "ls"}),
            session_id: Some("sess-1".into()),
            tool_call_id: None,
        };
        let json = serde_json::to_string(&ctx).unwrap();
        let back: EvaluationContext = serde_json::from_str(&json).unwrap();
        assert_eq!(back.tool_name, "Bash");
        assert_eq!(back.session_id, Some("sess-1".into()));
        assert_eq!(back.tool_call_id, None);
    }

    #[test]
    fn evaluation_context_omits_none_fields() {
        let ctx = EvaluationContext {
            tool_name: "Bash".into(),
            tool_arguments: serde_json::json!({}),
            session_id: None,
            tool_call_id: None,
        };
        let json = serde_json::to_string(&ctx).unwrap();
        assert!(!json.contains("sessionId"));
        assert!(!json.contains("toolCallId"));
    }

    #[test]
    fn rule_evaluation_result_not_triggered() {
        let r = RuleEvaluationResult::not_triggered("test-rule");
        assert!(!r.triggered);
        assert_eq!(r.rule_id, "test-rule");
        assert!(r.severity.is_none());
    }

    #[test]
    fn rule_evaluation_result_triggered() {
        let r = RuleEvaluationResult::triggered("test-rule", Severity::Block, "blocked!");
        assert!(r.triggered);
        assert_eq!(r.severity, Some(Severity::Block));
        assert_eq!(r.reason.as_deref(), Some("blocked!"));
    }

    #[test]
    fn rule_evaluation_result_with_details() {
        let r = RuleEvaluationResult::triggered("r", Severity::Warn, "w")
            .with_details(serde_json::json!({"key": "val"}));
        assert!(r.details.is_some());
        assert_eq!(r.details.unwrap()["key"], "val");
    }

    #[test]
    fn guardrail_evaluation_serde_roundtrip() {
        let eval = GuardrailEvaluation {
            blocked: true,
            block_reason: Some("test".into()),
            triggered_rules: vec![RuleEvaluationResult::triggered(
                "r",
                Severity::Block,
                "reason",
            )],
            has_warnings: false,
            warnings: vec![],
            timestamp: "2026-01-01T00:00:00Z".into(),
            duration_ms: 5,
        };
        let json = serde_json::to_string(&eval).unwrap();
        let back: GuardrailEvaluation = serde_json::from_str(&json).unwrap();
        assert!(back.blocked);
        assert_eq!(back.triggered_rules.len(), 1);
    }

    #[test]
    fn audit_entry_serde_roundtrip() {
        let entry = AuditEntry {
            id: "audit-1".into(),
            timestamp: "2026-01-01T00:00:00Z".into(),
            session_id: Some("sess-1".into()),
            tool_name: "Bash".into(),
            tool_call_id: None,
            evaluation: GuardrailEvaluation {
                blocked: false,
                block_reason: None,
                triggered_rules: vec![],
                has_warnings: false,
                warnings: vec![],
                timestamp: "2026-01-01T00:00:00Z".into(),
                duration_ms: 0,
            },
            tool_arguments: Some(serde_json::json!({"command": "ls"})),
        };
        let json = serde_json::to_string(&entry).unwrap();
        let back: AuditEntry = serde_json::from_str(&json).unwrap();
        assert_eq!(back.id, "audit-1");
        assert_eq!(back.tool_name, "Bash");
    }

    // =========================================================================
    // Pattern rule tests
    // =========================================================================

    #[test]
    fn pattern_rm_rf_root_blocked() {
        let mut engine = default_engine();
        let eval = engine.evaluate(&make_bash_ctx("rm -rf /"));
        assert!(eval.blocked);
        assert!(eval.triggered_rules.iter().any(|r| r.rule_id == "core.destructive-commands"));
    }

    #[test]
    fn pattern_sudo_rm_rf_root_blocked() {
        let mut engine = default_engine();
        let eval = engine.evaluate(&make_bash_ctx("sudo rm -rf /"));
        assert!(eval.blocked);
    }

    #[test]
    fn pattern_rm_rf_star_blocked() {
        let mut engine = default_engine();
        let eval = engine.evaluate(&make_bash_ctx("rm -rf /*"));
        assert!(eval.blocked);
    }

    #[test]
    fn pattern_fork_bomb_blocked() {
        let mut engine = default_engine();
        let eval = engine.evaluate(&make_bash_ctx(":(){ :|: & };:"));
        assert!(eval.blocked);
    }

    #[test]
    fn pattern_dd_to_device_blocked() {
        let mut engine = default_engine();
        let eval = engine.evaluate(&make_bash_ctx("dd if=/dev/zero of=/dev/sda"));
        assert!(eval.blocked);
    }

    #[test]
    fn pattern_write_to_device_blocked() {
        let mut engine = default_engine();
        let eval = engine.evaluate(&make_bash_ctx("> /dev/sda"));
        assert!(eval.blocked);
    }

    #[test]
    fn pattern_mkfs_blocked() {
        let mut engine = default_engine();
        let eval = engine.evaluate(&make_bash_ctx("mkfs.ext4 /dev/sda1"));
        assert!(eval.blocked);
    }

    #[test]
    fn pattern_chmod_777_root_blocked() {
        let mut engine = default_engine();
        let eval = engine.evaluate(&make_bash_ctx("chmod 777 /"));
        assert!(eval.blocked);
    }

    #[test]
    fn pattern_sudo_rm_usr_blocked() {
        let mut engine = default_engine();
        let eval = engine.evaluate(&make_bash_ctx("sudo rm -rf /usr"));
        assert!(eval.blocked);
    }

    #[test]
    fn pattern_safe_rm_not_blocked() {
        let mut engine = default_engine();
        let eval = engine.evaluate(&make_bash_ctx("rm file.txt"));
        assert!(!eval.blocked);
    }

    #[test]
    fn pattern_safe_ls_not_blocked() {
        let mut engine = default_engine();
        let eval = engine.evaluate(&make_bash_ctx("ls -la"));
        assert!(!eval.blocked);
    }

    #[test]
    fn pattern_git_push_not_blocked() {
        let mut engine = default_engine();
        let eval = engine.evaluate(&make_bash_ctx("git push origin main"));
        assert!(!eval.blocked);
    }

    #[test]
    fn pattern_tron_delete_blocked() {
        let mut engine = default_engine();
        let eval = engine.evaluate(&make_bash_ctx("rm -rf ~/.tron/skills/test"));
        assert!(eval.blocked);
        assert!(eval.triggered_rules.iter().any(|r| r.rule_id == "core.tron-no-delete"));
    }

    #[test]
    fn pattern_trash_tron_blocked() {
        let mut engine = default_engine();
        let eval = engine.evaluate(&make_bash_ctx("trash ~/.tron/old-file"));
        assert!(eval.blocked);
    }

    #[test]
    fn pattern_target_argument_missing_not_triggered() {
        let ctx = EvaluationContext {
            tool_name: "Bash".into(),
            tool_arguments: serde_json::json!({"timeout": 5000}),
            session_id: None,
            tool_call_id: None,
        };
        let mut engine = default_engine();
        let eval = engine.evaluate(&ctx);
        assert!(!eval.triggered_rules.iter().any(|r| r.rule_id == "core.destructive-commands"));
    }

    // =========================================================================
    // Path rule tests
    // =========================================================================

    #[test]
    fn path_write_to_tron_app_blocked() {
        let home = std::env::var("HOME").unwrap_or_else(|_| "/root".into());
        let mut engine = default_engine();
        let eval = engine.evaluate(&make_write_ctx(&format!("{home}/.tron/app/server.js")));
        assert!(eval.blocked);
        assert!(eval.triggered_rules.iter().any(|r| r.rule_id == "core.tron-app-protection"));
    }

    #[test]
    fn path_edit_tron_database_blocked() {
        let home = std::env::var("HOME").unwrap_or_else(|_| "/root".into());
        let mut engine = default_engine();
        let eval = engine.evaluate(&make_edit_ctx(&format!("{home}/.tron/database/prod.db")));
        assert!(eval.blocked);
        assert!(eval.triggered_rules.iter().any(|r| r.rule_id == "core.tron-db-protection"));
    }

    #[test]
    fn path_write_tron_auth_blocked() {
        let home = std::env::var("HOME").unwrap_or_else(|_| "/root".into());
        let mut engine = default_engine();
        let eval = engine.evaluate(&make_write_ctx(&format!("{home}/.tron/auth.json")));
        assert!(eval.blocked);
        assert!(eval.triggered_rules.iter().any(|r| r.rule_id == "core.tron-auth-protection"));
    }

    #[test]
    fn path_write_normal_file_not_blocked() {
        let mut engine = default_engine();
        let eval = engine.evaluate(&make_write_ctx("/tmp/test.txt"));
        assert!(!eval.blocked);
    }

    #[test]
    fn path_traversal_blocked() {
        let mut engine = default_engine();
        let eval = engine.evaluate(&make_read_ctx("../../etc/passwd"));
        assert!(eval.blocked);
        assert!(eval.triggered_rules.iter().any(|r| r.rule_id == "path.traversal"));
    }

    #[test]
    fn path_traversal_in_write_blocked() {
        let mut engine = default_engine();
        let eval = engine.evaluate(&make_write_ctx("/home/../../../etc/shadow"));
        assert!(eval.blocked);
    }

    #[test]
    fn path_no_traversal_not_blocked() {
        let mut engine = default_engine();
        let eval = engine.evaluate(&make_read_ctx("/home/user/file.txt"));
        assert!(!eval.blocked);
    }

    #[test]
    fn path_hidden_mkdir_blocked() {
        let mut engine = default_engine();
        let eval = engine.evaluate(&make_bash_ctx("mkdir .hidden"));
        assert!(eval.blocked);
        assert!(eval.triggered_rules.iter().any(|r| r.rule_id == "path.hidden-mkdir"));
    }

    #[test]
    fn path_hidden_mkdir_p_blocked() {
        let mut engine = default_engine();
        let eval = engine.evaluate(&make_bash_ctx("mkdir -p /tmp/.secret"));
        assert!(eval.blocked);
    }

    #[test]
    fn path_normal_mkdir_not_blocked() {
        let mut engine = default_engine();
        let eval = engine.evaluate(&make_bash_ctx("mkdir new_directory"));
        assert!(!eval.blocked);
    }

    #[test]
    fn path_bash_tee_to_tron_app_blocked() {
        let home = std::env::var("HOME").unwrap_or_else(|_| "/root".into());
        let mut engine = default_engine();
        let cmd = format!("echo test | tee {home}/.tron/app/file.txt");
        let eval = engine.evaluate(&make_bash_ctx(&cmd));
        assert!(eval.blocked);
    }

    #[test]
    fn path_bash_cp_to_tron_db_blocked() {
        let home = std::env::var("HOME").unwrap_or_else(|_| "/root".into());
        let mut engine = default_engine();
        let cmd = format!("cp foo.db {home}/.tron/database/prod.db");
        let eval = engine.evaluate(&make_bash_ctx(&cmd));
        assert!(eval.blocked);
    }

    #[test]
    fn path_bash_redirect_to_tron_auth_blocked() {
        let home = std::env::var("HOME").unwrap_or_else(|_| "/root".into());
        let mut engine = default_engine();
        let cmd = format!("echo '{{}}' > {home}/.tron/auth.json");
        let eval = engine.evaluate(&make_bash_ctx(&cmd));
        assert!(eval.blocked);
    }

    // =========================================================================
    // Resource rule tests
    // =========================================================================

    #[test]
    fn resource_timeout_exceeds_max_blocked() {
        let ctx = EvaluationContext {
            tool_name: "Bash".into(),
            tool_arguments: serde_json::json!({"command": "sleep 1000", "timeout": 700000}),
            session_id: None,
            tool_call_id: None,
        };
        let mut engine = default_engine();
        let eval = engine.evaluate(&ctx);
        assert!(eval.blocked);
        assert!(eval.triggered_rules.iter().any(|r| r.rule_id == "bash.timeout"));
    }

    #[test]
    fn resource_timeout_within_limit_not_blocked() {
        let ctx = EvaluationContext {
            tool_name: "Bash".into(),
            tool_arguments: serde_json::json!({"command": "sleep 5", "timeout": 500000}),
            session_id: None,
            tool_call_id: None,
        };
        let mut engine = default_engine();
        let eval = engine.evaluate(&ctx);
        assert!(!eval.triggered_rules.iter().any(|r| r.rule_id == "bash.timeout"));
    }

    #[test]
    fn resource_timeout_exact_max_not_blocked() {
        let ctx = EvaluationContext {
            tool_name: "Bash".into(),
            tool_arguments: serde_json::json!({"command": "sleep 5", "timeout": 600000}),
            session_id: None,
            tool_call_id: None,
        };
        let mut engine = default_engine();
        let eval = engine.evaluate(&ctx);
        assert!(!eval.triggered_rules.iter().any(|r| r.rule_id == "bash.timeout"));
    }

    #[test]
    fn resource_missing_argument_not_triggered() {
        let ctx = EvaluationContext {
            tool_name: "Bash".into(),
            tool_arguments: serde_json::json!({"command": "ls"}),
            session_id: None,
            tool_call_id: None,
        };
        let mut engine = default_engine();
        let eval = engine.evaluate(&ctx);
        assert!(!eval.triggered_rules.iter().any(|r| r.rule_id == "bash.timeout"));
    }

    #[test]
    fn resource_non_numeric_argument_not_triggered() {
        let ctx = EvaluationContext {
            tool_name: "Bash".into(),
            tool_arguments: serde_json::json!({"command": "ls", "timeout": "not-a-number"}),
            session_id: None,
            tool_call_id: None,
        };
        let mut engine = default_engine();
        let eval = engine.evaluate(&ctx);
        assert!(!eval.triggered_rules.iter().any(|r| r.rule_id == "bash.timeout"));
    }

    #[test]
    fn resource_min_value_check() {
        let rule = ResourceRule {
            base: RuleBase {
                id: "test.min".into(),
                name: "Min Test".into(),
                description: "Test min value".into(),
                severity: Severity::Block,
                scope: Scope::Tool,
                tier: RuleTier::Custom,
                tools: vec!["Bash".into()],
                priority: 100,
                enabled: true,
                tags: vec![],
            },
            target_argument: "value".into(),
            max_value: None,
            min_value: Some(10.0),
        };
        let ctx = EvaluationContext {
            tool_name: "Bash".into(),
            tool_arguments: serde_json::json!({"value": 5}),
            session_id: None,
            tool_call_id: None,
        };
        let result = rule.evaluate(&ctx);
        assert!(result.triggered);
    }

    #[test]
    fn resource_both_min_max() {
        let rule = ResourceRule {
            base: RuleBase {
                id: "test.range".into(),
                name: "Range Test".into(),
                description: "Test range".into(),
                severity: Severity::Warn,
                scope: Scope::Tool,
                tier: RuleTier::Custom,
                tools: vec![],
                priority: 100,
                enabled: true,
                tags: vec![],
            },
            target_argument: "count".into(),
            max_value: Some(100.0),
            min_value: Some(1.0),
        };

        // Within range
        let ctx = EvaluationContext {
            tool_name: "Test".into(),
            tool_arguments: serde_json::json!({"count": 50}),
            session_id: None,
            tool_call_id: None,
        };
        assert!(!rule.evaluate(&ctx).triggered);

        // Above max
        let ctx2 = EvaluationContext {
            tool_name: "Test".into(),
            tool_arguments: serde_json::json!({"count": 150}),
            session_id: None,
            tool_call_id: None,
        };
        assert!(rule.evaluate(&ctx2).triggered);

        // Below min
        let ctx3 = EvaluationContext {
            tool_name: "Test".into(),
            tool_arguments: serde_json::json!({"count": 0}),
            session_id: None,
            tool_call_id: None,
        };
        assert!(rule.evaluate(&ctx3).triggered);
    }

    // =========================================================================
    // Context rule tests
    // =========================================================================

    #[test]
    fn context_rule_condition_true_triggers() {
        let rule = ContextRule {
            base: RuleBase {
                id: "test.context".into(),
                name: "Context Test".into(),
                description: "Test context".into(),
                severity: Severity::Block,
                scope: Scope::Global,
                tier: RuleTier::Custom,
                tools: vec![],
                priority: 100,
                enabled: true,
                tags: vec![],
            },
            condition: Box::new(|ctx| ctx.tool_name == "DangerousTool"),
            block_message: "DangerousTool is not allowed".into(),
        };
        let ctx = EvaluationContext {
            tool_name: "DangerousTool".into(),
            tool_arguments: serde_json::json!({}),
            session_id: None,
            tool_call_id: None,
        };
        let result = rule.evaluate(&ctx);
        assert!(result.triggered);
        assert_eq!(result.reason.as_deref(), Some("DangerousTool is not allowed"));
    }

    #[test]
    fn context_rule_condition_false_not_triggered() {
        let rule = ContextRule {
            base: RuleBase {
                id: "test.context".into(),
                name: "Context Test".into(),
                description: "Test context".into(),
                severity: Severity::Block,
                scope: Scope::Global,
                tier: RuleTier::Custom,
                tools: vec![],
                priority: 100,
                enabled: true,
                tags: vec![],
            },
            condition: Box::new(|ctx| ctx.tool_name == "DangerousTool"),
            block_message: "not allowed".into(),
        };
        let ctx = EvaluationContext {
            tool_name: "SafeTool".into(),
            tool_arguments: serde_json::json!({}),
            session_id: None,
            tool_call_id: None,
        };
        let result = rule.evaluate(&ctx);
        assert!(!result.triggered);
    }

    // =========================================================================
    // Composite rule tests
    // =========================================================================

    #[test]
    fn composite_and_all_triggered() {
        let mut engine = GuardrailEngine::new(GuardrailEngineOptions {
            enable_audit: Some(false),
            ..Default::default()
        });
        engine.register_rule(GuardrailRule::Pattern(PatternRule {
            base: RuleBase {
                id: "child.a".into(),
                name: "Child A".into(),
                description: "test".into(),
                severity: Severity::Audit,
                scope: Scope::Global,
                tier: RuleTier::Custom,
                tools: vec![],
                priority: 100,
                enabled: true,
                tags: vec![],
            },
            target_argument: "command".into(),
            patterns: vec![regex::Regex::new("test").unwrap()],
        }));
        engine.register_rule(GuardrailRule::Pattern(PatternRule {
            base: RuleBase {
                id: "child.b".into(),
                name: "Child B".into(),
                description: "test".into(),
                severity: Severity::Audit,
                scope: Scope::Global,
                tier: RuleTier::Custom,
                tools: vec![],
                priority: 100,
                enabled: true,
                tags: vec![],
            },
            target_argument: "command".into(),
            patterns: vec![regex::Regex::new("test").unwrap()],
        }));
        engine.register_rule(GuardrailRule::Composite(CompositeRule {
            base: RuleBase {
                id: "composite.and".into(),
                name: "AND Composite".into(),
                description: "test".into(),
                severity: Severity::Block,
                scope: Scope::Global,
                tier: RuleTier::Custom,
                tools: vec![],
                priority: 50,
                enabled: true,
                tags: vec![],
            },
            operator: CompositeOperator::And,
            child_rule_ids: vec!["child.a".into(), "child.b".into()],
        }));

        let ctx = make_bash_ctx("test command");
        let eval = engine.evaluate(&ctx);
        assert!(eval.triggered_rules.iter().any(|r| r.rule_id == "composite.and" && r.triggered));
    }

    #[test]
    fn composite_and_partial_not_triggered() {
        let mut engine = GuardrailEngine::new(GuardrailEngineOptions {
            enable_audit: Some(false),
            ..Default::default()
        });
        engine.register_rule(GuardrailRule::Pattern(PatternRule {
            base: RuleBase {
                id: "child.a".into(),
                name: "Child A".into(),
                description: "test".into(),
                severity: Severity::Audit,
                scope: Scope::Global,
                tier: RuleTier::Custom,
                tools: vec![],
                priority: 100,
                enabled: true,
                tags: vec![],
            },
            target_argument: "command".into(),
            patterns: vec![regex::Regex::new("test").unwrap()],
        }));
        engine.register_rule(GuardrailRule::Pattern(PatternRule {
            base: RuleBase {
                id: "child.b".into(),
                name: "Child B".into(),
                description: "test".into(),
                severity: Severity::Audit,
                scope: Scope::Global,
                tier: RuleTier::Custom,
                tools: vec![],
                priority: 100,
                enabled: true,
                tags: vec![],
            },
            target_argument: "command".into(),
            patterns: vec![regex::Regex::new("nomatch").unwrap()],
        }));
        engine.register_rule(GuardrailRule::Composite(CompositeRule {
            base: RuleBase {
                id: "composite.and".into(),
                name: "AND Composite".into(),
                description: "test".into(),
                severity: Severity::Block,
                scope: Scope::Global,
                tier: RuleTier::Custom,
                tools: vec![],
                priority: 50,
                enabled: true,
                tags: vec![],
            },
            operator: CompositeOperator::And,
            child_rule_ids: vec!["child.a".into(), "child.b".into()],
        }));

        let ctx = make_bash_ctx("test command");
        let eval = engine.evaluate(&ctx);
        assert!(!eval.triggered_rules.iter().any(|r| r.rule_id == "composite.and"));
    }

    #[test]
    fn composite_or_any_triggers() {
        let mut engine = GuardrailEngine::new(GuardrailEngineOptions {
            enable_audit: Some(false),
            ..Default::default()
        });
        engine.register_rule(GuardrailRule::Pattern(PatternRule {
            base: RuleBase {
                id: "child.a".into(),
                name: "Child A".into(),
                description: "test".into(),
                severity: Severity::Audit,
                scope: Scope::Global,
                tier: RuleTier::Custom,
                tools: vec![],
                priority: 100,
                enabled: true,
                tags: vec![],
            },
            target_argument: "command".into(),
            patterns: vec![regex::Regex::new("nomatch").unwrap()],
        }));
        engine.register_rule(GuardrailRule::Pattern(PatternRule {
            base: RuleBase {
                id: "child.b".into(),
                name: "Child B".into(),
                description: "test".into(),
                severity: Severity::Audit,
                scope: Scope::Global,
                tier: RuleTier::Custom,
                tools: vec![],
                priority: 100,
                enabled: true,
                tags: vec![],
            },
            target_argument: "command".into(),
            patterns: vec![regex::Regex::new("test").unwrap()],
        }));
        engine.register_rule(GuardrailRule::Composite(CompositeRule {
            base: RuleBase {
                id: "composite.or".into(),
                name: "OR Composite".into(),
                description: "test".into(),
                severity: Severity::Warn,
                scope: Scope::Global,
                tier: RuleTier::Custom,
                tools: vec![],
                priority: 50,
                enabled: true,
                tags: vec![],
            },
            operator: CompositeOperator::Or,
            child_rule_ids: vec!["child.a".into(), "child.b".into()],
        }));

        let ctx = make_bash_ctx("test command");
        let eval = engine.evaluate(&ctx);
        assert!(eval.triggered_rules.iter().any(|r| r.rule_id == "composite.or" && r.triggered));
    }

    #[test]
    fn composite_or_none_not_triggered() {
        let mut engine = GuardrailEngine::new(GuardrailEngineOptions {
            enable_audit: Some(false),
            ..Default::default()
        });
        engine.register_rule(GuardrailRule::Pattern(PatternRule {
            base: RuleBase {
                id: "child.a".into(),
                name: "Child A".into(),
                description: "test".into(),
                severity: Severity::Audit,
                scope: Scope::Global,
                tier: RuleTier::Custom,
                tools: vec![],
                priority: 100,
                enabled: true,
                tags: vec![],
            },
            target_argument: "command".into(),
            patterns: vec![regex::Regex::new("nomatch1").unwrap()],
        }));
        engine.register_rule(GuardrailRule::Pattern(PatternRule {
            base: RuleBase {
                id: "child.b".into(),
                name: "Child B".into(),
                description: "test".into(),
                severity: Severity::Audit,
                scope: Scope::Global,
                tier: RuleTier::Custom,
                tools: vec![],
                priority: 100,
                enabled: true,
                tags: vec![],
            },
            target_argument: "command".into(),
            patterns: vec![regex::Regex::new("nomatch2").unwrap()],
        }));
        engine.register_rule(GuardrailRule::Composite(CompositeRule {
            base: RuleBase {
                id: "composite.or".into(),
                name: "OR Composite".into(),
                description: "test".into(),
                severity: Severity::Warn,
                scope: Scope::Global,
                tier: RuleTier::Custom,
                tools: vec![],
                priority: 50,
                enabled: true,
                tags: vec![],
            },
            operator: CompositeOperator::Or,
            child_rule_ids: vec!["child.a".into(), "child.b".into()],
        }));

        let ctx = make_bash_ctx("safe command");
        let eval = engine.evaluate(&ctx);
        assert!(!eval.triggered_rules.iter().any(|r| r.rule_id == "composite.or"));
    }

    #[test]
    fn composite_not_triggered_when_child_not_triggered() {
        let mut engine = GuardrailEngine::new(GuardrailEngineOptions {
            enable_audit: Some(false),
            ..Default::default()
        });
        engine.register_rule(GuardrailRule::Pattern(PatternRule {
            base: RuleBase {
                id: "child.a".into(),
                name: "Child A".into(),
                description: "test".into(),
                severity: Severity::Audit,
                scope: Scope::Global,
                tier: RuleTier::Custom,
                tools: vec![],
                priority: 100,
                enabled: true,
                tags: vec![],
            },
            target_argument: "command".into(),
            patterns: vec![regex::Regex::new("nomatch").unwrap()],
        }));
        engine.register_rule(GuardrailRule::Composite(CompositeRule {
            base: RuleBase {
                id: "composite.not".into(),
                name: "NOT Composite".into(),
                description: "test".into(),
                severity: Severity::Warn,
                scope: Scope::Global,
                tier: RuleTier::Custom,
                tools: vec![],
                priority: 50,
                enabled: true,
                tags: vec![],
            },
            operator: CompositeOperator::Not,
            child_rule_ids: vec!["child.a".into()],
        }));

        let ctx = make_bash_ctx("safe command");
        let eval = engine.evaluate(&ctx);
        assert!(eval.triggered_rules.iter().any(|r| r.rule_id == "composite.not" && r.triggered));
    }

    #[test]
    fn composite_not_not_triggered_when_child_triggered() {
        let mut engine = GuardrailEngine::new(GuardrailEngineOptions {
            enable_audit: Some(false),
            ..Default::default()
        });
        engine.register_rule(GuardrailRule::Pattern(PatternRule {
            base: RuleBase {
                id: "child.a".into(),
                name: "Child A".into(),
                description: "test".into(),
                severity: Severity::Audit,
                scope: Scope::Global,
                tier: RuleTier::Custom,
                tools: vec![],
                priority: 100,
                enabled: true,
                tags: vec![],
            },
            target_argument: "command".into(),
            patterns: vec![regex::Regex::new("test").unwrap()],
        }));
        engine.register_rule(GuardrailRule::Composite(CompositeRule {
            base: RuleBase {
                id: "composite.not".into(),
                name: "NOT Composite".into(),
                description: "test".into(),
                severity: Severity::Warn,
                scope: Scope::Global,
                tier: RuleTier::Custom,
                tools: vec![],
                priority: 50,
                enabled: true,
                tags: vec![],
            },
            operator: CompositeOperator::Not,
            child_rule_ids: vec!["child.a".into()],
        }));

        let ctx = make_bash_ctx("test command");
        let eval = engine.evaluate(&ctx);
        assert!(!eval.triggered_rules.iter().any(|r| r.rule_id == "composite.not"));
    }

    #[test]
    fn composite_unknown_child_handled() {
        let mut engine = GuardrailEngine::new(GuardrailEngineOptions {
            enable_audit: Some(false),
            ..Default::default()
        });
        engine.register_rule(GuardrailRule::Composite(CompositeRule {
            base: RuleBase {
                id: "composite.bad".into(),
                name: "Bad Composite".into(),
                description: "test".into(),
                severity: Severity::Block,
                scope: Scope::Global,
                tier: RuleTier::Custom,
                tools: vec![],
                priority: 50,
                enabled: true,
                tags: vec![],
            },
            operator: CompositeOperator::And,
            child_rule_ids: vec!["nonexistent.rule".into()],
        }));

        let ctx = make_bash_ctx("test");
        let eval = engine.evaluate(&ctx);
        assert!(!eval.triggered_rules.iter().any(|r| r.rule_id == "composite.bad"));
    }

    // =========================================================================
    // Engine tests
    // =========================================================================

    #[test]
    fn engine_register_and_get_rule() {
        let engine = default_engine();
        assert!(engine.get_rule("core.destructive-commands").is_some());
        assert!(engine.get_rule("nonexistent").is_none());
    }

    #[test]
    fn engine_unregister_standard_rule() {
        let mut engine = default_engine();
        assert!(engine.get_rule("path.traversal").is_some());
        assert!(engine.unregister_rule("path.traversal"));
        assert!(engine.get_rule("path.traversal").is_none());
    }

    #[test]
    fn engine_unregister_core_rule_fails() {
        let mut engine = default_engine();
        assert!(!engine.unregister_rule("core.destructive-commands"));
        assert!(engine.get_rule("core.destructive-commands").is_some());
    }

    #[test]
    fn engine_unregister_nonexistent_returns_false() {
        let mut engine = default_engine();
        assert!(!engine.unregister_rule("does.not.exist"));
    }

    #[test]
    fn engine_evaluate_no_applicable_rules_not_blocked() {
        let mut engine = default_engine();
        let ctx = EvaluationContext {
            tool_name: "UnknownTool".into(),
            tool_arguments: serde_json::json!({}),
            session_id: None,
            tool_call_id: None,
        };
        let eval = engine.evaluate(&ctx);
        assert!(!eval.blocked);
    }

    #[test]
    fn engine_warn_rule_not_blocked() {
        let mut engine = GuardrailEngine::new(GuardrailEngineOptions {
            enable_audit: Some(false),
            ..Default::default()
        });
        engine.register_rule(GuardrailRule::Pattern(PatternRule {
            base: RuleBase {
                id: "test.warn".into(),
                name: "Warn Test".into(),
                description: "test".into(),
                severity: Severity::Warn,
                scope: Scope::Global,
                tier: RuleTier::Custom,
                tools: vec![],
                priority: 100,
                enabled: true,
                tags: vec![],
            },
            target_argument: "command".into(),
            patterns: vec![regex::Regex::new("warn-trigger").unwrap()],
        }));

        let eval = engine.evaluate(&make_bash_ctx("warn-trigger"));
        assert!(!eval.blocked);
        assert!(eval.has_warnings);
        assert!(!eval.warnings.is_empty());
    }

    #[test]
    fn engine_audit_rule_silent() {
        let mut engine = GuardrailEngine::new(GuardrailEngineOptions {
            enable_audit: Some(false),
            ..Default::default()
        });
        engine.register_rule(GuardrailRule::Pattern(PatternRule {
            base: RuleBase {
                id: "test.audit".into(),
                name: "Audit Test".into(),
                description: "test".into(),
                severity: Severity::Audit,
                scope: Scope::Global,
                tier: RuleTier::Custom,
                tools: vec![],
                priority: 100,
                enabled: true,
                tags: vec![],
            },
            target_argument: "command".into(),
            patterns: vec![regex::Regex::new("audit-trigger").unwrap()],
        }));

        let eval = engine.evaluate(&make_bash_ctx("audit-trigger"));
        assert!(!eval.blocked);
        assert!(!eval.has_warnings);
        assert!(eval.triggered_rules.iter().any(|r| r.rule_id == "test.audit" && r.triggered));
    }

    #[test]
    fn engine_priority_ordering() {
        let mut engine = GuardrailEngine::new(GuardrailEngineOptions {
            enable_audit: Some(false),
            ..Default::default()
        });
        engine.register_rule(GuardrailRule::Pattern(PatternRule {
            base: RuleBase {
                id: "low.priority".into(),
                name: "Low".into(),
                description: "test".into(),
                severity: Severity::Audit,
                scope: Scope::Global,
                tier: RuleTier::Custom,
                tools: vec!["Test".into()],
                priority: 10,
                enabled: true,
                tags: vec![],
            },
            target_argument: "cmd".into(),
            patterns: vec![regex::Regex::new("match").unwrap()],
        }));
        engine.register_rule(GuardrailRule::Pattern(PatternRule {
            base: RuleBase {
                id: "high.priority".into(),
                name: "High".into(),
                description: "test".into(),
                severity: Severity::Block,
                scope: Scope::Global,
                tier: RuleTier::Custom,
                tools: vec!["Test".into()],
                priority: 100,
                enabled: true,
                tags: vec![],
            },
            target_argument: "cmd".into(),
            patterns: vec![regex::Regex::new("match").unwrap()],
        }));

        let ctx = EvaluationContext {
            tool_name: "Test".into(),
            tool_arguments: serde_json::json!({"cmd": "match"}),
            session_id: None,
            tool_call_id: None,
        };
        let eval = engine.evaluate(&ctx);
        assert!(eval.blocked);
        assert_eq!(eval.triggered_rules.len(), 2);
    }

    #[test]
    fn engine_tool_filtering() {
        let mut engine = GuardrailEngine::new(GuardrailEngineOptions {
            enable_audit: Some(false),
            ..Default::default()
        });
        engine.register_rule(GuardrailRule::Pattern(PatternRule {
            base: RuleBase {
                id: "special.only".into(),
                name: "Special Only".into(),
                description: "test".into(),
                severity: Severity::Block,
                scope: Scope::Tool,
                tier: RuleTier::Custom,
                tools: vec!["SpecialTool".into()],
                priority: 100,
                enabled: true,
                tags: vec![],
            },
            target_argument: "input".into(),
            patterns: vec![regex::Regex::new(".*").unwrap()],
        }));

        let ctx = EvaluationContext {
            tool_name: "Bash".into(),
            tool_arguments: serde_json::json!({"input": "anything"}),
            session_id: None,
            tool_call_id: None,
        };
        let eval = engine.evaluate(&ctx);
        assert!(!eval.triggered_rules.iter().any(|r| r.rule_id == "special.only"));

        let ctx2 = EvaluationContext {
            tool_name: "SpecialTool".into(),
            tool_arguments: serde_json::json!({"input": "anything"}),
            session_id: None,
            tool_call_id: None,
        };
        let eval2 = engine.evaluate(&ctx2);
        assert!(eval2.triggered_rules.iter().any(|r| r.rule_id == "special.only"));
    }

    #[test]
    fn engine_disabled_rule_skipped() {
        let mut engine = GuardrailEngine::new(GuardrailEngineOptions {
            enable_audit: Some(false),
            rule_overrides: {
                let mut m = HashMap::new();
                let _ = m.insert("path.traversal".into(), RuleOverride { enabled: Some(false) });
                m
            },
            ..Default::default()
        });

        let eval = engine.evaluate(&make_read_ctx("../../etc/passwd"));
        assert!(!eval.triggered_rules.iter().any(|r| r.rule_id == "path.traversal"));
    }

    #[test]
    fn engine_core_rule_cannot_be_disabled_by_override() {
        let mut engine = GuardrailEngine::new(GuardrailEngineOptions {
            enable_audit: Some(false),
            rule_overrides: {
                let mut m = HashMap::new();
                let _ = m.insert(
                    "core.destructive-commands".into(),
                    RuleOverride { enabled: Some(false) },
                );
                m
            },
            ..Default::default()
        });

        assert!(engine.is_rule_enabled("core.destructive-commands"));
        let eval = engine.evaluate(&make_bash_ctx("rm -rf /"));
        assert!(eval.blocked);
    }

    #[test]
    fn engine_timing_populated() {
        let mut engine = default_engine();
        let eval = engine.evaluate(&make_bash_ctx("ls"));
        assert!(eval.timestamp.contains('T'));
    }

    #[test]
    fn engine_all_default_rules_registered() {
        let engine = default_engine();
        let rules = engine.get_rules();
        assert_eq!(rules.len(), 9);
    }

    #[test]
    fn engine_is_rule_enabled_nonexistent() {
        let engine = default_engine();
        assert!(!engine.is_rule_enabled("does.not.exist"));
    }

    #[test]
    fn engine_prevent_non_core_as_core() {
        let mut engine = default_engine();
        let count_before = engine.get_rules().len();
        engine.register_rule(GuardrailRule::Pattern(PatternRule {
            base: RuleBase {
                id: "fake.core".into(),
                name: "Fake Core".into(),
                description: "test".into(),
                severity: Severity::Block,
                scope: Scope::Global,
                tier: RuleTier::Core,
                tools: vec![],
                priority: 1000,
                enabled: true,
                tags: vec![],
            },
            target_argument: "command".into(),
            patterns: vec![],
        }));
        assert_eq!(engine.get_rules().len(), count_before);
    }

    // =========================================================================
    // Audit logger tests
    // =========================================================================

    #[test]
    fn audit_log_and_retrieve() {
        let mut logger = AuditLogger::new(None);
        let entry = logger.log(AuditEntryParams {
            session_id: Some("sess-1".into()),
            tool_name: "Bash".into(),
            tool_call_id: Some("call-1".into()),
            tool_arguments: Some(serde_json::json!({"command": "ls"})),
            evaluation: GuardrailEvaluation {
                blocked: false,
                block_reason: None,
                triggered_rules: vec![],
                has_warnings: false,
                warnings: vec![],
                timestamp: "2026-01-01T00:00:00Z".into(),
                duration_ms: 1,
            },
        });
        assert_eq!(entry.id, "audit-1");
        assert_eq!(logger.len(), 1);
    }

    #[test]
    fn audit_capacity_enforcement() {
        let mut logger = AuditLogger::new(Some(3));
        for i in 0..5 {
            let _ = logger.log(AuditEntryParams {
                session_id: None,
                tool_name: format!("Tool{i}"),
                tool_call_id: None,
                tool_arguments: None,
                evaluation: GuardrailEvaluation {
                    blocked: false,
                    block_reason: None,
                    triggered_rules: vec![],
                    has_warnings: false,
                    warnings: vec![],
                    timestamp: "t".into(),
                    duration_ms: 0,
                },
            });
        }
        assert_eq!(logger.len(), 3);
        let entries = logger.entries(None);
        assert_eq!(entries[0].tool_name, "Tool2");
    }

    #[test]
    fn audit_entries_for_session() {
        let mut logger = AuditLogger::new(None);
        for session in &["sess-1", "sess-2", "sess-1"] {
            let _ = logger.log(AuditEntryParams {
                session_id: Some((*session).to_string()),
                tool_name: "Bash".into(),
                tool_call_id: None,
                tool_arguments: None,
                evaluation: GuardrailEvaluation {
                    blocked: false,
                    block_reason: None,
                    triggered_rules: vec![],
                    has_warnings: false,
                    warnings: vec![],
                    timestamp: "t".into(),
                    duration_ms: 0,
                },
            });
        }
        assert_eq!(logger.entries_for_session("sess-1", None).len(), 2);
        assert_eq!(logger.entries_for_session("sess-2", None).len(), 1);
        assert_eq!(logger.entries_for_session("sess-3", None).len(), 0);
    }

    #[test]
    fn audit_triggered_entries_filter() {
        let mut logger = AuditLogger::new(None);
        let _ = logger.log(AuditEntryParams {
            session_id: None,
            tool_name: "Bash".into(),
            tool_call_id: None,
            tool_arguments: None,
            evaluation: GuardrailEvaluation {
                blocked: true,
                block_reason: Some("test".into()),
                triggered_rules: vec![
                    RuleEvaluationResult::triggered("rule-a", Severity::Block, "blocked"),
                ],
                has_warnings: false,
                warnings: vec![],
                timestamp: "t".into(),
                duration_ms: 0,
            },
        });
        let _ = logger.log(AuditEntryParams {
            session_id: None,
            tool_name: "Read".into(),
            tool_call_id: None,
            tool_arguments: None,
            evaluation: GuardrailEvaluation {
                blocked: false,
                block_reason: None,
                triggered_rules: vec![],
                has_warnings: false,
                warnings: vec![],
                timestamp: "t".into(),
                duration_ms: 0,
            },
        });

        assert_eq!(logger.triggered_entries(None).len(), 1);
        assert_eq!(logger.triggered_entries(Some("rule-a")).len(), 1);
        assert_eq!(logger.triggered_entries(Some("rule-b")).len(), 0);
    }

    #[test]
    fn audit_blocked_entries_filter() {
        let mut logger = AuditLogger::new(None);
        let _ = logger.log(AuditEntryParams {
            session_id: None,
            tool_name: "Bash".into(),
            tool_call_id: None,
            tool_arguments: None,
            evaluation: GuardrailEvaluation {
                blocked: true,
                block_reason: Some("test".into()),
                triggered_rules: vec![],
                has_warnings: false,
                warnings: vec![],
                timestamp: "t".into(),
                duration_ms: 0,
            },
        });
        let _ = logger.log(AuditEntryParams {
            session_id: None,
            tool_name: "Read".into(),
            tool_call_id: None,
            tool_arguments: None,
            evaluation: GuardrailEvaluation {
                blocked: false,
                block_reason: None,
                triggered_rules: vec![],
                has_warnings: false,
                warnings: vec![],
                timestamp: "t".into(),
                duration_ms: 0,
            },
        });

        assert_eq!(logger.blocked_entries().len(), 1);
    }

    #[test]
    fn audit_clear() {
        let mut logger = AuditLogger::new(None);
        let _ = logger.log(AuditEntryParams {
            session_id: None,
            tool_name: "Bash".into(),
            tool_call_id: None,
            tool_arguments: None,
            evaluation: GuardrailEvaluation {
                blocked: false,
                block_reason: None,
                triggered_rules: vec![],
                has_warnings: false,
                warnings: vec![],
                timestamp: "t".into(),
                duration_ms: 0,
            },
        });
        assert_eq!(logger.len(), 1);
        logger.clear();
        assert_eq!(logger.len(), 0);
        assert!(logger.is_empty());
    }

    #[test]
    fn audit_stats() {
        let mut logger = AuditLogger::new(None);
        let _ = logger.log(AuditEntryParams {
            session_id: None,
            tool_name: "Bash".into(),
            tool_call_id: None,
            tool_arguments: None,
            evaluation: GuardrailEvaluation {
                blocked: true,
                block_reason: Some("test".into()),
                triggered_rules: vec![
                    RuleEvaluationResult::triggered("rule-a", Severity::Block, "blocked"),
                ],
                has_warnings: false,
                warnings: vec![],
                timestamp: "t".into(),
                duration_ms: 0,
            },
        });
        let _ = logger.log(AuditEntryParams {
            session_id: None,
            tool_name: "Write".into(),
            tool_call_id: None,
            tool_arguments: None,
            evaluation: GuardrailEvaluation {
                blocked: false,
                block_reason: None,
                triggered_rules: vec![
                    RuleEvaluationResult::triggered("rule-b", Severity::Warn, "warned"),
                ],
                has_warnings: true,
                warnings: vec!["test warning".into()],
                timestamp: "t".into(),
                duration_ms: 0,
            },
        });
        let _ = logger.log(AuditEntryParams {
            session_id: None,
            tool_name: "Bash".into(),
            tool_call_id: None,
            tool_arguments: None,
            evaluation: GuardrailEvaluation {
                blocked: false,
                block_reason: None,
                triggered_rules: vec![],
                has_warnings: false,
                warnings: vec![],
                timestamp: "t".into(),
                duration_ms: 0,
            },
        });

        let stats = logger.stats();
        assert_eq!(stats.total, 3);
        assert_eq!(stats.blocked, 1);
        assert_eq!(stats.warnings, 1);
        assert_eq!(stats.passed, 1);
        assert_eq!(stats.by_tool.get("Bash"), Some(&2));
        assert_eq!(stats.by_tool.get("Write"), Some(&1));
        assert_eq!(stats.by_rule.get("rule-a"), Some(&1));
        assert_eq!(stats.by_rule.get("rule-b"), Some(&1));
    }

    #[test]
    fn audit_redaction_in_logged_entry() {
        let mut engine = default_engine();
        let ctx = EvaluationContext {
            tool_name: "Bash".into(),
            tool_arguments: serde_json::json!({
                "command": "ls",
                "password": "secret123",
                "apiToken": "tok-abc"
            }),
            session_id: Some("sess".into()),
            tool_call_id: None,
        };
        let _ = engine.evaluate(&ctx);

        let audit = engine.audit_logger().unwrap();
        let entries = audit.entries(None);
        assert_eq!(entries.len(), 1);
        let args = entries[0].tool_arguments.as_ref().unwrap();
        assert_eq!(args["password"], "[REDACTED]");
        assert_eq!(args["apiToken"], "[REDACTED]");
        assert_eq!(args["command"], "ls");
    }

    // =========================================================================
    // Integration: full engine evaluation scenarios
    // =========================================================================

    #[test]
    fn integration_safe_bash_command() {
        let mut engine = default_engine();
        let eval = engine.evaluate(&make_bash_ctx("cargo test --workspace"));
        assert!(!eval.blocked);
        assert!(!eval.has_warnings);
        assert!(eval.triggered_rules.is_empty());
    }

    #[test]
    fn integration_dangerous_bash_multiple_rules() {
        let mut engine = default_engine();
        let eval = engine.evaluate(&make_bash_ctx("rm -rf ~/.tron"));
        assert!(eval.blocked);
        assert!(eval.triggered_rules.iter().any(|r| r.rule_id == "core.tron-no-delete"));
    }

    #[test]
    fn integration_write_to_safe_path() {
        let mut engine = default_engine();
        let eval = engine.evaluate(&make_write_ctx("/tmp/test-file.txt"));
        assert!(!eval.blocked);
    }

    #[test]
    fn integration_write_to_tron_skills_allowed() {
        let home = std::env::var("HOME").unwrap_or_else(|_| "/root".into());
        let mut engine = default_engine();
        let eval = engine.evaluate(&make_write_ctx(&format!("{home}/.tron/skills/test/SKILL.md")));
        assert!(!eval.blocked);
    }

    #[test]
    fn integration_read_tool_not_affected_by_path_protection() {
        let home = std::env::var("HOME").unwrap_or_else(|_| "/root".into());
        let mut engine = default_engine();
        let eval = engine.evaluate(&make_read_ctx(&format!("{home}/.tron/app/server.js")));
        assert!(!eval.blocked);
    }
}
