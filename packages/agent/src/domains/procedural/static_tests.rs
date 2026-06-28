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

const FORBIDDEN_SKILL_BOOTSTRAP_IDENTIFIER_FRAGMENTS: &[&str] = &[
    "bootstrapmanagedskill",
    "bootstrapmanagedskills",
    "bootstrapskill",
    "bootstrapskills",
    "builtinskill",
    "builtinskills",
    "copyskill",
    "copyskills",
    "firstpartyskill",
    "firstpartyskills",
    "injectskill",
    "injectskills",
    "loadskill",
    "loadskills",
    "managedskillbootstrap",
    "managedskillsbootstrap",
    "promptskillcontext",
    "promptskillscontext",
    "promptskillinjection",
    "promptskillsinjection",
    "repomanagedskillbootstrap",
    "repomanagedskillsbootstrap",
    "skillasset",
    "skillassets",
    "skillbootstrap",
    "skillbundle",
    "skillbundles",
    "skillcopy",
    "skillinject",
    "skillloader",
    "skillpromptcontext",
    "skillpromptinjection",
    "skillregistry",
    "skillsasset",
    "skillsassets",
    "skillsbootstrap",
    "skillsbundle",
    "skillsbundles",
    "skillscopy",
    "skillsinject",
    "skillsloader",
    "skillspromptcontext",
    "skillspromptinjection",
    "skillsregistry",
    "skillsync",
    "syncskill",
    "syncskills",
];

fn compact_identifier_token(token: &str) -> String {
    token
        .bytes()
        .filter_map(|byte| match byte {
            b'A'..=b'Z' => Some((byte + 32) as char),
            b'a'..=b'z' | b'0'..=b'9' => Some(byte as char),
            _ => None,
        })
        .collect()
}

fn push_identifier_compact(compacts: &mut Vec<String>, token: &str) {
    if token.bytes().any(|byte| byte.is_ascii_alphabetic()) {
        let compact = compact_identifier_token(token);
        if !compact.is_empty() {
            compacts.push(compact);
        }
    }
}

fn code_like_identifier_compacts(contents: &str) -> Vec<String> {
    let mut compacts = Vec::new();
    let mut token = String::new();
    for ch in contents.chars() {
        if ch == '_' || ch.is_ascii_alphanumeric() {
            token.push(ch);
        } else if !token.is_empty() {
            push_identifier_compact(&mut compacts, &token);
            token.clear();
        }
    }
    if !token.is_empty() {
        push_identifier_compact(&mut compacts, &token);
    }
    compacts
}

fn forbidden_skill_bootstrap_identifier_hits(path: &str, contents: &str) -> Vec<String> {
    let identifiers = code_like_identifier_compacts(contents);
    let mut hits = Vec::new();
    for forbidden in FORBIDDEN_SKILL_BOOTSTRAP_IDENTIFIER_FRAGMENTS {
        if identifiers
            .iter()
            .any(|identifier| identifier.contains(forbidden))
        {
            hits.push(format!("{path}: {forbidden}"));
        }
    }
    hits
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
        hits.extend(forbidden_skill_bootstrap_identifier_hits(path, &contents));
    }
    assert!(
        hits.is_empty(),
        "bootstrap skill registries, skill-copy wiring, and hidden prompt-context skill injection must stay absent: {hits:#?}"
    );
}

#[test]
fn skill_bootstrap_identifier_guard_rejects_realistic_name_variants() {
    for (contents, expected_fragment) in [
        ("struct SkillsRegistry;", "skillsregistry"),
        ("struct BootstrapSkillsRegistry;", "bootstrapskills"),
        ("struct ManagedSkillsRegistry;", "skillsregistry"),
        ("struct SkillLoader;", "skillloader"),
        ("struct SkillsLoader;", "skillsloader"),
        ("struct SkillBootstrapRegistry;", "skillbootstrap"),
        ("struct SkillsPromptContext;", "skillspromptcontext"),
        ("fn bootstrap_skills_registry() {}", "bootstrapskills"),
        ("fn managed_skill_bootstrap() {}", "managedskillbootstrap"),
        ("fn skill_prompt_context() {}", "skillpromptcontext"),
        ("fn prompt_skills_context() {}", "promptskillscontext"),
        (
            "fn repo_managed_skills_bootstrap() {}",
            "repomanagedskillsbootstrap",
        ),
    ] {
        let hits = forbidden_skill_bootstrap_identifier_hits("candidate.rs", contents);
        assert!(
            hits.iter().any(|hit| hit.ends_with(expected_fragment)),
            "expected {contents:?} to be rejected by {expected_fragment}; hits: {hits:?}"
        );
    }
}

#[test]
fn skill_bootstrap_identifier_guard_allows_metadata_only_proof_fields() {
    for contents in [
        r#"const MODULE_REGISTRY: &str = "module_registry_procedural_manifest";"#,
        r#"const MODULE_ID: &str = "procedural_module";"#,
        r#"json!({"sideEffectProof": {"repoManagedSkillsTouched": false}})"#,
        "no skill-copy/bootstrap registries or hidden skill prompt-context injection may return",
    ] {
        let hits = forbidden_skill_bootstrap_identifier_hits("allowed.rs", contents);
        assert!(
            hits.is_empty(),
            "metadata-only proof text must remain allowed: {hits:?}"
        );
    }
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
