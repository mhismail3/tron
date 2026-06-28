use serde_json::json;
use std::path::Path;

use crate::engine::{PROCEDURAL_RECORD_KIND, PROCEDURAL_RECORD_SCHEMA_ID};

fn repo_root() -> std::path::PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .and_then(Path::parent)
        .expect("agent crate under packages/agent")
        .to_path_buf()
}

fn git_ls_files() -> Vec<String> {
    let output = std::process::Command::new("git")
        .args(["ls-files"])
        .current_dir(repo_root())
        .output()
        .expect("git ls-files");
    assert!(
        output.status.success(),
        "git ls-files failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8(output.stdout)
        .expect("git output should be UTF-8")
        .lines()
        .map(str::to_owned)
        .collect()
}

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
    let repo_root = repo_root();
    assert!(!repo_root.join("packages/agent/skills").exists());

    let tracked_files = git_ls_files();
    for path in &tracked_files {
        assert!(
            path != "packages/agent/skills" && !path.starts_with("packages/agent/skills/"),
            "repo-managed first-party skill asset must not be tracked: {path}"
        );
        assert!(
            !(path.starts_with("packages/agent/") && path.ends_with("/SKILL.md")),
            "package SKILL.md assets must not be tracked under packages/agent: {path}"
        );
    }

    let forbidden_symbols = [
        "bootstrap_skill_registry",
        "bootstrap_skills_registry",
        "managed_skill_registry",
        "repo_managed_skill_registry",
        "first_party_skill_registry",
        "builtin_skill_registry",
        "built_in_skill_registry",
        "skillregistry",
        "builtinskill",
        "firstpartyskill",
        "skill_copy",
        "skillcopy",
        "copy_skill",
        "copyskill",
        "copy_skills",
        "copyskills",
        "sync_skill",
        "syncskill",
        "sync_skills",
        "syncskills",
        "skill_asset",
        "skillasset",
        "skill_assets",
        "skillassets",
        "skill_bundle",
        "skillbundle",
        "skill_bundles",
        "skillbundles",
        "skill_prompt_context",
        "skillpromptcontext",
        "prompt_skill_context",
        "promptskillcontext",
        "inject_skill",
        "injectskill",
        "skill_inject",
        "skillinject",
        "skill_prompt",
        "skillprompt",
        "prompt_skill",
        "promptskill",
        "load_skill",
        "loadskill",
        "load_skills",
        "loadskills",
    ];
    let mut hits = Vec::new();
    for path in tracked_files
        .iter()
        .filter(|path| path.starts_with("packages/agent/src/") && path.ends_with(".rs"))
        .filter(|path| {
            !path.ends_with("_tests.rs")
                && !path.ends_with("/tests.rs")
                && !path.ends_with("/static_tests.rs")
        })
    {
        let contents = std::fs::read_to_string(repo_root.join(path))
            .unwrap_or_else(|error| panic!("failed to read {path}: {error}"));
        let lower = contents.to_ascii_lowercase();
        for forbidden in forbidden_symbols {
            if lower.contains(forbidden) {
                hits.push(format!("{path}: {forbidden}"));
            }
        }
    }
    assert!(
        hits.is_empty(),
        "bootstrap skill registries, skill-copy wiring, and hidden prompt-context skill injection must stay absent: {hits:#?}"
    );
}

#[test]
fn procedural_module_manifest_seed_remains_metadata_only_not_skill_bootstrap() {
    let manifest_path =
        "packages/agent/src/engine/durability/resources/module_registry_procedural_manifest.rs";
    let manifest = std::fs::read_to_string(repo_root().join(manifest_path))
        .unwrap_or_else(|error| panic!("failed to read {manifest_path}: {error}"));
    for required in [
        "\"moduleId\": \"procedural_module\"",
        "\"source\": \"source_backed_first_party\"",
        "\"installable\": false",
        "\"executable\": false",
        "\"networkPolicy\": \"none\"",
        "\"activation\": \"review_decision_metadata_only\"",
        "metadata-only",
        "without firing triggers or executing code",
    ] {
        assert!(
            manifest.contains(required),
            "procedural module manifest seed must remain metadata-only evidence: {required}"
        );
    }
    for forbidden in [
        "SKILL.md",
        "packages/agent/skills",
        "copy/bootstrap skills into prompts",
    ] {
        assert!(
            !manifest.contains(forbidden),
            "procedural module manifest seed must not become skill bootstrap wiring: {forbidden}"
        );
    }
}
