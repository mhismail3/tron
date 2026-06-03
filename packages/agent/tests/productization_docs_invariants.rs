//! Static product-doc coverage for the self-extending local product flow.

use std::path::{Path, PathBuf};

fn crate_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
}

fn repo_root() -> PathBuf {
    let mut cur = crate_root();
    for _ in 0..5 {
        if cur.join("scripts").join("tron").is_file() {
            return cur;
        }
        if !cur.pop() {
            break;
        }
    }
    panic!("could not locate repo root from {:?}", crate_root());
}

fn read(path: &Path) -> String {
    std::fs::read_to_string(path)
        .unwrap_or_else(|error| panic!("failed to read {}: {error}", path.display()))
}

fn assert_contains_all(label: &str, content: &str, required: &[&str]) {
    for needle in required {
        assert!(
            content.contains(needle),
            "{label} missing required product docs marker: {needle}"
        );
    }
}

#[test]
fn self_extending_product_docs_cover_user_operator_release_and_troubleshooting() {
    let repo_root = repo_root();
    let docs_root = repo_root.join("packages").join("agent").join("docs");
    let docs = [
        (
            "user guide",
            docs_root.join("self-extending-local-product-user-guide.md"),
            [
                "# Self-Extending Local Product User Guide",
                "Chat is the primary surface",
                "Created by Agent",
                "Packs",
                "Local when possible",
                "Balanced",
                "Deep",
                "server-owned trust labels",
                "generated UI",
                "Inspect",
                "no push, merge, release, deploy, or remote package discovery",
            ]
            .as_slice(),
        ),
        (
            "operator guide",
            docs_root.join("self-extending-local-product-operator-guide.md"),
            [
                "# Self-Extending Local Product Operator Guide",
                "module::register_package",
                "module::verify_source",
                "module::record_conformance",
                "module::approve_source",
                "module::configure",
                "module::activate",
                "module::disable",
                "module::rollback",
                "module::remove_package",
                "ui::submit_action",
                "worker::protocol_guide",
                "worker::spawn",
                "resource refs are evidence",
                "No remote package discovery",
            ]
            .as_slice(),
        ),
        (
            "release notes",
            docs_root.join("self-extending-local-product-release-notes.md"),
            [
                "# Self-Extending Local Product Notes",
                "TPROD-A",
                "TPROD-J",
                "chat-led self-extension",
                "local example packs",
                "generated UI authoring",
                "model presets",
                "Known boundaries",
                "This is not a release, deploy, push, merge, notarization, or rollout checklist",
            ]
            .as_slice(),
        ),
        (
            "troubleshooting",
            docs_root.join("self-extending-local-product-troubleshooting.md"),
            [
                "# Self-Extending Local Product Troubleshooting",
                "workspace autonomy",
                "materialized file",
                "source verification",
                "conformance",
                "trustPresentation",
                "generated UI",
                "Local when possible",
                "catalog::watch_snapshot",
                "sandbox::stop_spawned_worker",
                "No remote marketplace",
            ]
            .as_slice(),
        ),
    ];

    for (label, path, required) in docs {
        assert!(path.is_file(), "{label} must exist at {}", path.display());
        let content = read(&path);
        assert_contains_all(label, &content, required);
        for forbidden in [
            "tron deploy",
            "remote package discovery is implemented",
            "remote marketplace install is implemented",
            "client-owned trust",
            "client-owned policy",
            "client-owned model routing",
            "client-authored generated action target",
        ] {
            assert!(
                !content.contains(forbidden),
                "{label} must not claim forbidden product behavior: {forbidden}"
            );
        }
    }

    let readme = read(&repo_root.join("README.md"));
    for doc in [
        "packages/agent/docs/self-extending-local-product-user-guide.md",
        "packages/agent/docs/self-extending-local-product-operator-guide.md",
        "packages/agent/docs/self-extending-local-product-release-notes.md",
        "packages/agent/docs/self-extending-local-product-troubleshooting.md",
    ] {
        assert!(
            readme.contains(doc),
            "README living-doc map must link {doc}"
        );
    }
}
