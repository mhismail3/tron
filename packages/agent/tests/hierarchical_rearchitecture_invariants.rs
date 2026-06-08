//! Static gates for the whole-repo hierarchical rearchitecture campaign.

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::process::Command;

const FILE_INVENTORY_PATH: &str =
    "packages/agent/docs/hierarchical-rearchitecture-file-inventory.tsv";
const MOVE_MAP_PATH: &str = "packages/agent/docs/hierarchical-rearchitecture-move-map.tsv";
const SCORECARD_PATH: &str = "packages/agent/docs/hierarchical-rearchitecture-scorecard.md";
const EVIDENCE_PATH: &str = "packages/agent/docs/hierarchical-rearchitecture-evidence-manifest.md";
const INVENTORY_PATH: &str = "packages/agent/docs/hierarchical-rearchitecture-inventory.md";
const INVARIANT_TEST_PATH: &str = "packages/agent/tests/hierarchical_rearchitecture_invariants.rs";

fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .and_then(|path| path.parent())
        .expect("agent crate should live under packages/agent")
        .to_path_buf()
}

fn repo_path(path: &str) -> PathBuf {
    repo_root().join(path)
}

fn read_repo_file(path: &str) -> String {
    let full_path = repo_path(path);
    std::fs::read_to_string(&full_path)
        .unwrap_or_else(|error| panic!("failed to read {}: {error}", full_path.display()))
}

fn git_ls_files() -> Vec<String> {
    let output = Command::new("git")
        .arg("ls-files")
        .current_dir(repo_root())
        .output()
        .expect("git ls-files should run in repository tests");
    assert!(
        output.status.success(),
        "git ls-files failed with status {:?}",
        output.status.code()
    );
    String::from_utf8(output.stdout)
        .expect("git ls-files output should be UTF-8")
        .lines()
        .map(str::to_owned)
        .collect()
}

fn source_line_count(path: &Path) -> usize {
    std::fs::read_to_string(path)
        .unwrap_or_else(|error| panic!("failed to read {}: {error}", path.display()))
        .lines()
        .count()
}

fn list_source_files(root: &Path, extensions: &[&str], files: &mut Vec<PathBuf>) {
    if root.is_file() {
        if root
            .extension()
            .and_then(|extension| extension.to_str())
            .is_some_and(|extension| extensions.contains(&extension))
        {
            files.push(root.to_path_buf());
        }
        return;
    }

    let entries = std::fs::read_dir(root)
        .unwrap_or_else(|error| panic!("failed to enumerate {}: {error}", root.display()));
    for entry in entries {
        let path = entry.expect("directory entry should be readable").path();
        if path.is_dir() {
            list_source_files(&path, extensions, files);
        } else if path
            .extension()
            .and_then(|extension| extension.to_str())
            .is_some_and(|extension| extensions.contains(&extension))
        {
            files.push(path);
        }
    }
}

fn parse_inventory(path: &str) -> HashMap<String, Vec<String>> {
    let text = read_repo_file(path);
    let mut lines = text.lines();
    assert_eq!(
        lines.next(),
        Some(
            "current_path\ttarget_path\tpackage\tarea\towner\tclassification\treason\tphase\tstatus\tnotes"
        ),
        "{path} must keep the stable HRA TSV header"
    );

    let allowed_classifications = HashSet::from([
        "retain_in_place",
        "move",
        "split",
        "merge",
        "delete",
        "asset",
        "generated",
        "external_boundary",
    ]);
    let allowed_statuses = HashSet::from([
        "pending",
        "running",
        "passed",
        "passed_after_fix",
        "failed_unfixed",
        "blocked",
        "deferred_to_successor",
    ]);

    let mut rows = HashMap::new();
    for line in lines {
        let columns: Vec<_> = line.split('\t').map(str::to_owned).collect();
        assert_eq!(
            columns.len(),
            10,
            "{path} row must have ten TSV columns: {line}"
        );
        assert!(
            !columns[0].is_empty() && !columns[1].is_empty(),
            "{path} row must include current and target paths: {line}"
        );
        assert!(
            allowed_classifications.contains(columns[5].as_str()),
            "{path} has invalid classification `{}` for {}",
            columns[5],
            columns[0]
        );
        assert!(
            allowed_statuses.contains(columns[8].as_str()),
            "{path} has invalid status `{}` for {}",
            columns[8],
            columns[0]
        );
        assert!(
            !columns[2].is_empty()
                && !columns[3].is_empty()
                && !columns[4].is_empty()
                && !columns[6].is_empty()
                && !columns[7].is_empty(),
            "{path} row must name package, area, owner, reason, and phase: {line}"
        );
        assert!(
            rows.insert(columns[0].clone(), columns).is_none(),
            "{path} has duplicate row for {line}"
        );
    }
    rows
}

#[test]
fn hierarchical_rearchitecture_scorecard_stays_formalized() {
    let scorecard = read_repo_file(SCORECARD_PATH);
    let manifest = read_repo_file(EVIDENCE_PATH);
    let inventory = read_repo_file(INVENTORY_PATH);
    let readme = read_repo_file("README.md");

    for required in [
        "# Hierarchical Rearchitecture Scorecard",
        "Current score: **37/100**",
        "Status: **running**",
        "Total weight: **100**",
        "## Folder Justification Table",
        "## Large File Budgets",
        "## Static Gates",
        "HRA-0 | Scorecard, evidence, and static-gate setup | 5 | passed_after_fix",
        "HRA-1 | Whole-repo inventory and target architecture | 8 | passed_after_fix",
        "HRA-2 | Rust app, transport, shared, and platform roots | 6 | passed_after_fix",
        "HRA-3 | Rust engine kernel and invocation hierarchy | 10 | passed_after_fix",
        "HRA-4 | Rust engine durability and authority hierarchy | 8 | passed_after_fix",
        "HRA-16 | Final adversarial review and closeout | 2 | pending",
        FILE_INVENTORY_PATH,
        MOVE_MAP_PATH,
    ] {
        assert!(
            scorecard.contains(required),
            "HRA scorecard missing required text: {required}"
        );
    }

    let score_total: u32 = scorecard
        .lines()
        .filter_map(|line| {
            let columns: Vec<_> = line.split('|').map(str::trim).collect();
            if columns.get(1).is_some_and(|cell| cell.starts_with("HRA-")) {
                columns.get(3).and_then(|cell| cell.parse::<u32>().ok())
            } else {
                None
            }
        })
        .sum();
    assert_eq!(
        score_total, 100,
        "HRA scorecard row weights must sum to 100"
    );

    for required in [
        "# Hierarchical Rearchitecture Evidence Manifest",
        "Current score: **37/100**",
        "Status: **running**",
        "| HRA-0 | passed_after_fix |",
        "## HRA-0 Red Static Gate",
    ] {
        assert!(
            manifest.contains(required),
            "HRA evidence manifest missing required text: {required}"
        );
    }

    for required in [
        "# Hierarchical Rearchitecture Inventory",
        "Status: `passed_after_fix`",
        "Machine-Readable Artifacts",
        "Allowed classifications",
        "Allowed statuses",
        "HRA-1 Baseline Counts",
    ] {
        assert!(
            inventory.contains(required),
            "HRA inventory missing required text: {required}"
        );
    }

    for required in [
        SCORECARD_PATH,
        EVIDENCE_PATH,
        INVENTORY_PATH,
        FILE_INVENTORY_PATH,
        MOVE_MAP_PATH,
        INVARIANT_TEST_PATH,
    ] {
        assert!(
            readme.contains(required),
            "README living architecture docs must link {required}"
        );
    }
}

#[test]
fn tracked_files_have_rearchitecture_inventory_rows() {
    let file_rows = parse_inventory(FILE_INVENTORY_PATH);
    let move_rows = parse_inventory(MOVE_MAP_PATH);

    let required_artifacts = [
        SCORECARD_PATH,
        EVIDENCE_PATH,
        INVENTORY_PATH,
        FILE_INVENTORY_PATH,
        MOVE_MAP_PATH,
        INVARIANT_TEST_PATH,
    ];

    for path in git_ls_files()
        .into_iter()
        .chain(required_artifacts.iter().map(|path| path.to_string()))
    {
        assert!(
            file_rows.contains_key(&path),
            "tracked file missing HRA file-inventory row: {path}"
        );
        assert!(
            move_rows.contains_key(&path),
            "tracked file missing HRA move-map row: {path}"
        );
    }
}

#[test]
fn rust_source_root_has_only_allowed_entry_files() {
    let allowed = HashSet::from(["lib.rs", "main.rs"]);
    let mut unexpected = Vec::new();
    for entry in std::fs::read_dir(repo_path("packages/agent/src"))
        .expect("Rust source root should be readable")
    {
        let path = entry.expect("source root entry should be readable").path();
        if path.extension().and_then(|extension| extension.to_str()) == Some("rs") {
            let file_name = path
                .file_name()
                .and_then(|name| name.to_str())
                .expect("Rust source file should have UTF-8 name");
            if !allowed.contains(file_name) {
                unexpected.push(
                    path.strip_prefix(repo_root())
                        .unwrap()
                        .display()
                        .to_string(),
                );
            }
        }
    }

    assert!(
        unexpected.is_empty(),
        "Rust source root must contain only true crate entry files; move these into owned modules: {unexpected:#?}"
    );
}

#[test]
fn rust_app_transport_shared_roots_are_owned() {
    let required = [
        "packages/agent/src/app/cli/mod.rs",
        "packages/agent/src/app/bootstrap/mod.rs",
        "packages/agent/src/app/bootstrap/config.rs",
        "packages/agent/src/app/bootstrap/server.rs",
        "packages/agent/src/app/health/mod.rs",
        "packages/agent/src/app/health/metrics.rs",
        "packages/agent/src/app/lifecycle/mod.rs",
        "packages/agent/src/app/lifecycle/onboarding/mod.rs",
        "packages/agent/src/app/lifecycle/shutdown.rs",
        "packages/agent/src/transport/http/auth.rs",
        "packages/agent/src/transport/engine/contracts.rs",
        "packages/agent/src/transport/engine/mod.rs",
        "packages/agent/src/transport/engine/socket/mod.rs",
        "packages/agent/src/transport/runtime/setup.rs",
        "packages/agent/src/shared/foundation/mod.rs",
        "packages/agent/src/shared/protocol/mod.rs",
        "packages/agent/src/shared/observability/mod.rs",
        "packages/agent/src/shared/storage/mod.rs",
    ];
    let banned = [
        "packages/agent/src/main_cli.rs",
        "packages/agent/src/main_runtime.rs",
        "packages/agent/src/main_tests.rs",
        "packages/agent/src/app/config.rs",
        "packages/agent/src/app/disk.rs",
        "packages/agent/src/app/health.rs",
        "packages/agent/src/app/metrics.rs",
        "packages/agent/src/app/onboarding",
        "packages/agent/src/app/server.rs",
        "packages/agent/src/app/shutdown.rs",
        "packages/agent/src/transport/auth.rs",
        "packages/agent/src/transport/contracts.rs",
        "packages/agent/src/transport/engine.rs",
        "packages/agent/src/transport/engine_ws",
        "packages/agent/src/transport/engine_ws.rs",
        "packages/agent/src/transport/setup.rs",
        "packages/agent/src/shared/errors",
        "packages/agent/src/shared/logging",
        "packages/agent/src/shared/storage.rs",
        "packages/agent/src/shared/foundation/paths.rs",
        "packages/agent/src/shared/foundation/profile.rs",
        "packages/agent/src/shared/protocol/events.rs",
        "packages/agent/src/shared/protocol/messages.rs",
    ];

    let missing: Vec<_> = required
        .iter()
        .copied()
        .filter(|path| !repo_path(path).exists())
        .collect();
    let present_banned: Vec<_> = banned
        .iter()
        .copied()
        .filter(|path| repo_path(path).exists())
        .collect();

    assert!(
        missing.is_empty() && present_banned.is_empty(),
        "Rust app/transport/shared HRA-2 roots are not clean; missing: {missing:#?}; old paths still present: {present_banned:#?}"
    );
}

#[test]
fn rust_engine_root_has_no_unowned_flat_modules() {
    let mut unexpected = Vec::new();
    for entry in
        std::fs::read_dir(repo_path("packages/agent/src/engine")).expect("engine root readable")
    {
        let path = entry.expect("engine entry should be readable").path();
        if path.extension().and_then(|extension| extension.to_str()) == Some("rs")
            && path.file_name().and_then(|name| name.to_str()) != Some("mod.rs")
        {
            unexpected.push(
                path.strip_prefix(repo_root())
                    .unwrap()
                    .display()
                    .to_string(),
            );
        }
    }

    assert!(
        unexpected.is_empty(),
        "Rust engine root must be subsystem folders plus mod.rs, not unowned flat modules: {unexpected:#?}"
    );
}

#[test]
fn rust_engine_subsystem_roots_are_owned() {
    let required_files = [
        "packages/agent/src/engine/authority/mod.rs",
        "packages/agent/src/engine/authority/grants/mod.rs",
        "packages/agent/src/engine/catalog/mod.rs",
        "packages/agent/src/engine/catalog/registry/mod.rs",
        "packages/agent/src/engine/durability/mod.rs",
        "packages/agent/src/engine/durability/ledger/mod.rs",
        "packages/agent/src/engine/durability/queue/mod.rs",
        "packages/agent/src/engine/durability/resources/store/mod.rs",
        "packages/agent/src/engine/invocation/mod.rs",
        "packages/agent/src/engine/invocation/host/mod.rs",
        "packages/agent/src/engine/kernel/mod.rs",
        "packages/agent/src/engine/kernel/types/mod.rs",
        "packages/agent/src/engine/kernel/types/catalog.rs",
        "packages/agent/src/engine/kernel/types/function.rs",
        "packages/agent/src/engine/kernel/types/trigger.rs",
        "packages/agent/src/engine/kernel/types/worker.rs",
        "packages/agent/src/engine/primitives/resource/mod.rs",
        "packages/agent/src/engine/primitives/ui/mod.rs",
        "packages/agent/src/engine/runtime/mod.rs",
        "packages/agent/src/engine/runtime/external_workers.rs",
        "packages/agent/src/engine/runtime/worker_protocol.rs",
    ];
    let banned_paths = [
        "packages/agent/src/engine/capabilities.rs",
        "packages/agent/src/engine/compensation.rs",
        "packages/agent/src/engine/discovery.rs",
        "packages/agent/src/engine/errors.rs",
        "packages/agent/src/engine/external.rs",
        "packages/agent/src/engine/grants",
        "packages/agent/src/engine/grants.rs",
        "packages/agent/src/engine/host",
        "packages/agent/src/engine/host.rs",
        "packages/agent/src/engine/ids.rs",
        "packages/agent/src/engine/invocation.rs",
        "packages/agent/src/engine/ledger",
        "packages/agent/src/engine/ledger.rs",
        "packages/agent/src/engine/leases.rs",
        "packages/agent/src/engine/policy.rs",
        "packages/agent/src/engine/protocol.rs",
        "packages/agent/src/engine/queue",
        "packages/agent/src/engine/queue.rs",
        "packages/agent/src/engine/registry",
        "packages/agent/src/engine/registry.rs",
        "packages/agent/src/engine/resources",
        "packages/agent/src/engine/schema.rs",
        "packages/agent/src/engine/state.rs",
        "packages/agent/src/engine/streams.rs",
        "packages/agent/src/engine/triggers.rs",
        "packages/agent/src/engine/types.rs",
        "packages/agent/src/engine/primitives/resource.rs",
        "packages/agent/src/engine/primitives/ui.rs",
    ];

    let missing: Vec<_> = required_files
        .iter()
        .copied()
        .filter(|path| !repo_path(path).exists())
        .collect();
    let present_banned: Vec<_> = banned_paths
        .iter()
        .copied()
        .filter(|path| repo_path(path).exists())
        .collect();

    assert!(
        missing.is_empty() && present_banned.is_empty(),
        "Rust engine HRA-3/HRA-4 subsystem roots are not clean; missing: {missing:#?}; old paths still present: {present_banned:#?}"
    );
}

#[test]
fn rust_engine_has_no_same_name_file_folder_pairs() {
    let mut pairs = Vec::new();
    let mut source_files = Vec::new();
    list_source_files(
        &repo_path("packages/agent/src/engine"),
        &["rs"],
        &mut source_files,
    );
    for file in source_files {
        let sibling_folder = file.with_extension("");
        if sibling_folder.is_dir() {
            pairs.push(
                file.strip_prefix(repo_root())
                    .unwrap()
                    .display()
                    .to_string(),
            );
        }
    }

    assert!(
        pairs.is_empty(),
        "Rust engine must not retain avoidable same-name file/folder module pairs: {pairs:#?}"
    );
}

#[test]
fn ios_sources_do_not_use_broad_views_network_database_buckets() {
    let banned = [
        "packages/ios-app/Sources/UI/Views",
        "packages/ios-app/Sources/Engine/Network",
        "packages/ios-app/Sources/Engine/Database",
        "packages/ios-app/Sources/Engine/EventStore",
        "packages/ios-app/Sources/Session/ViewModels/Managers",
        "packages/ios-app/Sources/Session/ViewModels/Utilities",
        "packages/ios-app/Sources/Support/Utilities",
        "packages/ios-app/Sources/Support/Extensions",
    ];

    let present: Vec<_> = banned
        .iter()
        .copied()
        .filter(|path| repo_path(path).exists())
        .collect();

    assert!(
        present.is_empty(),
        "iOS sources must not retain broad technical buckets after HRA closeout: {present:#?}"
    );
}

#[test]
fn ios_tests_mirror_source_boundaries() {
    let required_roots = [
        "packages/ios-app/Tests/Infrastructure",
        "packages/ios-app/Tests/Engine",
        "packages/ios-app/Tests/Session",
        "packages/ios-app/Tests/UI",
        "packages/ios-app/Tests/Support",
    ];
    let banned_roots = [
        "packages/ios-app/Tests/Core",
        "packages/ios-app/Tests/Extensions",
        "packages/ios-app/Tests/Models",
        "packages/ios-app/Tests/Navigation",
        "packages/ios-app/Tests/Observability",
        "packages/ios-app/Tests/Onboarding",
        "packages/ios-app/Tests/Repositories",
        "packages/ios-app/Tests/Services",
        "packages/ios-app/Tests/Theme",
        "packages/ios-app/Tests/Utilities",
        "packages/ios-app/Tests/ViewModels",
        "packages/ios-app/Tests/Views",
    ];

    let missing: Vec<_> = required_roots
        .iter()
        .copied()
        .filter(|path| !repo_path(path).exists())
        .collect();
    let present_banned: Vec<_> = banned_roots
        .iter()
        .copied()
        .filter(|path| repo_path(path).exists())
        .collect();

    assert!(
        missing.is_empty() && present_banned.is_empty(),
        "iOS tests must mirror production feature boundaries; missing roots: {missing:#?}; old buckets still present: {present_banned:#?}"
    );
}

#[test]
fn large_files_have_decomposition_budget_rows() {
    let scorecard = read_repo_file(SCORECARD_PATH);
    let mut source_files = Vec::new();
    for (path, extensions) in [
        ("packages/agent/src", &["rs"][..]),
        ("packages/agent/tests", &["rs"][..]),
        ("packages/ios-app/Sources", &["swift"][..]),
        ("packages/ios-app/Tests", &["swift"][..]),
        ("packages/mac-app/Sources", &["swift"][..]),
        ("packages/mac-app/Tests", &["swift"][..]),
    ] {
        list_source_files(&repo_path(path), extensions, &mut source_files);
    }

    let mut missing_budget_rows = Vec::new();
    for path in source_files {
        let relative = path
            .strip_prefix(repo_root())
            .expect("source file should live under repo root")
            .display()
            .to_string();
        let extension = path.extension().and_then(|extension| extension.to_str());
        let limit = if extension == Some("rs") { 900 } else { 700 };
        let lines = source_line_count(&path);
        if lines > limit {
            let budgeted = scorecard.lines().any(|line| {
                line.contains(&format!("| `{relative}` |")) && !line.contains("| pending |")
            });
            if !budgeted {
                missing_budget_rows.push(format!("{relative} has {lines} LOC over limit {limit}"));
            }
        }
    }

    assert!(
        missing_budget_rows.is_empty(),
        "over-budget files need explicit owner, reason, and decomposition or temporary budget rows: {missing_budget_rows:#?}"
    );
}
