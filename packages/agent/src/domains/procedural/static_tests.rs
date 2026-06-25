use serde_json::json;
use std::path::Path;

use crate::engine::{PROCEDURAL_RECORD_KIND, PROCEDURAL_RECORD_SCHEMA_ID};

#[test]
fn procedural_record_resource_definition_is_registered_as_inert_metadata() {
    let definitions = crate::engine::builtin_resource_type_definitions();
    let definition = definitions
        .iter()
        .find(|definition| definition.kind == PROCEDURAL_RECORD_KIND)
        .expect("procedural record resource type");
    assert_eq!(definition.schema_id, PROCEDURAL_RECORD_SCHEMA_ID);
    assert_eq!(
        definition.lifecycle_states,
        vec![
            "draft".to_owned(),
            "candidate".to_owned(),
            "validated".to_owned(),
            "disabled".to_owned(),
            "stale".to_owned(),
            "archived".to_owned()
        ]
    );
    assert_eq!(
        definition.required_capabilities["read"],
        json!(["procedural.read", "resource.read"])
    );
    assert_eq!(
        definition.redaction_rules["activation"],
        json!("proof_only")
    );
}

#[test]
fn procedural_operations_are_read_only_execute_schema_values_without_activation_goals() {
    let metadata = crate::domains::capability::contract::model_metadata(
        crate::domains::capability::contract::EXECUTE_FUNCTION_ID,
    );
    let schema_text = metadata["capabilitySchema"]["parameters"].to_string();
    assert!(schema_text.contains("procedural_state_list"));
    assert!(schema_text.contains("procedural_state_inspect"));
    assert!(schema_text.contains("proceduralKind"));
    assert!(schema_text.contains("proceduralRecordResourceId"));
    for forbidden in [
        "procedural_state_create",
        "procedural_state_update",
        "procedural_state_delete",
        "procedural_state_activate",
        "skill_activate",
        "rule_apply",
        "hook_fire",
        "procedure_execute",
        "trigger_register",
        "prompt_inject",
        "learn_behavior",
        "autonomous_execute",
        "self_modify",
        "mcp_start",
        "mcp_restart",
    ] {
        assert!(
            !schema_text.contains(forbidden),
            "{forbidden} should be absent"
        );
    }
    assert!(
        metadata.to_string().to_lowercase().contains("read-only"),
        "provider metadata should describe procedural operations as read-only"
    );
}

#[test]
fn repo_managed_skills_and_skill_copy_wiring_remain_absent() {
    let repo_root = Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .and_then(Path::parent)
        .expect("agent crate under packages/agent");
    assert!(!repo_root.join("packages/agent/skills").exists());
    for path in [
        "packages/agent/src/app",
        "packages/agent/src/domains/agent",
        "packages/agent/src/transport",
    ] {
        let output = std::process::Command::new("rg")
            .args([
                "-n",
                "--glob",
                "*.rs",
                "packages/agent/skills|copy.*skill|skill.*copy|bootstrap.*skill|SKILL.md",
                path,
            ])
            .current_dir(repo_root)
            .output()
            .expect("rg skill wiring");
        assert!(
            output.stdout.is_empty(),
            "repo-managed skill wiring should stay absent: {}",
            String::from_utf8_lossy(&output.stdout)
        );
    }
}
