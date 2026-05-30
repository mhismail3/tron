use super::*;

#[test]
fn pattern_rm_rf_root_blocked() {
    let mut engine = default_engine();
    let eval = engine.evaluate(&make_process_ctx("rm -rf /"));
    assert!(eval.blocked);
    assert!(
        eval.triggered_rules
            .iter()
            .any(|r| r.rule_id == "core.destructive-commands")
    );
}

#[test]
fn pattern_sudo_rm_rf_root_blocked() {
    let mut engine = default_engine();
    let eval = engine.evaluate(&make_process_ctx("sudo rm -rf /"));
    assert!(eval.blocked);
}

#[test]
fn pattern_rm_rf_star_blocked() {
    let mut engine = default_engine();
    let eval = engine.evaluate(&make_process_ctx("rm -rf /*"));
    assert!(eval.blocked);
}

#[test]
fn pattern_fork_bomb_blocked() {
    let mut engine = default_engine();
    let eval = engine.evaluate(&make_process_ctx(":(){ :|: & };:"));
    assert!(eval.blocked);
}

#[test]
fn pattern_dd_to_device_blocked() {
    let mut engine = default_engine();
    let eval = engine.evaluate(&make_process_ctx("dd if=/dev/zero of=/dev/sda"));
    assert!(eval.blocked);
}

#[test]
fn pattern_write_to_device_blocked() {
    let mut engine = default_engine();
    let eval = engine.evaluate(&make_process_ctx("> /dev/sda"));
    assert!(eval.blocked);
}

#[test]
fn pattern_mkfs_blocked() {
    let mut engine = default_engine();
    let eval = engine.evaluate(&make_process_ctx("mkfs.ext4 /dev/sda1"));
    assert!(eval.blocked);
}

#[test]
fn pattern_chmod_777_root_blocked() {
    let mut engine = default_engine();
    let eval = engine.evaluate(&make_process_ctx("chmod 777 /"));
    assert!(eval.blocked);
}

#[test]
fn pattern_sudo_rm_usr_blocked() {
    let mut engine = default_engine();
    let eval = engine.evaluate(&make_process_ctx("sudo rm -rf /usr"));
    assert!(eval.blocked);
}

#[test]
fn pattern_safe_rm_not_blocked() {
    let mut engine = default_engine();
    let eval = engine.evaluate(&make_process_ctx("rm file.txt"));
    assert!(!eval.blocked);
}

#[test]
fn pattern_safe_ls_not_blocked() {
    let mut engine = default_engine();
    let eval = engine.evaluate(&make_process_ctx("ls -la"));
    assert!(!eval.blocked);
}

#[test]
fn pattern_git_push_not_blocked() {
    let mut engine = default_engine();
    let eval = engine.evaluate(&make_process_ctx("git push origin main"));
    assert!(!eval.blocked);
}

#[test]
fn pattern_tron_delete_blocked() {
    let mut engine = default_engine();
    let eval = engine.evaluate(&make_process_ctx("rm -rf ~/.tron/skills/test"));
    assert!(eval.blocked);
    assert!(
        eval.triggered_rules
            .iter()
            .any(|r| r.rule_id == "core.tron-no-delete")
    );
}

#[test]
fn pattern_trash_tron_blocked() {
    let mut engine = default_engine();
    let eval = engine.evaluate(&make_process_ctx("trash ~/.tron/old-file"));
    assert!(eval.blocked);
}

#[test]
fn pattern_target_argument_missing_not_triggered() {
    let ctx = EvaluationContext {
        model_primitive_name: "process::run".into(),
        capability_arguments: serde_json::json!({"timeout": 5000}),
        session_id: None,
        invocation_id: None,
    };
    let mut engine = default_engine();
    let eval = engine.evaluate(&ctx);
    assert!(
        !eval
            .triggered_rules
            .iter()
            .any(|r| r.rule_id == "core.destructive-commands")
    );
}

#[test]
fn path_write_to_tron_home_blocked() {
    let home = crate::shared::paths::home_dir();
    let mut engine = default_engine();
    let eval = engine.evaluate(&make_write_ctx(&format!(
        "{home}/.tron/profiles/user/profile.toml"
    )));
    assert!(eval.blocked);
    assert!(
        eval.triggered_rules
            .iter()
            .any(|r| r.rule_id == "core.tron-home-protection")
    );
}

#[test]
fn path_edit_tron_home_db_blocked() {
    let home = crate::shared::paths::home_dir();
    let mut engine = default_engine();
    let eval = engine.evaluate(&make_edit_ctx(&format!(
        "{home}/.tron/internal/{}/prod.db",
        crate::shared::paths::dirs::DB
    )));
    assert!(eval.blocked);
    assert!(
        eval.triggered_rules
            .iter()
            .any(|r| r.rule_id == "core.tron-home-protection")
    );
}

#[test]
fn path_write_tron_home_auth_blocked() {
    let home = crate::shared::paths::home_dir();
    let mut engine = default_engine();
    let eval = engine.evaluate(&make_write_ctx(&format!("{home}/.tron/profiles/auth.json")));
    assert!(eval.blocked);
    assert!(
        eval.triggered_rules
            .iter()
            .any(|r| r.rule_id == "core.tron-home-protection")
    );
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
    assert!(
        eval.triggered_rules
            .iter()
            .any(|r| r.rule_id == "path.traversal")
    );
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
    let eval = engine.evaluate(&make_process_ctx("mkdir .hidden"));
    assert!(eval.blocked);
    assert!(
        eval.triggered_rules
            .iter()
            .any(|r| r.rule_id == "path.hidden-mkdir")
    );
}

#[test]
fn path_hidden_mkdir_p_blocked() {
    let mut engine = default_engine();
    let eval = engine.evaluate(&make_process_ctx("mkdir -p /tmp/.secret"));
    assert!(eval.blocked);
}

#[test]
fn path_normal_mkdir_not_blocked() {
    let mut engine = default_engine();
    let eval = engine.evaluate(&make_process_ctx("mkdir new_directory"));
    assert!(!eval.blocked);
}

#[test]
fn path_process_tee_to_tron_home_blocked() {
    let home = crate::shared::paths::home_dir();
    let mut engine = default_engine();
    let cmd = format!("echo test | tee {home}/.tron/profiles/user/profile.toml");
    let eval = engine.evaluate(&make_process_ctx(&cmd));
    assert!(eval.blocked);
}

#[test]
fn path_process_cp_to_tron_home_db_blocked() {
    let home = crate::shared::paths::home_dir();
    let mut engine = default_engine();
    let cmd = format!(
        "cp foo.db {home}/.tron/internal/{}/prod.db",
        crate::shared::paths::dirs::DB
    );
    let eval = engine.evaluate(&make_process_ctx(&cmd));
    assert!(eval.blocked);
}

#[test]
fn path_process_redirect_to_tron_home_auth_blocked() {
    let home = crate::shared::paths::home_dir();
    let mut engine = default_engine();
    let cmd = format!("echo '{{}}' > {home}/.tron/profiles/auth.json");
    let eval = engine.evaluate(&make_process_ctx(&cmd));
    assert!(eval.blocked);
}

#[test]
fn resource_timeout_exceeds_max_blocked() {
    let ctx = EvaluationContext {
        model_primitive_name: "process::run".into(),
        capability_arguments: serde_json::json!({"command": "sleep 1000", "timeout": 4_000_000}),
        session_id: None,
        invocation_id: None,
    };
    let mut engine = default_engine();
    let eval = engine.evaluate(&ctx);
    assert!(eval.blocked);
    assert!(
        eval.triggered_rules
            .iter()
            .any(|r| r.rule_id == "process.timeout")
    );
}

#[test]
fn resource_timeout_above_600s_warns_but_not_blocked() {
    let ctx = EvaluationContext {
        model_primitive_name: "process::run".into(),
        capability_arguments: serde_json::json!({"command": "build", "timeout": 900_000}),
        session_id: None,
        invocation_id: None,
    };
    let mut engine = default_engine();
    let eval = engine.evaluate(&ctx);
    assert!(!eval.blocked, "900s should not be blocked (max is 3600s)");
    assert!(eval.has_warnings, "900s should trigger a warning");
    assert!(
        eval.triggered_rules
            .iter()
            .any(|r| r.rule_id == "process.long-timeout"),
        "process.long-timeout warning should fire"
    );
}

#[test]
fn resource_timeout_within_limit_not_blocked() {
    let ctx = EvaluationContext {
        model_primitive_name: "process::run".into(),
        capability_arguments: serde_json::json!({"command": "sleep 5", "timeout": 500_000}),
        session_id: None,
        invocation_id: None,
    };
    let mut engine = default_engine();
    let eval = engine.evaluate(&ctx);
    assert!(
        !eval
            .triggered_rules
            .iter()
            .any(|r| r.rule_id == "process.timeout")
    );
}

#[test]
fn resource_timeout_exact_max_not_blocked() {
    let ctx = EvaluationContext {
        model_primitive_name: "process::run".into(),
        capability_arguments: serde_json::json!({"command": "sleep 5", "timeout": 600_000}),
        session_id: None,
        invocation_id: None,
    };
    let mut engine = default_engine();
    let eval = engine.evaluate(&ctx);
    assert!(
        !eval
            .triggered_rules
            .iter()
            .any(|r| r.rule_id == "process.timeout")
    );
}

#[test]
fn resource_missing_argument_not_triggered() {
    let ctx = EvaluationContext {
        model_primitive_name: "process::run".into(),
        capability_arguments: serde_json::json!({"command": "ls"}),
        session_id: None,
        invocation_id: None,
    };
    let mut engine = default_engine();
    let eval = engine.evaluate(&ctx);
    assert!(
        !eval
            .triggered_rules
            .iter()
            .any(|r| r.rule_id == "process.timeout")
    );
}

#[test]
fn resource_non_numeric_argument_not_triggered() {
    let ctx = EvaluationContext {
        model_primitive_name: "process::run".into(),
        capability_arguments: serde_json::json!({"command": "ls", "timeout": "not-a-number"}),
        session_id: None,
        invocation_id: None,
    };
    let mut engine = default_engine();
    let eval = engine.evaluate(&ctx);
    assert!(
        !eval
            .triggered_rules
            .iter()
            .any(|r| r.rule_id == "process.timeout")
    );
}

#[test]
fn resource_min_value_check() {
    let rule = ResourceRule {
        base: RuleBase {
            id: "test.min".into(),
            name: "Min Test".into(),
            description: "Test min value".into(),
            severity: Severity::Block,
            scope: Scope::ModelCapability,
            tier: RuleTier::Custom,
            capabilities: vec!["process::run".into()],
            priority: 100,
            enabled: true,
            tags: vec![],
        },
        target_argument: "value".into(),
        max_value: None,
        min_value: Some(10.0),
    };
    let ctx = EvaluationContext {
        model_primitive_name: "process::run".into(),
        capability_arguments: serde_json::json!({"value": 5}),
        session_id: None,
        invocation_id: None,
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
            scope: Scope::ModelCapability,
            tier: RuleTier::Custom,
            capabilities: vec![],
            priority: 100,
            enabled: true,
            tags: vec![],
        },
        target_argument: "count".into(),
        max_value: Some(100.0),
        min_value: Some(1.0),
    };

    let ctx = EvaluationContext {
        model_primitive_name: "Test".into(),
        capability_arguments: serde_json::json!({"count": 50}),
        session_id: None,
        invocation_id: None,
    };
    assert!(!rule.evaluate(&ctx).triggered);

    let ctx2 = EvaluationContext {
        model_primitive_name: "Test".into(),
        capability_arguments: serde_json::json!({"count": 150}),
        session_id: None,
        invocation_id: None,
    };
    assert!(rule.evaluate(&ctx2).triggered);

    let ctx3 = EvaluationContext {
        model_primitive_name: "Test".into(),
        capability_arguments: serde_json::json!({"count": 0}),
        session_id: None,
        invocation_id: None,
    };
    assert!(rule.evaluate(&ctx3).triggered);
}
