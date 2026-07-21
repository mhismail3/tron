use super::support::*;

use std::path::{Path, PathBuf};

const OWNED_TREES: &[&str] = &[
    ".codex",
    ".github",
    "scripts",
    "packages/agent/defaults",
    "packages/agent/src",
    "packages/agent/tests",
    "packages/agent/docs",
    "packages/ios-app/Sources",
    "packages/ios-app/Configuration",
    "packages/ios-app/ShareExtension",
    "packages/ios-app/Tests",
    "packages/ios-app/UITests",
    "packages/ios-app/docs",
    "packages/mac-app/Sources",
    "packages/mac-app/Configuration",
    "packages/mac-app/scripts",
    "packages/mac-app/Tests",
    "packages/mac-app/docs",
];

const REQUIRED_SINGLE_FILE_LAYOUTS: &[&str] = &[
    ".codex/environments",
    ".codex/skills/tron-ios-beta",
    "scripts/benchmarks/baselines",
    "packages/agent/defaults/profiles/chat",
    "packages/agent/defaults/profiles/default",
    "packages/agent/defaults/profiles/local",
    "packages/agent/defaults/profiles/normal",
    "packages/agent/defaults/profiles/user",
    "packages/agent/defaults/profiles/worker-poc",
    "packages/agent/docs",
    "packages/ios-app/docs/assets",
    "packages/ios-app/Sources/Assets.xcassets/AccentColor.colorset",
    "packages/ios-app/Sources/Assets.xcassets/LaunchScreenBackground.colorset",
    "packages/mac-app/Sources/Resources/Fonts",
    "packages/mac-app/Sources/Resources/Library/LoginItems/Tron Server Dev.app/Contents/MacOS",
    "packages/mac-app/Sources/Resources/Library/LoginItems/Tron Server.app/Contents/MacOS",
];

fn relative(path: &Path) -> String {
    path.strip_prefix(repo_root())
        .unwrap_or(path)
        .to_string_lossy()
        .replace('\\', "/")
}

fn inspect_tree(path: &Path, empty: &mut Vec<String>, single_file: &mut Vec<String>) {
    let mut entries = std::fs::read_dir(path)
        .unwrap_or_else(|error| panic!("failed to read {}: {error}", path.display()))
        .map(|entry| entry.expect("owned-tree entry should be readable").path())
        .collect::<Vec<_>>();
    entries.sort();

    if entries.is_empty() {
        empty.push(relative(path));
        return;
    }

    if entries.len() == 1 && entries[0].is_file() {
        let path = relative(path);
        if !REQUIRED_SINGLE_FILE_LAYOUTS.contains(&path.as_str()) {
            single_file.push(path);
        }
    }

    for child in entries.into_iter().filter(|entry| entry.is_dir()) {
        inspect_tree(&child, empty, single_file);
    }
}

fn rust_source_files(path: &Path, files: &mut Vec<PathBuf>) {
    for entry in std::fs::read_dir(path)
        .unwrap_or_else(|error| panic!("failed to read {}: {error}", path.display()))
    {
        let path = entry.expect("Rust source entry should be readable").path();
        if path.is_dir() {
            rust_source_files(&path, files);
        } else if path.extension().and_then(|extension| extension.to_str()) == Some("rs") {
            files.push(path);
        }
    }
}

#[test]
fn repository_owned_trees_have_no_empty_or_accidental_single_file_directories() {
    let mut empty = Vec::new();
    let mut single_file = Vec::new();

    for root in OWNED_TREES {
        let root = repo_path(root);
        assert!(root.is_dir(), "owned tree is missing: {}", root.display());
        inspect_tree(&root, &mut empty, &mut single_file);
    }

    assert!(
        empty.is_empty() && single_file.is_empty(),
        "repository-owned trees must not retain empty folders or one-file directory ceremony; empty: {empty:#?}; unjustified single-file directories: {single_file:#?}"
    );
}

#[test]
fn required_single_file_layout_exceptions_are_narrow_and_real() {
    for relative in REQUIRED_SINGLE_FILE_LAYOUTS {
        let directory = repo_path(relative);
        if !directory.exists() {
            // Ignored helper executables are generated only after bundling; a
            // clean checkout therefore need not contain their MacOS folders.
            assert!(
                relative.contains("LoginItems"),
                "required repository layout is missing: {relative}"
            );
            continue;
        }
        let files = std::fs::read_dir(&directory)
            .unwrap()
            .map(|entry| entry.unwrap().path())
            .collect::<Vec<PathBuf>>();
        assert_eq!(
            files.len(),
            1,
            "single-file layout exception no longer matches its narrow purpose: {relative}"
        );
        assert!(
            files[0].is_file(),
            "exception must contain one file: {relative}"
        );
    }
}

#[test]
fn every_rust_source_file_has_a_module_owner() {
    let mut files = Vec::new();
    rust_source_files(&repo_path("packages/agent/src"), &mut files);
    rust_source_files(&repo_path("packages/agent/tests"), &mut files);
    files.sort();

    let mut orphaned = Vec::new();
    for file in files {
        let stem = file.file_stem().and_then(|stem| stem.to_str()).unwrap();
        if matches!(stem, "lib" | "main" | "mod") {
            continue;
        }
        let parent = file.parent().unwrap();
        if parent == repo_path("packages/agent/tests") {
            // Every root-level file under Cargo's tests/ directory is an
            // integration-test crate entry point rather than a child module.
            continue;
        }
        let file_name = file.file_name().and_then(|name| name.to_str()).unwrap();
        let plain_declaration = format!("mod {stem}");
        let raw_declaration = format!("mod r#{stem}");
        let path_declaration = format!("\"{file_name}\"");
        let mut possible_owners = std::fs::read_dir(parent)
            .unwrap()
            .map(|entry| entry.unwrap().path())
            .filter(|sibling| sibling != &file)
            .collect::<Vec<_>>();
        // `owner/tests.rs` owns children in `owner/tests/*.rs`, which is the
        // standard alternate Rust module layout after flattening `mod.rs`.
        possible_owners.push(parent.with_extension("rs"));
        let owned = possible_owners.into_iter().any(|sibling| {
            sibling.extension().and_then(|extension| extension.to_str()) == Some("rs")
                && std::fs::read_to_string(&sibling).is_ok_and(|source| {
                    source.contains(&plain_declaration)
                        || source.contains(&raw_declaration)
                        || source.contains(&path_declaration)
                })
        });
        if !owned {
            orphaned.push(relative(&file));
        }
    }

    assert!(
        orphaned.is_empty(),
        "Rust files must be reachable from an adjacent module owner; orphaned files: {orphaned:#?}"
    );
}

#[test]
fn worker_kernel_and_dashboard_files_stay_concern_sized() {
    let mut rust_files = Vec::new();
    rust_source_files(
        &repo_path("packages/agent/src/domains/worker_kernel"),
        &mut rust_files,
    );
    let mut oversized = Vec::new();
    for file in rust_files {
        let relative = relative(&file);
        if relative.ends_with("tests.rs")
            || relative.contains("/tests/")
            || relative.ends_with("/tests.rs")
        {
            continue;
        }
        let limit = if relative.ends_with("/persistence/migration.rs") {
            // The one versioned, transactional retirement/import boundary is
            // cohesive but still explicitly capped.
            1_100
        } else {
            1_000
        };
        let lines = std::fs::read_to_string(&file).unwrap().lines().count();
        if lines > limit {
            oversized.push(format!("{relative}: {lines} > {limit}"));
        }
    }

    let dashboard = repo_path("packages/ios-app/Sources/UI/WorkerConsole");
    for entry in std::fs::read_dir(dashboard).unwrap() {
        let file = entry.unwrap().path();
        if file.extension().and_then(|extension| extension.to_str()) != Some("swift") {
            continue;
        }
        let lines = std::fs::read_to_string(&file).unwrap().lines().count();
        if lines > 600 {
            oversized.push(format!("{}: {lines} > 600", relative(&file)));
        }
    }

    assert!(
        oversized.is_empty(),
        "worker-kernel and Engine Dashboard files must retain one inspectable concern: {oversized:#?}"
    );
}
