use super::support::*;

#[test]
fn primitive_code_cleanup_scorecard_stays_formalized() {
    let scorecard = read_repo_file("packages/agent/docs/primitive-code-cleanup-scorecard.md");
    let manifest =
        read_repo_file("packages/agent/docs/primitive-code-cleanup-evidence-manifest.md");
    let readme = read_repo_file("README.md");

    for required in [
        "# Primitive Code Cleanup Scorecard",
        "Current score: **100/100**",
        "Status: **completed**",
        "Branch: `codex/primitive-engine-teardown`",
        "Primitive And Plane Budget",
        "Folder Justification Table",
        "Large File Budgets",
        "Static Gates",
        "| PCC-0 | Scorecard, evidence, and static-gate setup | 5 | passed_after_fix |",
        "Total weight: **100**",
        "| PCC-1 | Inventory and folder justification | 12 | passed_after_fix |",
        "| PCC-2 | Root and generated artifact hygiene | 5 | passed_after_fix |",
        "| PCC-3 | Rust agent consolidation | 18 | passed_after_fix |",
        "| PCC-4 | Engine and primitive surface cleanup | 10 | passed_after_fix |",
        "| PCC-5 | Session, trace, and persistence cleanup | 8 | passed_after_fix |",
        "| PCC-6 | iOS app consolidation | 12 | passed_after_fix |",
        "| PCC-7 | Mac app consolidation | 8 | passed_after_fix |",
        "| PCC-8 | Scripts cleanup | 6 | passed_after_fix |",
        "| PCC-9 | Docs and test cleanup | 8 | passed_after_fix |",
        "| PCC-10 | Final adversarial pass | 8 | passed_after_fix |",
        "Closeout complete.",
        "primitive-code-cleanup-inventory.md",
        "primitive-code-cleanup-file-inventory.tsv",
    ] {
        assert!(
            scorecard.contains(required),
            "cleanup scorecard missing required text: {required}"
        );
    }

    for required in [
        "# Primitive Code Cleanup Evidence Manifest",
        "Current score: **100/100**",
        "Status: **completed**",
        "| PCC-0 | passed_after_fix |",
        "| PCC-1 | passed_after_fix |",
        "| PCC-2 | passed_after_fix |",
        "| PCC-3 | passed_after_fix |",
        "| PCC-4 | passed_after_fix |",
        "| PCC-5 | passed_after_fix |",
        "| PCC-6 | passed_after_fix |",
        "| PCC-7 | passed_after_fix |",
        "| PCC-8 | passed_after_fix |",
        "| PCC-9 | passed_after_fix |",
        "| PCC-10 | passed_after_fix |",
    ] {
        assert!(
            manifest.contains(required),
            "cleanup evidence manifest missing required text: {required}"
        );
    }

    assert!(
        readme.contains("packages/agent/docs/primitive-code-cleanup-scorecard.md")
            && readme.contains("packages/agent/docs/primitive-code-cleanup-evidence-manifest.md"),
        "README living-doc map must link the active cleanup scorecard and evidence manifest"
    );
}

#[test]
fn primitive_code_cleanup_inventory_covers_tracked_files() {
    let inventory = read_repo_file("packages/agent/docs/primitive-code-cleanup-inventory.md");
    let file_inventory =
        read_repo_file("packages/agent/docs/primitive-code-cleanup-file-inventory.tsv");
    let readme = read_repo_file("README.md");

    for required in [
        "# Primitive Code Cleanup Inventory",
        "Status: `passed_after_fix`",
        "Machine-readable inventory",
        "Classification Vocabulary",
        "Canonical Target Tree",
        "Delete Candidates",
        "Collapse-Audit Hotspots",
        "Open Loops",
    ] {
        assert!(
            inventory.contains(required),
            "cleanup inventory missing required text: {required}"
        );
    }

    assert!(
        readme.contains("packages/agent/docs/primitive-code-cleanup-inventory.md")
            && readme.contains("packages/agent/docs/primitive-code-cleanup-file-inventory.tsv"),
        "README living-doc map must link cleanup inventory artifacts"
    );

    let mut seen_paths = HashSet::new();
    let mut counts = HashMap::<&str, usize>::new();
    let mut classifications = HashMap::<String, String>::new();
    let mut lines = file_inventory.lines();
    assert_eq!(
        lines.next(),
        Some("path\tclassification\towner\tcleanup_row\treason"),
        "file inventory must keep a stable TSV header"
    );
    for line in lines {
        let columns: Vec<_> = line.split('\t').collect();
        assert_eq!(
            columns.len(),
            5,
            "inventory row must have five TSV columns: {line}"
        );
        assert!(
            matches!(
                columns[1],
                "retain" | "collapse" | "delete" | "generated" | "asset"
            ),
            "invalid inventory classification `{}` for {}",
            columns[1],
            columns[0]
        );
        assert!(
            !columns[2].is_empty() && !columns[3].is_empty() && !columns[4].is_empty(),
            "inventory row must name owner, cleanup row, and reason: {line}"
        );
        *counts.entry(columns[1]).or_insert(0) += 1;
        classifications.insert(columns[0].to_owned(), columns[1].to_owned());
        assert!(
            seen_paths.insert(columns[0].to_owned()),
            "duplicate file inventory row for {}",
            columns[0]
        );
    }

    for path in git_ls_files().into_iter().chain([
        "packages/agent/docs/primitive-code-cleanup-inventory.md".to_owned(),
        "packages/agent/docs/primitive-code-cleanup-file-inventory.tsv".to_owned(),
    ]) {
        assert!(
            seen_paths.contains(&path),
            "tracked file missing cleanup inventory classification: {path}"
        );
    }

    for path in [
        "packages/agent/src/domains/agent/loop/capability_invocation_executor/grant_module_validation_tests.rs",
        "packages/agent/src/domains/capability/module_validation_contract.rs",
        "packages/agent/src/domains/capability/operations/module_validation.rs",
        "packages/agent/src/domains/module_validation/authority.rs",
        "packages/agent/src/domains/module_validation/contract.rs",
        "packages/agent/src/domains/module_validation/mod.rs",
        "packages/agent/src/domains/module_validation/projection.rs",
        "packages/agent/src/domains/module_validation/service.rs",
        "packages/agent/src/domains/module_validation/shell_ref_tests.rs",
        "packages/agent/src/domains/module_validation/tests.rs",
        "packages/agent/src/domains/module_validation/validation.rs",
        "packages/agent/src/engine/durability/resources/module_validation_definitions.rs",
    ] {
        assert_eq!(
            classifications.get(path).map(String::as_str),
            Some("retain"),
            "PCC inventory must retain Slice 23C path: {path}"
        );
    }

    for classification in ["retain", "generated", "asset"] {
        assert!(
            counts.get(classification).copied().unwrap_or_default() > 0,
            "inventory must contain at least one `{classification}` row"
        );
    }
    for classification in ["collapse", "delete"] {
        assert_eq!(
            counts.get(classification).copied().unwrap_or_default(),
            0,
            "inventory must not retain unresolved `{classification}` rows after PCC-9"
        );
    }
}

#[test]
fn retained_top_level_source_directories_are_justified() {
    let scorecard = read_repo_file("packages/agent/docs/primitive-code-cleanup-scorecard.md");
    for path in [
        ".codex",
        ".github",
        "packages",
        "scripts",
        "packages/agent",
        "packages/ios-app",
        "packages/mac-app",
        "packages/agent/src/app",
        "packages/agent/src/transport",
        "packages/agent/src/engine",
        "packages/agent/src/domains",
        "packages/agent/src/shared",
        "packages/agent/src/platform",
        "packages/ios-app/Sources/App",
        "packages/ios-app/Sources/Assets.xcassets",
        "packages/ios-app/Sources/Engine",
        "packages/ios-app/Sources/Resources",
        "packages/ios-app/Sources/Session",
        "packages/ios-app/Sources/Support",
        "packages/ios-app/Sources/UI",
        "packages/mac-app/Sources/App",
        "packages/mac-app/Sources/Assets.xcassets",
        "packages/mac-app/Sources/MenuBar",
        "packages/mac-app/Sources/Resources",
        "packages/mac-app/Sources/Server",
        "packages/mac-app/Sources/Support",
        "packages/mac-app/Sources/Wizard",
    ] {
        assert!(
            scorecard.contains(&format!("| `{path}` |")),
            "folder justification table missing retained directory `{path}`"
        );
    }
}
