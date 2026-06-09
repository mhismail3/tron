use super::support::*;

#[test]
fn docs_guards_and_inventories_are_current() {
    let scorecard = read_repo_file("packages/agent/docs/true-primitive-cleanup-scorecard.md");
    let manifest =
        read_repo_file("packages/agent/docs/true-primitive-cleanup-evidence-manifest.md");
    let readme = read_repo_file("README.md");

    for required in [
        "Current score: **100/100**",
        "| TPC-10 | Docs, guards, inventories | 5 | passed_after_fix |",
        "Residual Term Review Policy",
        "Manual deploy wording is retained only for `tron manual-deploy`",
    ] {
        assert!(
            scorecard.contains(required),
            "TPC-10 scorecard closeout missing `{required}`"
        );
    }

    assert!(
        manifest.contains("| TPC-10 | passed_after_fix |"),
        "TPC-10 evidence manifest row must be passed after fix"
    );

    for stale in [
        "`tron deploy`",
        "tron deploy",
        "Deploy Pipeline",
        "fallback residue",
        "no-op/failure state",
    ] {
        assert!(
            !readme.contains(stale),
            "README still contains stale TPC-10 wording `{stale}`"
        );
    }
    assert!(
        readme.contains("### Manual Contributor Deploy"),
        "README deployment docs must name the retained contributor command explicitly"
    );

    assert!(
        repo_path("scripts/tron.d/manual-deploy.sh").exists()
            && !repo_path("scripts/tron.d/deploy.sh").exists(),
        "only the manual deploy script module should exist"
    );

    for path in [
        "packages/agent/docs/hierarchical-rearchitecture-current-ownership-map.tsv",
        "packages/agent/docs/hierarchical-rearchitecture-file-inventory.tsv",
        "packages/agent/docs/primitive-code-cleanup-file-inventory.tsv",
        "packages/agent/docs/primitive-code-cleanup-scorecard.md",
        "packages/agent/tests/hierarchical_rearchitecture/docs_path_closeout.rs",
    ] {
        let text = read_repo_file(path);
        assert!(
            !text.contains("scripts/tron.d/deploy.sh"),
            "{path} still references the retired deploy script path"
        );
        assert!(
            !text.contains("manual `tron deploy`"),
            "{path} still describes the retained contributor workflow with old command spelling"
        );
    }

    let inventory =
        read_repo_file("packages/agent/docs/true-primitive-cleanup-retention-inventory.md");
    let tsv = read_repo_file("packages/agent/docs/true-primitive-cleanup-retention-inventory.tsv");
    assert!(
        tsv.contains(
            "packages/agent/tests/true_primitive_cleanup/docs_guards_inventories.rs\ttest\t"
        ),
        "TPC-10 guard file must be classified in the retention inventory"
    );
    let counts = inventory_class_counts(&tsv);
    for (classification, count) in counts {
        assert!(
            inventory.contains(&format!("| {classification} | {count} |")),
            "inventory summary count for `{classification}` must match TSV count {count}"
        );
    }

    let owner_counts = inventory_owner_counts(&tsv);
    for (owner, count) in owner_counts {
        assert!(
            inventory.contains(&format!("| `{owner}` | {count} |")),
            "inventory owner count for `{owner}` must match TSV count {count}"
        );
    }
}

fn inventory_class_counts(tsv: &str) -> std::collections::BTreeMap<String, usize> {
    let mut counts = std::collections::BTreeMap::<String, usize>::new();
    for line in tsv.lines().skip(1) {
        let columns: Vec<_> = line.split('\t').collect();
        if columns.len() == 5 {
            *counts.entry(columns[1].to_owned()).or_default() += 1;
        }
    }
    counts
}

fn inventory_owner_counts(tsv: &str) -> std::collections::BTreeMap<String, usize> {
    let mut counts = std::collections::BTreeMap::<String, usize>::new();
    for line in tsv.lines().skip(1) {
        let columns: Vec<_> = line.split('\t').collect();
        if columns.len() == 5 {
            *counts.entry(columns[2].to_owned()).or_default() += 1;
        }
    }
    counts
}
