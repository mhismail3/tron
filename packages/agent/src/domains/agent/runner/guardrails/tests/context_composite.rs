use super::*;

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
            capabilities: vec![],
            priority: 100,
            enabled: true,
            tags: vec![],
        },
        condition: Box::new(|ctx| ctx.model_primitive_name == "DangerousCapability"),
        block_message: "DangerousCapability is not allowed".into(),
    };
    let ctx = EvaluationContext {
        model_primitive_name: "DangerousCapability".into(),
        capability_arguments: serde_json::json!({}),
        session_id: None,
        invocation_id: None,
    };
    let result = rule.evaluate(&ctx);
    assert!(result.triggered);
    assert_eq!(
        result.reason.as_deref(),
        Some("DangerousCapability is not allowed")
    );
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
            capabilities: vec![],
            priority: 100,
            enabled: true,
            tags: vec![],
        },
        condition: Box::new(|ctx| ctx.model_primitive_name == "DangerousCapability"),
        block_message: "not allowed".into(),
    };
    let ctx = EvaluationContext {
        model_primitive_name: "SafeCapability".into(),
        capability_arguments: serde_json::json!({}),
        session_id: None,
        invocation_id: None,
    };
    let result = rule.evaluate(&ctx);
    assert!(!result.triggered);
}

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
            capabilities: vec![],
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
            capabilities: vec![],
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
            capabilities: vec![],
            priority: 50,
            enabled: true,
            tags: vec![],
        },
        operator: CompositeOperator::And,
        child_rule_ids: vec!["child.a".into(), "child.b".into()],
    }));

    let ctx = make_process_ctx("test command");
    let eval = engine.evaluate(&ctx);
    assert!(
        eval.triggered_rules
            .iter()
            .any(|r| r.rule_id == "composite.and" && r.triggered)
    );
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
            capabilities: vec![],
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
            capabilities: vec![],
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
            capabilities: vec![],
            priority: 50,
            enabled: true,
            tags: vec![],
        },
        operator: CompositeOperator::And,
        child_rule_ids: vec!["child.a".into(), "child.b".into()],
    }));

    let ctx = make_process_ctx("test command");
    let eval = engine.evaluate(&ctx);
    assert!(
        !eval
            .triggered_rules
            .iter()
            .any(|r| r.rule_id == "composite.and")
    );
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
            capabilities: vec![],
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
            capabilities: vec![],
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
            capabilities: vec![],
            priority: 50,
            enabled: true,
            tags: vec![],
        },
        operator: CompositeOperator::Or,
        child_rule_ids: vec!["child.a".into(), "child.b".into()],
    }));

    let ctx = make_process_ctx("test command");
    let eval = engine.evaluate(&ctx);
    assert!(
        eval.triggered_rules
            .iter()
            .any(|r| r.rule_id == "composite.or" && r.triggered)
    );
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
            capabilities: vec![],
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
            capabilities: vec![],
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
            capabilities: vec![],
            priority: 50,
            enabled: true,
            tags: vec![],
        },
        operator: CompositeOperator::Or,
        child_rule_ids: vec!["child.a".into(), "child.b".into()],
    }));

    let ctx = make_process_ctx("safe command");
    let eval = engine.evaluate(&ctx);
    assert!(
        !eval
            .triggered_rules
            .iter()
            .any(|r| r.rule_id == "composite.or")
    );
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
            capabilities: vec![],
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
            capabilities: vec![],
            priority: 50,
            enabled: true,
            tags: vec![],
        },
        operator: CompositeOperator::Not,
        child_rule_ids: vec!["child.a".into()],
    }));

    let ctx = make_process_ctx("safe command");
    let eval = engine.evaluate(&ctx);
    assert!(
        eval.triggered_rules
            .iter()
            .any(|r| r.rule_id == "composite.not" && r.triggered)
    );
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
            capabilities: vec![],
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
            capabilities: vec![],
            priority: 50,
            enabled: true,
            tags: vec![],
        },
        operator: CompositeOperator::Not,
        child_rule_ids: vec!["child.a".into()],
    }));

    let ctx = make_process_ctx("test command");
    let eval = engine.evaluate(&ctx);
    assert!(
        !eval
            .triggered_rules
            .iter()
            .any(|r| r.rule_id == "composite.not")
    );
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
            capabilities: vec![],
            priority: 50,
            enabled: true,
            tags: vec![],
        },
        operator: CompositeOperator::And,
        child_rule_ids: vec!["nonexistent.rule".into()],
    }));

    let ctx = make_process_ctx("test");
    let eval = engine.evaluate(&ctx);
    assert!(
        !eval
            .triggered_rules
            .iter()
            .any(|r| r.rule_id == "composite.bad")
    );
}
