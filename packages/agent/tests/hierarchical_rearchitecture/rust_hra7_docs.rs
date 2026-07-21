use super::support::*;

#[test]
fn rust_progressive_docs_declare_dependency_and_test_ownership() {
    let required_docs = [
        "packages/agent/src/engine/durability/mod.rs",
        "packages/agent/src/domains/worker_kernel/mod.rs",
        "packages/agent/src/domains/session/event_store/mod.rs",
    ];

    let mut missing_sections = Vec::new();
    for path in required_docs {
        let source = read_repo_file(path);
        for section in [
            "## Submodules",
            "## Entry Points",
            "## Dependency Direction",
            "## Invariants",
            "## Test Ownership",
        ] {
            if !source.contains(section) {
                missing_sections.push(format!("{path} missing {section}"));
            }
        }
    }

    assert!(
        missing_sections.is_empty(),
        "HRA-7 progressive docs must name submodules, entry points, dependencies, invariants, and test ownership: {missing_sections:#?}"
    );
}
