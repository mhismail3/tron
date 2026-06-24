use super::support::*;

#[test]
fn script_runtime_helpers_are_split_and_manual_only() {
    let bootstrap_tests = "packages/agent/src/app/bootstrap/tests.rs";
    let lines = line_count(&repo_path(bootstrap_tests));
    assert!(
        lines <= 800,
        "TPC-9 bootstrap test root {bootstrap_tests} has {lines} LOC, limit 800"
    );

    for path in [
        "packages/agent/src/app/bootstrap/tests/cli.rs",
        "packages/agent/src/app/bootstrap/tests/database.rs",
        "packages/agent/src/app/bootstrap/tests/provider_auth.rs",
        "packages/agent/src/app/bootstrap/tests/server_runtime.rs",
        "packages/agent/src/app/bootstrap/tests/source_guards.rs",
    ] {
        assert!(
            repo_path(path).exists(),
            "TPC-9 expected bootstrap test owner missing: {path}"
        );
    }

    let workspace_cli = read_repo_file("scripts/tron");
    assert!(
        workspace_cli.contains("manual-deploy")
            && !workspace_cli.contains("deploy)    shift; cmd_deploy")
            && !workspace_cli.contains("  deploy          Build, test, deploy"),
        "`scripts/tron` must expose the contributor deploy path only as manual-deploy"
    );

    let installed_cli = read_repo_file("scripts/tron-cli");
    assert!(
        installed_cli.contains("manual-deploy")
            && !installed_cli.contains("dev|deploy|ci")
            && !installed_cli.contains("  deploy          Build, test, deploy"),
        "`scripts/tron-cli` must not retain the old deploy delegate command"
    );

    let manual_deploy = read_repo_file("scripts/tron.d/manual-deploy.sh");
    assert!(
        manual_deploy.contains("cmd_manual_deploy") && !manual_deploy.contains("cmd_deploy()"),
        "manual deploy module must use an explicit manual-deploy command owner"
    );

    let readme = read_repo_file("README.md");
    assert!(
        readme.contains("tron manual-deploy")
            && !readme.contains("| `tron deploy` |")
            && !readme.contains("tron deploy          #"),
        "README must document the retained contributor path as manual-deploy only"
    );

    let mut residue = Vec::new();
    for path in git_ls_files() {
        let is_mac_swift = (path.starts_with("packages/mac-app/Sources/")
            || path.starts_with("packages/mac-app/Tests/"))
            && path.ends_with(".swift");
        let is_script_text = path.starts_with("scripts/") && !path.ends_with(".icns");
        if !is_mac_swift && !is_script_text {
            continue;
        }

        let full_path = repo_path(&path);
        let Ok(source) = std::fs::read_to_string(&full_path) else {
            continue;
        };
        if source.contains("no-op") || source.contains("noop") {
            residue.push(path);
        }
    }
    assert!(
        residue.is_empty(),
        "TPC-9 Mac/scripts runtime helpers must avoid inactive-operation wording: {residue:?}"
    );
}
