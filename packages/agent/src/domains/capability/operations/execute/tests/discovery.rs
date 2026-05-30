use super::support::*;

#[test]
fn discovery_only_intent_is_guidance_not_execution() {
    let input = parse_orchestrated_execute_input(&json!({
        "intent": "Discover module package registration required fields. Do not execute mutations.",
        "reason": "RWO discovery only"
    }))
    .expect("input");

    assert!(input.discovery_only());
    assert_eq!(input.operation, None);
    assert!(!orchestration_status_is_error("capability_discovery"));
    assert!(!orchestration_status_is_error("needs_selection"));
    assert!(!orchestration_status_is_error("needs_input"));
    assert!(!orchestration_status_is_error("needs_capability"));
    assert!(orchestration_status_is_error("request_invalid"));
    assert!(orchestration_status_is_error("target_policy_rejected"));
}

#[test]
fn explicit_execute_operation_controls_discovery_inference() {
    let discover = parse_orchestrated_execute_input(&json!({
        "operation": "discover",
        "intent": "module package registration",
        "arguments": {}
    }))
    .expect("discover input");
    assert!(discover.discovery_only());

    let run = parse_orchestrated_execute_input(&json!({
        "operation": "run",
        "intent": "Discover README.md by reading it",
        "arguments": {}
    }))
    .expect("run input");
    assert!(!run.discovery_only());

    let invalid = parse_orchestrated_execute_input(&json!({
        "operation": "unsupported-probe",
        "intent": "read README.md"
    }))
    .expect_err("invalid operation");
    assert!(invalid.to_string().contains("execute.operation"));
}

#[test]
fn safety_constraints_do_not_make_pure_read_targets_discovery_only() {
    let input = parse_orchestrated_execute_input(&json!({
        "intent": "Get recent server/event/log counts from a pure-read observability metrics snapshot. Do not mutate anything and do not use shell/process.",
        "target": "observability::metrics_snapshot",
        "arguments": {},
        "constraints": {"effect": "pure_read"}
    }))
    .expect("input");

    assert!(!input.discovery_only());
}

#[test]
fn nested_target_arguments_preserve_target_owned_mode_field() {
    let input = parse_orchestrated_execute_input(&json!({
        "target": "module::check_health",
        "operation": "run",
        "arguments": {
            "activationResourceId": "activation:system:demo-tools",
            "activationVersionId": "ver_demo",
            "expectedCurrentVersionId": "ver_demo",
            "mode": "on_demand"
        },
        "idempotencyKey": "module-health-demo"
    }))
    .expect("input");

    assert_eq!(
        input.arguments["mode"],
        json!("on_demand"),
        "execute must not strip target-owned fields that happen to share wrapper names"
    );
    assert!(
        input
            .corrections
            .iter()
            .all(|correction| { correction["kind"] != json!("nested_wrapper_field_removed") })
    );
}

#[test]
fn current_status_discovery_wording_still_runs_pure_read_target() {
    let input = parse_orchestrated_execute_input(&json!({
        "intent": "Discover current model/provider status.",
        "target": "model::list",
        "arguments": {},
        "constraints": {"effect": "pure_read"}
    }))
    .expect("input");

    assert!(!input.discovery_only());
}

#[test]
fn resource_inventory_discovery_runs_pure_read_instead_of_schema_only() {
    let mut input = parse_orchestrated_execute_input(&json!({
        "operation": "discover",
        "intent": "Discover whether current engine has existing module_package resources.",
        "arguments": {}
    }))
    .expect("discover input");
    assert!(input.discovery_only());

    normalize_live_resource_inventory_operation(&mut input);

    assert_eq!(input.operation.as_deref(), Some("run"));
    assert!(!input.discovery_only());
    assert!(input.corrections.iter().any(|correction| {
        correction["kind"] == json!("resource_inventory_discovery_to_read_only_run")
    }));
}

#[test]
fn resource_inventory_required_fields_remains_discovery_only() {
    let mut input = parse_orchestrated_execute_input(&json!({
        "operation": "discover",
        "intent": "Discover module package registration required fields. Do not execute mutations.",
        "arguments": {}
    }))
    .expect("discover input");

    normalize_live_resource_inventory_operation(&mut input);

    assert_eq!(input.operation.as_deref(), Some("discover"));
    assert!(input.discovery_only());
    assert!(input.corrections.iter().all(|correction| {
        correction["kind"] != json!("resource_inventory_discovery_to_read_only_run")
    }));
}
