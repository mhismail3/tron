use super::support::*;

#[test]
fn rust_hra7_has_no_remaining_overbudget_rust_files() {
    let mut source_files = Vec::new();
    for path in ["packages/agent/src", "packages/agent/tests"] {
        list_source_files(&repo_path(path), &["rs"], &mut source_files);
    }

    let mut over_budget = Vec::new();
    for path in source_files {
        let lines = source_line_count(&path);
        if lines > 900 {
            over_budget.push(format!(
                "{} has {lines} LOC over Rust HRA-7 limit 900",
                path.strip_prefix(repo_root()).unwrap().display()
            ));
        }
    }

    assert!(
        over_budget.is_empty(),
        "HRA-7 must replace temporary Rust budget rows with real decomposition: {over_budget:#?}"
    );
}

#[test]
fn rust_progressive_docs_declare_dependency_and_test_ownership() {
    let required_docs = [
        "packages/agent/src/engine/authority/mod.rs",
        "packages/agent/src/engine/durability/mod.rs",
        "packages/agent/src/engine/runtime/mod.rs",
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
