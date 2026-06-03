//! Static checks for repo-managed first-party skill sources.

use std::path::{Path, PathBuf};

use tron::domains::skills::parser::parse_skill_md;

#[test]
fn self_extend_skill_is_managed_and_uses_live_worker_protocol_guide() {
    let skill_dir = repo_root()
        .join("packages")
        .join("agent")
        .join("skills")
        .join("self-extend");
    let skill_path = skill_dir.join("SKILL.md");
    assert!(skill_dir.join(".managed").is_file());
    assert!(skill_path.is_file());

    let raw = std::fs::read_to_string(&skill_path)
        .unwrap_or_else(|error| panic!("failed to read {}: {error}", skill_path.display()));
    let parsed = parse_skill_md(&raw).expect("self-extend skill must parse");
    let frontmatter = parsed.frontmatter;
    assert_eq!(frontmatter.name.as_deref(), Some("self-extend"));
    assert!(
        frontmatter
            .description
            .as_deref()
            .is_some_and(|description| description.contains("local Tron capabilities"))
    );
    assert!(
        frontmatter
            .allowed_contracts
            .as_ref()
            .is_some_and(|contracts| contracts
                .iter()
                .any(|contract| contract == "capability::execute"))
    );

    for required in [
        "worker::protocol_guide",
        "Call `worker::protocol_guide` at the start of every run",
        "worker::spawn",
        "catalog::watch_snapshot",
        "capability::inspect",
        "ui::surface_for_target",
        "module::register_package",
        "module::inspect_package",
        "module::configure",
        "module::activate",
        "module::disable",
        "module::rollback",
        "module::revoke_source_approval",
        "module::remove_package",
        "engine::promote",
        "worker::disconnect",
        "sandbox::stop_spawned_worker",
        "Remote package discovery and marketplace install are outside this campaign.",
        "## Gotchas",
    ] {
        assert!(
            raw.contains(required),
            "self-extend skill missing required flow marker: {required}"
        );
    }

    for forbidden_protocol_copy in [
        "TRON_ENGINE_WORKER_ENDPOINT",
        "WorkerIdentity",
        "/engine/workers",
        "functionDefinitions",
        "worker_protocol_template.py",
    ] {
        assert!(
            !raw.contains(forbidden_protocol_copy),
            "self-extend skill must fetch live worker protocol details, not copy `{forbidden_protocol_copy}`"
        );
    }
}

fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .and_then(Path::parent)
        .unwrap_or_else(|| Path::new(env!("CARGO_MANIFEST_DIR")))
        .to_path_buf()
}
