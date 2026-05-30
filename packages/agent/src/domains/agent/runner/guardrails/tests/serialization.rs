use super::*;

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
        (Scope::ModelCapability, "\"capability\""),
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
        model_primitive_name: "process::run".into(),
        capability_arguments: serde_json::json!({"command": "ls"}),
        session_id: Some("sess-1".into()),
        invocation_id: None,
    };
    let json = serde_json::to_string(&ctx).unwrap();
    let back: EvaluationContext = serde_json::from_str(&json).unwrap();
    assert_eq!(back.model_primitive_name, "process::run");
    assert_eq!(back.session_id, Some("sess-1".into()));
    assert_eq!(back.invocation_id, None);
}

#[test]
fn evaluation_context_omits_none_fields() {
    let ctx = EvaluationContext {
        model_primitive_name: "process::run".into(),
        capability_arguments: serde_json::json!({}),
        session_id: None,
        invocation_id: None,
    };
    let json = serde_json::to_string(&ctx).unwrap();
    assert!(!json.contains("sessionId"));
    assert!(!json.contains("invocationId"));
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
        model_primitive_name: "process::run".into(),
        invocation_id: None,
        evaluation: GuardrailEvaluation {
            blocked: false,
            block_reason: None,
            triggered_rules: vec![],
            has_warnings: false,
            warnings: vec![],
            timestamp: "2026-01-01T00:00:00Z".into(),
            duration_ms: 0,
        },
        capability_arguments: Some(serde_json::json!({"command": "ls"})),
    };
    let json = serde_json::to_string(&entry).unwrap();
    let back: AuditEntry = serde_json::from_str(&json).unwrap();
    assert_eq!(back.id, "audit-1");
    assert_eq!(back.model_primitive_name, "process::run");
}
