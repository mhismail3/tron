use super::support::*;

const INVENTORY_MD: &str = "packages/agent/docs/true-primitive-cleanup-retention-inventory.md";
const INVENTORY_TSV: &str = "packages/agent/docs/true-primitive-cleanup-retention-inventory.tsv";

#[test]
fn tracked_source_inventory_is_formalized() {
    let scorecard = read_repo_file("packages/agent/docs/true-primitive-cleanup-scorecard.md");
    let readme = read_repo_file("README.md");
    let inventory = read_repo_file(INVENTORY_MD);
    let tsv = read_repo_file(INVENTORY_TSV);

    for required in [
        "# True Primitive Cleanup Retention Inventory",
        "Status: `passed_after_fix`",
        "Classification Vocabulary",
        "Coverage Scope",
        "Classification Summary",
        "Open Loops",
    ] {
        assert!(
            inventory.contains(required),
            "TPC retention inventory missing `{required}`"
        );
    }

    for required in [INVENTORY_MD, INVENTORY_TSV] {
        assert!(
            scorecard.contains(required) && readme.contains(required),
            "TPC scorecard and README must link retention inventory artifact `{required}`"
        );
    }

    let mut lines = tsv.lines();
    assert_eq!(
        lines.next(),
        Some("path\tclassification\towner\tcleanup_row\treason"),
        "TPC retention TSV must keep a stable header"
    );

    let mut seen_paths = HashSet::new();
    let mut counts = std::collections::HashMap::<String, usize>::new();
    let mut classifications = std::collections::HashMap::<String, String>::new();
    for line in lines {
        let columns: Vec<_> = line.split('\t').collect();
        assert_eq!(
            columns.len(),
            5,
            "inventory row must have five columns: {line}"
        );
        assert!(
            matches!(
                columns[1],
                "primitive" | "implementation" | "support" | "test" | "docs" | "delete"
            ),
            "invalid TPC retention classification `{}` for {}",
            columns[1],
            columns[0]
        );
        assert!(
            !columns[2].is_empty() && !columns[3].is_empty() && !columns[4].is_empty(),
            "inventory row must name owner, cleanup row, and reason: {line}"
        );
        assert!(
            seen_paths.insert(columns[0].to_owned()),
            "duplicate TPC inventory row for {}",
            columns[0]
        );
        classifications.insert(columns[0].to_owned(), columns[1].to_owned());
        *counts.entry(columns[1].to_owned()).or_default() += 1;
    }

    for classification in ["primitive", "implementation", "support", "test", "docs"] {
        assert!(
            counts.get(classification).copied().unwrap_or_default() > 0,
            "TPC retention inventory must contain at least one `{classification}` row"
        );
    }

    for path in tracked_tpc_source_paths() {
        assert!(
            seen_paths.contains(&path),
            "tracked TPC source path missing retention classification: {path}"
        );
    }

    for (path, expected_classification) in [
        (
            "packages/agent/src/domains/agent/loop/capability_invocation_executor/grant_module_validation_tests.rs",
            "test",
        ),
        (
            "packages/agent/src/domains/capability/module_validation_contract.rs",
            "implementation",
        ),
        (
            "packages/agent/src/domains/capability/operations/module_validation.rs",
            "implementation",
        ),
        (
            "packages/agent/src/domains/module_validation/authority.rs",
            "implementation",
        ),
        (
            "packages/agent/src/domains/module_validation/contract.rs",
            "implementation",
        ),
        (
            "packages/agent/src/domains/module_validation/mod.rs",
            "implementation",
        ),
        (
            "packages/agent/src/domains/module_validation/projection.rs",
            "implementation",
        ),
        (
            "packages/agent/src/domains/module_validation/service.rs",
            "implementation",
        ),
        (
            "packages/agent/src/domains/module_validation/shell_ref_tests.rs",
            "test",
        ),
        (
            "packages/agent/src/domains/module_validation/tests.rs",
            "test",
        ),
        (
            "packages/agent/src/domains/module_validation/validation.rs",
            "implementation",
        ),
        (
            "packages/agent/src/engine/durability/resources/module_validation_definitions.rs",
            "implementation",
        ),
    ] {
        assert_eq!(
            classifications.get(path).map(String::as_str),
            Some(expected_classification),
            "TPC inventory classification drifted for Slice 23C path: {path}"
        );
    }
}

fn tracked_tpc_source_paths() -> Vec<String> {
    git_ls_files()
        .into_iter()
        .filter(|path| repo_path(path).exists())
        .filter(|path| {
            path == "README.md"
                || path == "AGENTS.md"
                || path.starts_with("packages/agent/src/")
                || path.starts_with("packages/agent/tests/")
                || path.starts_with("packages/agent/docs/")
                || path.starts_with("packages/ios-app/Sources/")
                || path.starts_with("packages/ios-app/Tests/")
                || path.starts_with("packages/ios-app/docs/")
                || path.starts_with("packages/mac-app/Sources/")
                || path.starts_with("packages/mac-app/Tests/")
                || path.starts_with("packages/mac-app/docs/")
                || path.starts_with("scripts/")
        })
        .collect()
}
