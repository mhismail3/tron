use super::*;

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
        model_primitive_name: "UnknownCapability".into(),
        capability_arguments: serde_json::json!({}),
        session_id: None,
        invocation_id: None,
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
            capabilities: vec![],
            priority: 100,
            enabled: true,
            tags: vec![],
        },
        target_argument: "command".into(),
        patterns: vec![regex::Regex::new("warn-trigger").unwrap()],
    }));

    let eval = engine.evaluate(&make_process_ctx("warn-trigger"));
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
            capabilities: vec![],
            priority: 100,
            enabled: true,
            tags: vec![],
        },
        target_argument: "command".into(),
        patterns: vec![regex::Regex::new("audit-trigger").unwrap()],
    }));

    let eval = engine.evaluate(&make_process_ctx("audit-trigger"));
    assert!(!eval.blocked);
    assert!(!eval.has_warnings);
    assert!(
        eval.triggered_rules
            .iter()
            .any(|r| r.rule_id == "test.audit" && r.triggered)
    );
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
            capabilities: vec!["Test".into()],
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
            capabilities: vec!["Test".into()],
            priority: 100,
            enabled: true,
            tags: vec![],
        },
        target_argument: "cmd".into(),
        patterns: vec![regex::Regex::new("match").unwrap()],
    }));

    let ctx = EvaluationContext {
        model_primitive_name: "Test".into(),
        capability_arguments: serde_json::json!({"cmd": "match"}),
        session_id: None,
        invocation_id: None,
    };
    let eval = engine.evaluate(&ctx);
    assert!(eval.blocked);
    assert_eq!(eval.triggered_rules.len(), 2);
}

#[test]
fn engine_capability_filtering() {
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
            scope: Scope::ModelCapability,
            tier: RuleTier::Custom,
            capabilities: vec!["SpecialCapability".into()],
            priority: 100,
            enabled: true,
            tags: vec![],
        },
        target_argument: "input".into(),
        patterns: vec![regex::Regex::new(".*").unwrap()],
    }));

    let ctx = EvaluationContext {
        model_primitive_name: "process::run".into(),
        capability_arguments: serde_json::json!({"input": "anything"}),
        session_id: None,
        invocation_id: None,
    };
    let eval = engine.evaluate(&ctx);
    assert!(
        !eval
            .triggered_rules
            .iter()
            .any(|r| r.rule_id == "special.only")
    );

    let ctx2 = EvaluationContext {
        model_primitive_name: "SpecialCapability".into(),
        capability_arguments: serde_json::json!({"input": "anything"}),
        session_id: None,
        invocation_id: None,
    };
    let eval2 = engine.evaluate(&ctx2);
    assert!(
        eval2
            .triggered_rules
            .iter()
            .any(|r| r.rule_id == "special.only")
    );
}

#[test]
fn engine_disabled_rule_skipped() {
    let mut engine = GuardrailEngine::new(GuardrailEngineOptions {
        enable_audit: Some(false),
        rule_overrides: {
            let mut m = HashMap::new();
            let _ = m.insert(
                "path.traversal".into(),
                RuleOverride {
                    enabled: Some(false),
                },
            );
            m
        },
        ..Default::default()
    });

    let eval = engine.evaluate(&make_read_ctx("../../etc/passwd"));
    assert!(
        !eval
            .triggered_rules
            .iter()
            .any(|r| r.rule_id == "path.traversal")
    );
}

#[test]
fn engine_core_rule_cannot_be_disabled_by_override() {
    let mut engine = GuardrailEngine::new(GuardrailEngineOptions {
        enable_audit: Some(false),
        rule_overrides: {
            let mut m = HashMap::new();
            let _ = m.insert(
                "core.destructive-commands".into(),
                RuleOverride {
                    enabled: Some(false),
                },
            );
            m
        },
        ..Default::default()
    });

    assert!(engine.is_rule_enabled("core.destructive-commands"));
    let eval = engine.evaluate(&make_process_ctx("rm -rf /"));
    assert!(eval.blocked);
}

#[test]
fn engine_timing_populated() {
    let mut engine = default_engine();
    let eval = engine.evaluate(&make_process_ctx("ls"));
    assert!(eval.timestamp.contains('T'));
}

#[test]
fn engine_all_default_rules_registered() {
    let engine = default_engine();
    let rules = engine.get_rules();
    assert_eq!(rules.len(), 11);
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
            capabilities: vec![],
            priority: 1000,
            enabled: true,
            tags: vec![],
        },
        target_argument: "command".into(),
        patterns: vec![],
    }));
    assert_eq!(engine.get_rules().len(), count_before);
}

#[test]
fn audit_log_and_retrieve() {
    let mut logger = AuditLogger::new(None);
    let entry = logger.log(AuditEntryParams {
        session_id: Some("sess-1".into()),
        model_primitive_name: "process::run".into(),
        invocation_id: Some("call-1".into()),
        capability_arguments: Some(serde_json::json!({"command": "ls"})),
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
            model_primitive_name: format!("Capability{i}"),
            invocation_id: None,
            capability_arguments: None,
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
    assert_eq!(entries[0].model_primitive_name, "Capability2");
}

#[test]
fn audit_entries_for_session() {
    let mut logger = AuditLogger::new(None);
    for session in &["sess-1", "sess-2", "sess-1"] {
        let _ = logger.log(AuditEntryParams {
            session_id: Some((*session).to_string()),
            model_primitive_name: "process::run".into(),
            invocation_id: None,
            capability_arguments: None,
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
        model_primitive_name: "process::run".into(),
        invocation_id: None,
        capability_arguments: None,
        evaluation: GuardrailEvaluation {
            blocked: true,
            block_reason: Some("test".into()),
            triggered_rules: vec![RuleEvaluationResult::triggered(
                "rule-a",
                Severity::Block,
                "blocked",
            )],
            has_warnings: false,
            warnings: vec![],
            timestamp: "t".into(),
            duration_ms: 0,
        },
    });
    let _ = logger.log(AuditEntryParams {
        session_id: None,
        model_primitive_name: "filesystem::read_file".into(),
        invocation_id: None,
        capability_arguments: None,
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
        model_primitive_name: "process::run".into(),
        invocation_id: None,
        capability_arguments: None,
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
        model_primitive_name: "filesystem::read_file".into(),
        invocation_id: None,
        capability_arguments: None,
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
        model_primitive_name: "process::run".into(),
        invocation_id: None,
        capability_arguments: None,
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
        model_primitive_name: "process::run".into(),
        invocation_id: None,
        capability_arguments: None,
        evaluation: GuardrailEvaluation {
            blocked: true,
            block_reason: Some("test".into()),
            triggered_rules: vec![RuleEvaluationResult::triggered(
                "rule-a",
                Severity::Block,
                "blocked",
            )],
            has_warnings: false,
            warnings: vec![],
            timestamp: "t".into(),
            duration_ms: 0,
        },
    });
    let _ = logger.log(AuditEntryParams {
        session_id: None,
        model_primitive_name: "filesystem::write_file".into(),
        invocation_id: None,
        capability_arguments: None,
        evaluation: GuardrailEvaluation {
            blocked: false,
            block_reason: None,
            triggered_rules: vec![RuleEvaluationResult::triggered(
                "rule-b",
                Severity::Warn,
                "warned",
            )],
            has_warnings: true,
            warnings: vec!["test warning".into()],
            timestamp: "t".into(),
            duration_ms: 0,
        },
    });
    let _ = logger.log(AuditEntryParams {
        session_id: None,
        model_primitive_name: "process::run".into(),
        invocation_id: None,
        capability_arguments: None,
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
    assert_eq!(stats.by_capability.get("process::run"), Some(&2));
    assert_eq!(stats.by_capability.get("filesystem::write_file"), Some(&1));
    assert_eq!(stats.by_rule.get("rule-a"), Some(&1));
    assert_eq!(stats.by_rule.get("rule-b"), Some(&1));
}

#[test]
fn audit_redaction_in_logged_entry() {
    let mut engine = default_engine();
    let ctx = EvaluationContext {
        model_primitive_name: "process::run".into(),
        capability_arguments: serde_json::json!({
            "command": "ls",
            "password": "secret123",
            "apiToken": "tok-abc"
        }),
        session_id: Some("sess".into()),
        invocation_id: None,
    };
    let _ = engine.evaluate(&ctx);

    let audit = engine.audit_logger().unwrap();
    let entries = audit.entries(None);
    assert_eq!(entries.len(), 1);
    let args = entries[0].capability_arguments.as_ref().unwrap();
    assert_eq!(args["password"], "[REDACTED]");
    assert_eq!(args["apiToken"], "[REDACTED]");
    assert_eq!(args["command"], "ls");
}

#[test]
fn integration_safe_process_command() {
    let mut engine = default_engine();
    let eval = engine.evaluate(&make_process_ctx("cargo test --workspace"));
    assert!(!eval.blocked);
    assert!(!eval.has_warnings);
    assert!(eval.triggered_rules.is_empty());
}

#[test]
fn integration_dangerous_process_multiple_rules() {
    let mut engine = default_engine();
    let eval = engine.evaluate(&make_process_ctx("rm -rf ~/.tron"));
    assert!(eval.blocked);
    assert!(
        eval.triggered_rules
            .iter()
            .any(|r| r.rule_id == "core.tron-no-delete")
    );
}

#[test]
fn integration_write_to_safe_path() {
    let mut engine = default_engine();
    let eval = engine.evaluate(&make_write_ctx("/tmp/test-file.txt"));
    assert!(!eval.blocked);
}

#[test]
fn integration_write_to_tron_skills_allowed() {
    let home = crate::shared::paths::home_dir();
    let mut engine = default_engine();
    let eval = engine.evaluate(&make_write_ctx(&format!(
        "{home}/.tron/skills/test/SKILL.md"
    )));
    assert!(!eval.blocked);
}

#[test]
fn integration_read_capability_not_affected_by_path_protection() {
    let home = crate::shared::paths::home_dir();
    let mut engine = default_engine();
    let eval = engine.evaluate(&make_read_ctx(&format!(
        "{home}/.tron/internal/run/server.log"
    )));
    assert!(!eval.blocked);
}
