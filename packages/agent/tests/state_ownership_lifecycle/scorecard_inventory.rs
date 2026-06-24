use super::support::*;
use std::collections::BTreeSet;

#[test]
fn sol_campaign_harness_exists() {
    let scorecard = read_repo_file(SCORECARD_PATH);
    let evidence = read_repo_file(EVIDENCE_PATH);
    let inventory = read_repo_file(INVENTORY_PATH);
    let tsv = read_repo_file(INVENTORY_TSV_PATH);
    let readme = read_repo_file("README.md");

    for required in [
        "# State Ownership And Lifecycle Scorecard",
        "Current score:",
        "Status: **complete**",
        "Total weight: **100**",
        "| SOL-0 | Campaign harness, red static gate, README links, scorecard/evidence/inventory scaffolding | 5 | passed_after_fix |",
        "| SOL-1 | Whole-repo state inventory for Rust server, iOS app, scripts/CI state, docs-owned state claims | 10 |",
        "| SOL-8 | iOS projection and local state lifecycle | 14 |",
        "| SOL-10 | Final closeout | 3 |",
        "SessionManager::plan_mode",
        "Engine compensation records",
        "iOS local-only state surfaces",
        "cargo test --manifest-path packages/agent/Cargo.toml --test state_ownership_lifecycle_invariants -- --nocapture",
    ] {
        assert!(
            scorecard.contains(required),
            "SOL scorecard missing required text: {required}"
        );
    }

    for required in [
        "# State Ownership And Lifecycle Evidence Manifest",
        "Current score:",
        "| SOL-0 | passed_after_fix |",
        "| SOL-10 | passed_after_fix |",
        "## SOL-0 Evidence",
        "## Verification Log",
        "## Residual Risk Log",
    ] {
        assert!(
            evidence.contains(required),
            "SOL evidence manifest missing required text: {required}"
        );
    }

    for required in [
        "# State Ownership And Lifecycle Inventory",
        "Allowed State Classes",
        "`canonical_truth`",
        "`durable_substrate`",
        "`projection_cache`",
        "`ephemeral_runtime`",
        "`local_device_preference`",
        "`secret`",
        "`diagnostic_buffer`",
        "`test_fixture`",
    ] {
        assert!(
            inventory.contains(required),
            "SOL inventory missing required text: {required}"
        );
    }

    assert!(
        tsv.starts_with(INVENTORY_HEADER),
        "SOL inventory TSV must start with the required header"
    );

    for required in [
        SCORECARD_PATH,
        EVIDENCE_PATH,
        INVENTORY_PATH,
        INVENTORY_TSV_PATH,
        INVARIANT_TEST_PATH,
    ] {
        assert!(
            readme.contains(required),
            "README living-doc map must link {required}"
        );
    }
}

#[test]
fn sol_scorecard_weights_sum_to_100() {
    let scorecard = read_repo_file(SCORECARD_PATH);
    let total: u32 = scorecard
        .lines()
        .filter_map(|line| {
            let columns: Vec<_> = line.split('|').map(str::trim).collect();
            if columns.get(1).is_some_and(|cell| cell.starts_with("SOL-")) {
                columns.get(3).and_then(|cell| cell.parse::<u32>().ok())
            } else {
                None
            }
        })
        .sum();
    assert_eq!(total, 100, "SOL row weights must sum to 100");
}

#[test]
fn sol_inventory_rows_are_structured_and_classified() {
    let rows = parse_inventory();
    assert!(!rows.is_empty(), "SOL inventory must have rows");

    let mut seen = BTreeSet::new();
    for row in rows {
        assert!(
            seen.insert((row.path.clone(), row.state_surface.clone())),
            "duplicate SOL inventory row for path/surface: {} {}",
            row.path,
            row.state_surface
        );
        assert!(
            repo_path(&row.path).exists(),
            "SOL inventory path must exist: {}",
            row.path
        );
        assert!(
            ALLOWED_STATE_CLASSES.contains(&row.state_class.as_str()),
            "invalid state_class `{}` for {}",
            row.state_class,
            row.path
        );
        for (name, value) in [
            ("language", &row.language),
            ("owner", &row.owner),
            ("scope", &row.scope),
            ("creation_path", &row.creation_path),
            ("mutation_boundary", &row.mutation_boundary),
            (
                "hydration_or_reconstruction",
                &row.hydration_or_reconstruction,
            ),
            ("retirement_or_retention", &row.retirement_or_retention),
            ("concurrency_or_task_guard", &row.concurrency_or_task_guard),
            ("sol_rows", &row.sol_rows),
        ] {
            assert!(
                !value.trim().is_empty(),
                "SOL inventory field {name} must be populated for {}",
                row.path
            );
        }
    }
}

#[test]
fn sol_truth_taxonomy_is_owner_scoped() {
    let inventory_doc = read_repo_file(INVENTORY_PATH);
    for class in ALLOWED_STATE_CLASSES {
        assert!(
            inventory_doc.contains(&format!("`{class}`")),
            "SOL inventory docs must define allowed state class `{class}`"
        );
    }

    let rows = parse_inventory();
    let mut bad_rows = Vec::new();

    for row in rows {
        if row.owner.contains("unclassified") {
            bad_rows.push(format!("{} has unclassified owner {}", row.path, row.owner));
        }

        if row.path.starts_with("packages/ios-app/") && row.state_class == "canonical_truth" {
            bad_rows.push(format!(
                "{} is iOS-local but claims canonical server truth",
                row.path
            ));
        }

        if (row.path.starts_with("scripts/")
            || row.path.starts_with(".github/")
            || row.path.starts_with("packages/agent/docs/")
            || row.path == "README.md")
            && matches!(
                row.state_class.as_str(),
                "canonical_truth" | "durable_substrate" | "secret"
            )
        {
            bad_rows.push(format!(
                "{} is docs/script/CI state but claims {}",
                row.path, row.state_class
            ));
        }

        if row.state_class == "canonical_truth"
            && !matches!(
                row.owner.as_str(),
                "session_event_store" | "settings_profile" | "shared_foundation"
            )
        {
            bad_rows.push(format!(
                "{} canonical truth has unexpected owner {}",
                row.path, row.owner
            ));
        }

        if row.state_class == "secret"
            && !(row.owner == "auth_credentials"
                || row.owner == "ios_local_storage"
                || row.path.contains("Keychain")
                || row.path.contains("TokenStore"))
        {
            bad_rows.push(format!(
                "{} secret has unexpected owner {}",
                row.path, row.owner
            ));
        }

        if row.state_class == "local_device_preference"
            && !row.path.starts_with("packages/ios-app/")
        {
            bad_rows.push(format!(
                "{} local_device_preference is not owned by iOS local state",
                row.path
            ));
        }
    }

    assert!(
        bad_rows.is_empty(),
        "SOL truth taxonomy violations:\n{}",
        bad_rows.join("\n")
    );
}

#[test]
fn sol_inventory_covers_stateful_marker_sources() {
    let inventory = inventory_by_path();
    let missing = marker_paths()
        .into_iter()
        .filter(|path| !inventory.contains_key(path))
        .collect::<Vec<_>>();
    assert!(
        missing.is_empty(),
        "SOL inventory missing stateful marker source rows:\n{}",
        missing.join("\n")
    );
}

#[test]
fn sol_inventory_covers_scripts_ci_and_docs_state_claims() {
    let inventory = inventory_by_path();
    for required in [
        "README.md",
        "scripts/tron",
        "scripts/tron.d/dev.sh",
        "scripts/tron.d/quality.sh",
        "scripts/tron-lib.d/service.sh",
        ".github/workflows/ci.yml",
    ] {
        assert!(
            inventory.contains_key(required),
            "SOL inventory must cover script/CI/docs state surface: {required}"
        );
    }
}
