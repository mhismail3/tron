use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::process::Command;

use serde_json::{Value, json};
use tempfile::tempdir;

use crate::engine::{
    ActorId, ActorKind, AuthorityGrantId, CausalContext, FunctionId, Invocation,
    RUNTIME_METADATA_MODEL_PRIMITIVE_NAME, RUNTIME_METADATA_PROVIDER_INVOCATION_ID,
    RUNTIME_METADATA_PROVIDER_TYPE, RUNTIME_METADATA_RUN_ID, RUNTIME_METADATA_TURN,
    RUNTIME_METADATA_WORKING_DIRECTORY, TraceId,
};
use crate::shared::server::context::ServerRuntimeContext;
use crate::shared::server::test_support::make_test_context;

use super::service::{diff_value, status_value};
use crate::domains::capability::contract;

#[tokio::test]
async fn status_reports_clean_repo() {
    let repo = tempdir().expect("repo");
    init_repo(repo.path());
    write_file(repo.path(), "tracked.txt", "clean\n");
    git(repo.path(), ["add", "tracked.txt"]);
    commit(repo.path(), "initial");

    let value = status(repo.path(), json!({})).await;
    assert_eq!(value["dirty"], false);
    assert_eq!(value["repository"]["branch"], "main");
    assert_eq!(value["repository"]["detachedHead"], false);
    assert!(value["repository"]["headOid"].as_str().unwrap().len() >= 40);
    assert_eq!(value["repository"]["hasUpstream"], false);
    assert!(value["repository"]["upstream"].is_null());
}

#[tokio::test]
async fn status_reports_unstaged_staged_and_untracked_changes() {
    let repo = tempdir().expect("repo");
    init_repo(repo.path());
    write_file(repo.path(), "tracked.txt", "clean\n");
    git(repo.path(), ["add", "tracked.txt"]);
    commit(repo.path(), "initial");

    write_file(repo.path(), "tracked.txt", "unstaged\n");
    write_file(repo.path(), "staged.txt", "staged\n");
    git(repo.path(), ["add", "staged.txt"]);
    write_file(repo.path(), "untracked.txt", "untracked\n");

    let value = status(repo.path(), json!({})).await;
    assert_eq!(value["dirty"], true);
    assert_eq!(value["summary"]["stagedCount"], 1);
    assert_eq!(value["summary"]["unstagedCount"], 1);
    assert_eq!(value["summary"]["untrackedCount"], 1);
    assert_eq!(value["staged"][0]["path"], "staged.txt");
    assert_eq!(value["unstaged"][0]["path"], "tracked.txt");
    assert_eq!(value["untracked"][0], "untracked.txt");
}

#[tokio::test]
async fn status_scopes_nested_path_inside_repo() {
    let repo = tempdir().expect("repo");
    init_repo(repo.path());
    fs::create_dir(repo.path().join("src")).expect("src");
    write_file(repo.path(), "src/lib.rs", "before\n");
    write_file(repo.path(), "outside.txt", "before\n");
    git(repo.path(), ["add", "."]);
    commit(repo.path(), "initial");
    write_file(repo.path(), "src/lib.rs", "after\n");
    write_file(repo.path(), "outside.txt", "after\n");

    let value = status(repo.path(), json!({"path": "src"})).await;
    assert_eq!(value["path"]["relativePath"], "src");
    assert_eq!(value["repository"]["pathspec"], "src");
    assert_eq!(value["summary"]["unstagedCount"], 1);
    assert_eq!(value["unstaged"][0]["path"], "src/lib.rs");
}

#[tokio::test]
async fn status_reports_detached_head() {
    let repo = tempdir().expect("repo");
    init_repo(repo.path());
    write_file(repo.path(), "tracked.txt", "clean\n");
    git(repo.path(), ["add", "tracked.txt"]);
    commit(repo.path(), "initial");
    let head = git_stdout(repo.path(), ["rev-parse", "HEAD"]);
    git(repo.path(), ["checkout", "--detach", head.as_str()]);

    let value = status(repo.path(), json!({})).await;
    assert_eq!(value["repository"]["detachedHead"], true);
    assert!(value["repository"]["branch"].is_null());
    assert_eq!(value["repository"]["headOid"], head);
}

#[tokio::test]
async fn status_reports_ahead_behind_when_upstream_exists() {
    let remote = tempdir().expect("remote");
    git(remote.path(), ["init", "--bare"]);
    let repo = tempdir().expect("repo");
    git(repo.path(), ["clone", remote.path().to_str().unwrap(), "."]);
    configure_repo(repo.path());
    git(repo.path(), ["checkout", "-B", "main"]);
    write_file(repo.path(), "tracked.txt", "base\n");
    git(repo.path(), ["add", "tracked.txt"]);
    commit(repo.path(), "base");
    git(repo.path(), ["push", "-u", "origin", "main"]);
    write_file(repo.path(), "tracked.txt", "ahead\n");
    git(repo.path(), ["add", "tracked.txt"]);
    commit(repo.path(), "ahead");

    let value = status(repo.path(), json!({})).await;
    assert_eq!(value["repository"]["upstream"], "origin/main");
    assert_eq!(value["repository"]["ahead"], 1);
    assert_eq!(value["repository"]["behind"], 0);
}

#[tokio::test]
async fn status_fails_for_non_repo_path() {
    let dir = tempdir().expect("dir");
    let error = status_error(dir.path(), json!({})).await;
    assert!(
        error.contains("not inside a Git worktree"),
        "unexpected error: {error}"
    );
}

#[tokio::test]
async fn status_rejects_paths_outside_trusted_working_root() {
    let repo = tempdir().expect("repo");
    init_repo(repo.path());

    let error = status_error(repo.path(), json!({"path": "../outside.txt"})).await;
    assert!(
        error.contains("must not escape the root"),
        "unexpected error: {error}"
    );
}

#[tokio::test]
async fn diff_reports_staged_unstaged_and_truncation() {
    let repo = tempdir().expect("repo");
    init_repo(repo.path());
    write_file(repo.path(), "tracked.txt", "base\n");
    git(repo.path(), ["add", "tracked.txt"]);
    commit(repo.path(), "base");
    write_file(repo.path(), "staged.txt", "staged\n");
    git(repo.path(), ["add", "staged.txt"]);
    write_file(
        repo.path(),
        "tracked.txt",
        &format!("{}\n", "unstaged".repeat(200)),
    );

    let value = diff(repo.path(), json!({"maxDiffBytes": 20})).await;
    assert_eq!(value["summary"]["stagedCount"], 1);
    assert_eq!(value["summary"]["unstagedCount"], 1);
    assert_eq!(value["diffs"]["staged"]["truncated"], true);
    assert_eq!(value["diffs"]["unstaged"]["truncated"], true);
    assert_eq!(value["diffs"]["staged"]["limitBytes"], 20);
    assert_eq!(value["diffs"]["unstaged"]["limitBytes"], 20);
    assert!(value["diffs"]["staged"]["text"].as_str().unwrap().len() <= 20);
    assert!(value["diffs"]["unstaged"]["text"].as_str().unwrap().len() <= 20);
    assert_eq!(value["truncated"], true);
}

#[tokio::test]
async fn diff_does_not_invoke_configured_textconv_driver() {
    let repo = tempdir().expect("repo");
    init_repo(repo.path());
    let sentinel = repo.path().join("textconv-ran");
    let script = repo.path().join("textconv-spy.sh");
    fs::write(
        &script,
        format!(
            "#!/bin/sh\ntouch {}\nprintf 'textconv output\\n'\n",
            shell_quote(&sentinel)
        ),
    )
    .expect("write textconv script");
    let mut permissions = fs::metadata(&script)
        .expect("script metadata")
        .permissions();
    permissions.set_mode(0o755);
    fs::set_permissions(&script, permissions).expect("script permissions");
    write_file(repo.path(), ".gitattributes", "tracked.txt diff=spy\n");
    write_file(repo.path(), "tracked.txt", "base\n");
    git(
        repo.path(),
        ["config", "diff.spy.textconv", script.to_str().unwrap()],
    );
    git(repo.path(), ["add", ".gitattributes", "tracked.txt"]);
    commit(repo.path(), "base");
    write_file(repo.path(), "tracked.txt", "changed\n");

    let value = diff(repo.path(), json!({"maxDiffBytes": 1024})).await;
    assert_eq!(value["diffs"]["unstaged"]["truncated"], false);
    assert!(
        value["diffs"]["unstaged"]["text"]
            .as_str()
            .unwrap()
            .contains("changed")
    );
    assert!(
        !sentinel.exists(),
        "git diff invoked configured textconv despite --no-textconv"
    );
}

#[tokio::test]
async fn status_evidence_is_bounded_and_truncated() {
    let repo = tempdir().expect("repo");
    init_repo(repo.path());
    write_file(repo.path(), "tracked.txt", "base\n");
    git(repo.path(), ["add", "tracked.txt"]);
    commit(repo.path(), "base");
    for index in 0..10 {
        write_file(repo.path(), &format!("untracked-{index}.txt"), "x\n");
    }

    let value = status(repo.path(), json!({"maxStatusBytes": 10})).await;
    assert_eq!(value["evidence"]["statusTruncated"], true);
    assert!(
        value["evidence"]["statusPorcelainV1Z"]
            .as_str()
            .unwrap()
            .len()
            <= 10
    );
}

#[tokio::test]
async fn execute_git_status_uses_single_provider_tool_boundary() {
    let ctx = make_test_context();
    let repo = tempdir().expect("repo");
    init_repo(repo.path());
    write_file(repo.path(), "tracked.txt", "clean\n");
    git(repo.path(), ["add", "tracked.txt"]);
    commit(repo.path(), "initial");

    let result = ctx
        .engine_host
        .invoke(Invocation::new_sync(
            FunctionId::new("capability::execute").unwrap(),
            json!({
                "operation": "git_status",
                "path": "."
            }),
            execute_context(&ctx, repo.path(), "execute-git-status").await,
        ))
        .await;
    assert_eq!(result.error, None, "execute failed: {:?}", result.error);
    let value = result.value.expect("value");
    assert_eq!(value["details"]["primitiveOperation"], "git_status");
    assert_eq!(value["details"]["git"]["dirty"], false);
}

#[test]
fn model_schema_exposes_only_read_only_git_operations() {
    let metadata = contract::model_metadata(contract::EXECUTE_FUNCTION_ID);
    let schema_text = metadata["capabilitySchema"]["parameters"].to_string();
    assert!(schema_text.contains("git_status"));
    assert!(schema_text.contains("git_diff"));
    for forbidden in [
        "git_stage",
        "git_commit",
        "git_merge",
        "git_rebase",
        "git_reset",
        "git_push",
        "git_checkout",
    ] {
        assert!(
            !schema_text.contains(forbidden),
            "mutating git operation leaked into execute schema: {forbidden}"
        );
    }
}

async fn status(root: &Path, payload: Value) -> Value {
    status_value(&invocation(root, "git-status"), &payload)
        .await
        .expect("status")
}

async fn status_error(root: &Path, payload: Value) -> String {
    status_value(&invocation(root, "git-status-error"), &payload)
        .await
        .expect_err("status should fail")
        .to_string()
}

async fn diff(root: &Path, payload: Value) -> Value {
    diff_value(&invocation(root, "git-diff"), &payload)
        .await
        .expect("diff")
}

fn invocation(root: &Path, trace: &str) -> Invocation {
    Invocation::new_sync(
        FunctionId::new("git::status").unwrap(),
        json!({}),
        CausalContext::new(
            ActorId::new("engine-client").unwrap(),
            ActorKind::Client,
            AuthorityGrantId::new("engine-transport").unwrap(),
            TraceId::new(trace).unwrap(),
        )
        .with_scope(super::READ_SCOPE)
        .with_session_id("git-session")
        .with_workspace_id("git-workspace")
        .with_runtime_metadata(
            RUNTIME_METADATA_WORKING_DIRECTORY,
            root.display().to_string(),
        ),
    )
}

async fn execute_context(ctx: &ServerRuntimeContext, root: &Path, key: &str) -> CausalContext {
    let trace_id = TraceId::new(key).unwrap();
    let session_id = format!("{key}-session");
    let workspace_id = format!("{key}-workspace");
    let actor_id = ActorId::new(format!("agent:{session_id}")).unwrap();
    let grant_id = derive_execute_grant(ctx, &actor_id, trace_id.clone(), &session_id, root).await;
    CausalContext::new(actor_id, ActorKind::Agent, grant_id, trace_id)
        .with_scope("capability.execute")
        .with_session_id(session_id)
        .with_workspace_id(workspace_id)
        .with_runtime_metadata(
            RUNTIME_METADATA_WORKING_DIRECTORY,
            root.display().to_string(),
        )
        .with_runtime_metadata(RUNTIME_METADATA_PROVIDER_INVOCATION_ID, key)
        .with_runtime_metadata(RUNTIME_METADATA_PROVIDER_TYPE, "openai")
        .with_runtime_metadata(RUNTIME_METADATA_MODEL_PRIMITIVE_NAME, "execute")
        .with_runtime_metadata(RUNTIME_METADATA_RUN_ID, format!("run-{key}"))
        .with_runtime_metadata(RUNTIME_METADATA_TURN, "1")
}

async fn derive_execute_grant(
    ctx: &ServerRuntimeContext,
    actor_id: &ActorId,
    trace_id: TraceId,
    session_id: &str,
    root: &Path,
) -> AuthorityGrantId {
    let result = ctx
        .engine_host
        .invoke(Invocation::new_sync(
            FunctionId::new("grant::derive").unwrap(),
            json!({
                "parentGrantId": "agent-capability-runtime",
                "subjectActorId": actor_id.as_str(),
                "allowedCapabilities": ["capability::execute"],
                "allowedNamespaces": ["__no_namespace_authority__"],
                "allowedAuthorityScopes": ["capability.execute"],
                "allowedResourceKinds": ["agent_state"],
                "resourceSelectors": ["kind:agent_state"],
                "fileRoots": [root.display().to_string()],
                "networkPolicy": "none",
                "maxRisk": "medium",
                "budget": {"remainingInvocations": 1},
                "canDelegate": false,
                "provenance": {"source": "git_test"}
            }),
            CausalContext::new(
                ActorId::new("system:git-test").unwrap(),
                ActorKind::System,
                AuthorityGrantId::new("grant").unwrap(),
                trace_id,
            )
            .with_scope("grant.write")
            .with_session_id(session_id)
            .with_idempotency_key(format!("derive-{session_id}")),
        ))
        .await;
    assert_eq!(
        result.error, None,
        "grant derive failed: {:?}",
        result.error
    );
    AuthorityGrantId::new(
        result.value.unwrap()["grant"]["grantId"]
            .as_str()
            .unwrap()
            .to_owned(),
    )
    .unwrap()
}

fn init_repo(path: &Path) {
    git(path, ["init", "-b", "main"]);
    configure_repo(path);
}

fn configure_repo(path: &Path) {
    git(path, ["config", "user.name", "Tron Test"]);
    git(path, ["config", "user.email", "tron-test@invalid.local"]);
}

fn write_file(root: &Path, relative: &str, content: &str) {
    let path = root.join(relative);
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).expect("parent dir");
    }
    fs::write(path, content).expect("write file");
}

fn commit(path: &Path, message: &str) {
    git(path, ["commit", "-m", message]);
}

fn git<const N: usize>(path: &Path, args: [&str; N]) {
    let output = Command::new("git")
        .arg("-C")
        .arg(path)
        .args(args)
        .env("GIT_TERMINAL_PROMPT", "0")
        .output()
        .expect("run git");
    assert!(
        output.status.success(),
        "git failed\nstdout:\n{}\nstderr:\n{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
}

fn git_stdout<const N: usize>(path: &Path, args: [&str; N]) -> String {
    let output = Command::new("git")
        .arg("-C")
        .arg(path)
        .args(args)
        .env("GIT_TERMINAL_PROMPT", "0")
        .output()
        .expect("run git");
    assert!(
        output.status.success(),
        "git failed\nstdout:\n{}\nstderr:\n{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8_lossy(&output.stdout).trim().to_owned()
}

fn shell_quote(path: &Path) -> String {
    format!("'{}'", path.to_string_lossy().replace('\'', "'\\''"))
}
