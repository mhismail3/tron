use super::support::*;

#[test]
fn large_source_files_have_explicit_cleanup_budget_rows() {
    let scorecard = read_repo_file("packages/agent/docs/primitive-code-cleanup-scorecard.md");
    for path in git_ls_files() {
        let extension = Path::new(&path)
            .extension()
            .and_then(|extension| extension.to_str());
        let budget = match extension {
            Some("rs") => 1_000,
            Some("swift") => 800,
            _ => continue,
        };
        if path.contains(".xcodeproj/") || path.contains("Assets.xcassets/") {
            continue;
        }
        let lines = line_count(&repo_path(&path));
        if lines > budget {
            assert!(
                scorecard.contains(&format!("| `{path}` |")),
                "large source file {path} has {lines} LOC but no cleanup budget row"
            );
        }
    }
}

#[test]
fn tracked_generated_and_cache_junk_stays_absent() {
    for path in git_ls_files() {
        assert!(
            !path.contains("/__pycache__/")
                && !path.ends_with(".pyc")
                && !path.contains("/node_modules/")
                && !path.contains("/target/")
                && !path.contains(".xcresult/"),
            "tracked generated/cache artifact must not be committed: {path}"
        );
    }
}

#[test]
fn project_gitignore_covers_recurring_local_artifacts() {
    let gitignore = read_repo_file(".gitignore");
    for pattern in [
        "**/target/",
        "packages/ios-app/.build/",
        "packages/ios-app/build/",
        "DerivedData/",
        "*.xcresult",
        "*.dSYM/",
        "node_modules/",
        "__pycache__/",
        "*.pyc",
        ".pytest_cache/",
        "scripts/artifacts/",
        "tmp/",
        "*.log",
        ".worktrees/",
    ] {
        assert!(
            gitignore.contains(pattern),
            "root .gitignore must cover recurring local artifact pattern `{pattern}`"
        );
    }
}

#[test]
fn rust_dead_dependency_artifacts_stay_removed() {
    let cargo_toml = read_repo_file("packages/agent/Cargo.toml");
    let cargo_lock = read_repo_file("packages/agent/Cargo.lock");

    for banned in [
        "fastembed",
        "sqlite-vec",
        "rquickjs",
        "rquickjs-serde",
        "resvg",
    ] {
        assert!(
            !cargo_toml.contains(banned),
            "Cargo.toml must not reintroduce dead dependency `{banned}`"
        );
        assert!(
            !cargo_lock.contains(banned),
            "Cargo.lock must not retain dead dependency `{banned}`"
        );
    }

    assert!(
        !cargo_toml.contains("\nimage = ") && !cargo_lock.contains("name = \"image\""),
        "standalone image conversion dependency must stay removed"
    );

    for banned in [
        "bytemuck",
        "chrono-tz",
        "ed25519-dalek",
        "eventsource-stream",
        "globset",
        "hmac",
        "html2text",
        "indexmap",
        "pin-project-lite",
        "portable-pty",
        "scraper",
        "unicode-normalization",
        "urlencoding",
        "assert_matches",
        "insta",
        "mockall",
        "proptest",
        "enigo",
    ] {
        assert!(
            !cargo_toml.contains(banned),
            "Cargo.toml must not retain unused direct dependency `{banned}`"
        );
    }

    let retired_asset = repo_path("packages/agent/assets/capability-search");
    assert!(
        !retired_asset.exists(),
        "retired capability-search asset bundle must stay deleted"
    );
}
