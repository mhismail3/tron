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
    RUNTIME_METADATA_WORKING_DIRECTORY, StreamActorScope, StreamCursor, TraceId,
};
use crate::shared::server::context::ServerRuntimeContext;
use crate::shared::server::test_support::make_test_context;

use super::service::{diff_value, status_value};
use crate::domains::capability::contract;
use crate::engine::{
    GIT_COMMIT_KIND, GIT_COMMIT_SCHEMA_ID, GIT_INDEX_CHANGE_KIND, GIT_INDEX_CHANGE_SCHEMA_ID,
    builtin_resource_type_definitions,
};

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
    assert!(value["repository"]["headTreeOid"].as_str().unwrap().len() >= 40);
    assert!(value["repository"]["indexTreeOid"].as_str().unwrap().len() >= 40);
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
async fn diff_status_preflight_is_bounded_independently_of_diff_text() {
    let repo = tempdir().expect("repo");
    init_repo(repo.path());
    write_file(repo.path(), "tracked.txt", "base\n");
    git(repo.path(), ["add", "tracked.txt"]);
    commit(repo.path(), "base");
    write_file(repo.path(), "tracked.txt", "changed\n");
    for index in 0..7_000 {
        write_file(
            repo.path(),
            &format!("untracked-status-preflight-{index:05}.txt"),
            "x\n",
        );
    }

    let value = diff(repo.path(), json!({"maxDiffBytes": 64})).await;
    assert_eq!(value["evidence"]["statusPreflightLimitBytes"], 200 * 1024);
    assert_eq!(value["evidence"]["statusPreflightTruncated"], true);
    assert!(
        value["evidence"]["statusPreflightRetainedBytes"]
            .as_u64()
            .unwrap()
            <= 200 * 1024
    );
    assert_eq!(value["diffs"]["unstaged"]["limitBytes"], 64);
    assert_eq!(value["summary"]["unstagedCount"], 1);
    assert_eq!(value["summary"]["untrackedCount"], 7_000);
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
fn model_schema_exposes_index_only_git_operations() {
    let metadata = contract::model_metadata(contract::EXECUTE_FUNCTION_ID);
    let schema_text = metadata["capabilitySchema"]["parameters"].to_string();
    assert!(schema_text.contains("git_status"));
    assert!(schema_text.contains("git_diff"));
    assert!(schema_text.contains("git_stage"));
    assert!(schema_text.contains("git_unstage"));
    assert!(schema_text.contains("git_commit"));
    assert!(schema_text.contains("expectedIndexTree"));
    for forbidden in [
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

#[test]
fn git_commit_is_execute_only_not_direct_git_domain_contract() {
    let direct_ids = super::contract::capabilities()
        .expect("git capabilities")
        .into_iter()
        .map(|spec| spec.function_id)
        .map(|function_id| function_id.into_inner())
        .collect::<Vec<_>>();

    assert!(direct_ids.contains(&"git::status".to_owned()));
    assert!(direct_ids.contains(&"git::diff".to_owned()));
    assert!(direct_ids.contains(&"git::stage".to_owned()));
    assert!(direct_ids.contains(&"git::unstage".to_owned()));
    assert!(
        !direct_ids.contains(&"git::commit".to_owned()),
        "Slice 6C git_commit must be exposed only through capability::execute"
    );

    let execute_metadata = contract::model_metadata(contract::EXECUTE_FUNCTION_ID);
    let execute_schema = execute_metadata["capabilitySchema"]["parameters"].to_string();
    assert!(execute_schema.contains("git_commit"));
}

#[test]
fn git_index_change_resource_definition_is_registered() {
    let definitions = builtin_resource_type_definitions();
    let definition = definitions
        .iter()
        .find(|definition| definition.kind == GIT_INDEX_CHANGE_KIND)
        .expect("git index change resource type");
    assert_eq!(definition.schema_id, GIT_INDEX_CHANGE_SCHEMA_ID);
    assert_eq!(
        definition.lifecycle_states,
        vec!["committed".to_owned(), "archived".to_owned()]
    );
    assert_eq!(
        definition.schema["properties"]["operation"]["enum"],
        json!(["stage", "unstage"])
    );
    assert_eq!(
        definition.required_capabilities["write"],
        json!(["git.write", "resource.write"])
    );
}

#[test]
fn git_commit_resource_definition_is_registered() {
    let definitions = builtin_resource_type_definitions();
    let definition = definitions
        .iter()
        .find(|definition| definition.kind == GIT_COMMIT_KIND)
        .expect("git commit resource type");
    assert_eq!(definition.schema_id, GIT_COMMIT_SCHEMA_ID);
    assert_eq!(
        definition.lifecycle_states,
        vec!["committed".to_owned(), "archived".to_owned()]
    );
    assert_eq!(
        definition.schema["properties"]["operation"]["enum"],
        json!(["commit"])
    );
    assert!(
        definition.schema["required"]
            .to_string()
            .contains("commitOid")
    );
    assert!(
        definition.schema["required"]
            .to_string()
            .contains("expectedIndexTree")
    );
    assert_eq!(
        definition.allowed_link_relations,
        vec![
            "evidence_for".to_owned(),
            "derived_from".to_owned(),
            "supersedes".to_owned()
        ]
    );
    assert_eq!(
        definition.required_capabilities["write"],
        json!(["git.write", "resource.write"])
    );
}

#[tokio::test]
async fn execute_git_stage_and_unstage_mutate_only_index_with_resource_and_stream() {
    let ctx = make_test_context();
    let repo = tempdir().expect("repo");
    init_repo(repo.path());
    write_file(repo.path(), "tracked.txt", "before\n");
    git(repo.path(), ["add", "tracked.txt"]);
    commit(repo.path(), "initial");
    let head = git_stdout(repo.path(), ["rev-parse", "HEAD"]);
    write_file(repo.path(), "tracked.txt", "after\n");
    let before_cursor = ctx
        .engine_host
        .latest_stream_cursor(super::GIT_LIFECYCLE_TOPIC)
        .await
        .expect("latest cursor");

    let staged = execute_git_ok(
        &ctx,
        repo.path(),
        "git-stage-success",
        json!({
            "operation": "git_stage",
            "path": "tracked.txt",
            "expectedHead": head,
            "reason": "test stage",
            "maxDiffBytes": 16,
            "idempotencyKey": "git-stage-success"
        }),
    )
    .await;
    assert_eq!(staged["details"]["primitiveOperation"], "git_stage");
    assert_eq!(staged["details"]["git"]["status"], "committed");
    assert_eq!(
        staged["details"]["git"]["evidence"]["beforeTruncated"],
        true
    );
    assert_eq!(staged["details"]["git"]["evidence"]["afterTruncated"], true);
    assert!(git_stdout(repo.path(), ["diff", "--cached", "--", "tracked.txt"]).contains("after"));
    assert_eq!(
        fs::read_to_string(repo.path().join("tracked.txt")).unwrap(),
        "after\n"
    );
    let resource_id = staged["details"]["git"]["gitIndexChangeResourceId"]
        .as_str()
        .expect("resource id");
    let inspection = ctx
        .engine_host
        .inspect_resource(resource_id)
        .await
        .expect("inspect resource")
        .expect("git index change resource");
    assert_eq!(inspection.resource.kind, "git_index_change");
    assert_eq!(inspection.resource.lifecycle, "committed");
    assert_eq!(inspection.versions[0].payload["operation"], "stage");
    assert_eq!(inspection.versions[0].payload["reason"], "test stage");
    let after_cursor = StreamCursor(
        staged["details"]["git"]["streamCursor"]
            .as_u64()
            .expect("stream cursor"),
    );
    assert!(after_cursor > before_cursor);
    assert_git_lifecycle_event(&ctx, before_cursor, resource_id).await;

    let unstaged = execute_git_ok(
        &ctx,
        repo.path(),
        "git-unstage-success",
        json!({
            "operation": "git_unstage",
            "path": "tracked.txt",
            "expectedHead": head,
            "reason": "test unstage",
            "idempotencyKey": "git-unstage-success"
        }),
    )
    .await;
    assert_eq!(unstaged["details"]["primitiveOperation"], "git_unstage");
    assert_eq!(
        git_stdout(repo.path(), ["diff", "--cached", "--", "tracked.txt"]),
        ""
    );
    assert!(git_stdout(repo.path(), ["diff", "--", "tracked.txt"]).contains("after"));
}

#[tokio::test]
async fn execute_git_commit_creates_one_commit_with_resource_and_stream() {
    let ctx = make_test_context();
    let repo = tempdir().expect("repo");
    init_repo(repo.path());
    write_file(repo.path(), "tracked.txt", "before\n");
    git(repo.path(), ["add", "tracked.txt"]);
    commit(repo.path(), "initial");
    let parent = git_stdout(repo.path(), ["rev-parse", "HEAD"]);
    write_file(repo.path(), "tracked.txt", "staged\n");
    git(repo.path(), ["add", "tracked.txt"]);
    write_file(repo.path(), "tracked.txt", "unstaged\n");
    write_file(repo.path(), "untracked.txt", "untracked\n");
    let expected_tree = status(repo.path(), json!({})).await["repository"]["indexTreeOid"]
        .as_str()
        .expect("index tree")
        .to_owned();
    let before_cursor = ctx
        .engine_host
        .latest_stream_cursor(super::GIT_LIFECYCLE_TOPIC)
        .await
        .expect("latest cursor");

    let committed = execute_git_ok(
        &ctx,
        repo.path(),
        "git-commit-success",
        json!({
            "operation": "git_commit",
            "message": "slice 6c test commit",
            "expectedHead": parent,
            "expectedIndexTree": expected_tree,
            "reason": "test commit",
            "maxDiffBytes": 16,
            "idempotencyKey": "git-commit-success"
        }),
    )
    .await;

    assert_eq!(committed["details"]["primitiveOperation"], "git_commit");
    assert_eq!(committed["details"]["git"]["status"], "committed");
    let commit_oid = committed["details"]["git"]["commitOid"]
        .as_str()
        .expect("commit oid");
    assert_eq!(git_stdout(repo.path(), ["rev-parse", "HEAD"]), commit_oid);
    assert_eq!(
        git_stdout(repo.path(), ["rev-parse", "HEAD^"]),
        committed["details"]["git"]["parentOid"]
    );
    let parents = git_stdout(repo.path(), ["rev-list", "--parents", "-n", "1", "HEAD"]);
    let parent_oids = parents.split_whitespace().skip(1).collect::<Vec<_>>();
    assert_eq!(parent_oids, vec![parent.as_str()]);
    assert_eq!(
        committed["details"]["git"]["actualTree"],
        committed["details"]["git"]["expectedIndexTree"]
    );
    assert_eq!(
        git_stdout(repo.path(), ["show", "HEAD:tracked.txt"]),
        "staged"
    );
    assert_eq!(
        fs::read_to_string(repo.path().join("tracked.txt")).unwrap(),
        "unstaged\n"
    );
    assert!(repo.path().join("untracked.txt").exists());
    assert!(git_stdout(repo.path(), ["status", "--porcelain=v1"]).contains("M tracked.txt"));
    assert!(git_stdout(repo.path(), ["status", "--porcelain=v1"]).contains("?? untracked.txt"));
    assert_eq!(
        committed["details"]["git"]["evidence"]["beforeTruncated"],
        true
    );
    assert_eq!(
        committed["details"]["git"]["evidence"]["afterTruncated"],
        true
    );
    assert_eq!(
        committed["details"]["git"]["evidence"]["hookPolicy"],
        "not invoked by commit-tree"
    );
    assert_eq!(
        committed["details"]["git"]["evidence"]["terminalPromptPolicy"],
        "disabled"
    );

    let resource_id = committed["details"]["git"]["gitCommitResourceId"]
        .as_str()
        .expect("resource id");
    let inspection = ctx
        .engine_host
        .inspect_resource(resource_id)
        .await
        .expect("inspect resource")
        .expect("git commit resource");
    assert_eq!(inspection.resource.kind, "git_commit");
    assert_eq!(inspection.resource.lifecycle, "committed");
    assert_eq!(inspection.versions[0].payload["commitOid"], commit_oid);
    assert_eq!(inspection.versions[0].payload["parentOid"], parent);
    assert_eq!(inspection.versions[0].payload["actualTree"], expected_tree);
    assert_eq!(
        inspection.versions[0].payload["message"]["subjectPreview"],
        "slice 6c test commit"
    );
    let after_cursor = StreamCursor(
        committed["details"]["git"]["streamCursor"]
            .as_u64()
            .expect("stream cursor"),
    );
    assert!(after_cursor > before_cursor);
    assert_git_commit_lifecycle_event(&ctx, before_cursor, resource_id, commit_oid).await;
}

#[tokio::test]
async fn execute_git_commit_replays_with_same_idempotency_key() {
    let ctx = make_test_context();
    let repo = tempdir().expect("repo");
    init_repo(repo.path());
    write_file(repo.path(), "tracked.txt", "before\n");
    git(repo.path(), ["add", "tracked.txt"]);
    commit(repo.path(), "initial");
    let parent = git_stdout(repo.path(), ["rev-parse", "HEAD"]);
    write_file(repo.path(), "tracked.txt", "after\n");
    git(repo.path(), ["add", "tracked.txt"]);
    let expected_tree = status(repo.path(), json!({})).await["repository"]["indexTreeOid"]
        .as_str()
        .unwrap()
        .to_owned();

    let payload = json!({
        "operation": "git_commit",
        "message": "idempotent commit",
        "expectedHead": parent,
        "expectedIndexTree": expected_tree,
        "reason": "test replay",
        "idempotencyKey": "git-commit-replay"
    });
    let first = execute_git_ok(&ctx, repo.path(), "git-commit-replay", payload.clone()).await;
    let first_commit = first["details"]["git"]["commitOid"]
        .as_str()
        .unwrap()
        .to_owned();
    let first_resource = first["details"]["git"]["gitCommitResourceId"]
        .as_str()
        .unwrap()
        .to_owned();
    let first_cursor = first["details"]["git"]["streamCursor"].as_u64().unwrap();

    let second = execute_git_ok(&ctx, repo.path(), "git-commit-replay", payload).await;
    assert_eq!(second["details"]["git"]["commitOid"], json!(first_commit));
    assert_eq!(
        second["details"]["git"]["gitCommitResourceId"],
        json!(first_resource)
    );
    assert_eq!(
        second["details"]["git"]["streamCursor"],
        json!(first_cursor)
    );
    assert_eq!(
        git_stdout(repo.path(), ["rev-list", "--count", "HEAD"]),
        "2"
    );
}

#[tokio::test]
async fn execute_git_stage_replays_with_same_idempotency_key() {
    let ctx = make_test_context();
    let repo = tempdir().expect("repo");
    init_repo(repo.path());
    write_file(repo.path(), "tracked.txt", "before\n");
    git(repo.path(), ["add", "tracked.txt"]);
    commit(repo.path(), "initial");
    let head = git_stdout(repo.path(), ["rev-parse", "HEAD"]);
    write_file(repo.path(), "tracked.txt", "after\n");

    let payload = json!({
        "operation": "git_stage",
        "path": "tracked.txt",
        "expectedHead": head,
        "reason": "test idempotent replay",
        "idempotencyKey": "git-stage-replay"
    });
    let first = execute_git_ok(&ctx, repo.path(), "git-stage-replay", payload.clone()).await;
    let first_resource = first["details"]["git"]["gitIndexChangeResourceId"]
        .as_str()
        .expect("first resource")
        .to_owned();
    let first_cursor = first["details"]["git"]["streamCursor"].as_u64().unwrap();

    let second = execute_git_ok(&ctx, repo.path(), "git-stage-replay", payload).await;
    assert_eq!(
        second["details"]["git"]["gitIndexChangeResourceId"],
        json!(first_resource)
    );
    assert_eq!(
        second["details"]["git"]["streamCursor"],
        json!(first_cursor)
    );
    let latest_cursor = ctx
        .engine_host
        .latest_stream_cursor(super::GIT_LIFECYCLE_TOPIC)
        .await
        .expect("latest cursor");
    assert_eq!(latest_cursor, StreamCursor(first_cursor));
}

#[tokio::test]
async fn execute_git_stage_and_unstage_reject_missing_and_empty_paths() {
    let ctx = make_test_context();
    let repo = tempdir().expect("repo");
    init_repo(repo.path());
    write_file(repo.path(), "a.txt", "before a\n");
    write_file(repo.path(), "b.txt", "before b\n");
    git(repo.path(), ["add", "a.txt", "b.txt"]);
    commit(repo.path(), "initial");
    let head = git_stdout(repo.path(), ["rev-parse", "HEAD"]);
    write_file(repo.path(), "a.txt", "after a\n");
    write_file(repo.path(), "b.txt", "after b\n");

    let missing_stage = execute_git_error(
        &ctx,
        repo.path(),
        "git-stage-missing-path",
        json!({
            "operation": "git_stage",
            "expectedHead": head,
            "reason": "test missing path",
            "idempotencyKey": "git-stage-missing-path"
        }),
    )
    .await;
    assert!(
        missing_stage.contains("missing path"),
        "unexpected missing stage path error: {missing_stage}"
    );

    let empty_stage = execute_git_error(
        &ctx,
        repo.path(),
        "git-stage-empty-path",
        json!({
            "operation": "git_stage",
            "path": "   ",
            "expectedHead": git_stdout(repo.path(), ["rev-parse", "HEAD"]),
            "reason": "test empty path",
            "idempotencyKey": "git-stage-empty-path"
        }),
    )
    .await;
    assert!(
        empty_stage.contains("path must not be empty"),
        "unexpected empty stage path error: {empty_stage}"
    );
    assert_eq!(
        git_stdout(repo.path(), ["diff", "--cached", "--name-only"]),
        ""
    );

    git(repo.path(), ["add", "a.txt", "b.txt"]);
    assert_eq!(
        git_stdout(repo.path(), ["diff", "--cached", "--name-only"]),
        "a.txt\nb.txt"
    );

    let missing_unstage = execute_git_error(
        &ctx,
        repo.path(),
        "git-unstage-missing-path",
        json!({
            "operation": "git_unstage",
            "expectedHead": git_stdout(repo.path(), ["rev-parse", "HEAD"]),
            "reason": "test missing unstage path",
            "idempotencyKey": "git-unstage-missing-path"
        }),
    )
    .await;
    assert!(
        missing_unstage.contains("missing path"),
        "unexpected missing unstage path error: {missing_unstage}"
    );

    let empty_unstage = execute_git_error(
        &ctx,
        repo.path(),
        "git-unstage-empty-path",
        json!({
            "operation": "git_unstage",
            "path": "",
            "expectedHead": git_stdout(repo.path(), ["rev-parse", "HEAD"]),
            "reason": "test empty unstage path",
            "idempotencyKey": "git-unstage-empty-path"
        }),
    )
    .await;
    assert!(
        empty_unstage.contains("path must not be empty"),
        "unexpected empty unstage path error: {empty_unstage}"
    );
    assert_eq!(
        git_stdout(repo.path(), ["diff", "--cached", "--name-only"]),
        "a.txt\nb.txt"
    );
}

#[tokio::test]
async fn execute_git_stage_rejects_stale_expected_head() {
    let ctx = make_test_context();
    let repo = tempdir().expect("repo");
    init_repo(repo.path());
    write_file(repo.path(), "tracked.txt", "before\n");
    git(repo.path(), ["add", "tracked.txt"]);
    commit(repo.path(), "initial");
    write_file(repo.path(), "tracked.txt", "after\n");

    let error = execute_git_error(
        &ctx,
        repo.path(),
        "git-stage-stale-head",
        json!({
            "operation": "git_stage",
            "path": "tracked.txt",
            "expectedHead": "0000000000000000000000000000000000000000",
            "reason": "test stale",
            "idempotencyKey": "git-stage-stale-head"
        }),
    )
    .await;
    assert!(
        error.contains("expectedHead mismatch"),
        "unexpected error: {error}"
    );
    assert_eq!(
        git_stdout(repo.path(), ["diff", "--cached", "--", "tracked.txt"]),
        ""
    );
}

#[tokio::test]
async fn execute_git_stage_rejects_absolute_traversal_and_missing_paths() {
    let ctx = make_test_context();
    let repo = tempdir().expect("repo");
    init_repo(repo.path());
    write_file(repo.path(), "tracked.txt", "before\n");
    git(repo.path(), ["add", "tracked.txt"]);
    commit(repo.path(), "initial");
    let head = git_stdout(repo.path(), ["rev-parse", "HEAD"]);

    let absolute = execute_git_error(
        &ctx,
        repo.path(),
        "git-stage-absolute",
        json!({
            "operation": "git_stage",
            "path": repo.path().join("tracked.txt").display().to_string(),
            "expectedHead": head,
            "reason": "test absolute",
            "idempotencyKey": "git-stage-absolute"
        }),
    )
    .await;
    assert!(
        absolute.contains("must be relative") || absolute.contains("does not allow file path"),
        "unexpected absolute path error: {absolute}"
    );

    let traversal = execute_git_error(
        &ctx,
        repo.path(),
        "git-stage-traversal",
        json!({
            "operation": "git_stage",
            "path": "../escape.txt",
            "expectedHead": head,
            "reason": "test traversal",
            "idempotencyKey": "git-stage-traversal"
        }),
    )
    .await;
    assert!(
        traversal.contains("must not escape the root")
            || traversal.contains("does not allow file path"),
        "unexpected traversal error: {traversal}"
    );

    let missing = execute_git_error(
        &ctx,
        repo.path(),
        "git-stage-missing",
        json!({
            "operation": "git_stage",
            "path": "missing.txt",
            "expectedHead": git_stdout(repo.path(), ["rev-parse", "HEAD"]),
            "reason": "test missing",
            "idempotencyKey": "git-stage-missing"
        }),
    )
    .await;
    assert!(
        missing.contains("not found"),
        "unexpected missing error: {missing}"
    );
}

#[tokio::test]
async fn execute_git_stage_rejects_non_repo_and_nested_repo_misuse() {
    let ctx = make_test_context();
    let non_repo = tempdir().expect("non repo");
    write_file(non_repo.path(), "tracked.txt", "content\n");

    let non_repo_error = execute_git_error(
        &ctx,
        non_repo.path(),
        "git-stage-non-repo",
        json!({
            "operation": "git_stage",
            "path": "tracked.txt",
            "expectedHead": "0000000000000000000000000000000000000000",
            "reason": "test non repo",
            "idempotencyKey": "git-stage-non-repo"
        }),
    )
    .await;
    assert!(
        non_repo_error.contains("not inside a Git worktree"),
        "unexpected non-repo error: {non_repo_error}"
    );

    let outer = tempdir().expect("outer repo");
    init_repo(outer.path());
    write_file(outer.path(), "outer.txt", "outer\n");
    git(outer.path(), ["add", "outer.txt"]);
    commit(outer.path(), "outer");
    let head = git_stdout(outer.path(), ["rev-parse", "HEAD"]);
    let nested = outer.path().join("nested");
    fs::create_dir(&nested).expect("nested dir");
    init_repo(&nested);
    write_file(&nested, "inner.txt", "inner\n");
    git(&nested, ["add", "inner.txt"]);
    commit(&nested, "inner");

    let nested_error = execute_git_error(
        &ctx,
        outer.path(),
        "git-stage-nested-repo",
        json!({
            "operation": "git_stage",
            "path": "nested/inner.txt",
            "expectedHead": head,
            "reason": "test nested repo misuse",
            "idempotencyKey": "git-stage-nested-repo"
        }),
    )
    .await;
    assert!(
        nested_error.contains("trusted working-directory repository"),
        "unexpected nested repo error: {nested_error}"
    );
}

#[tokio::test]
async fn execute_git_stage_rejects_conflicted_pathspecs() {
    let ctx = make_test_context();
    let repo = tempdir().expect("repo");
    init_repo(repo.path());
    write_file(repo.path(), "tracked.txt", "base\n");
    git(repo.path(), ["add", "tracked.txt"]);
    commit(repo.path(), "base");
    git(repo.path(), ["checkout", "-b", "feature"]);
    write_file(repo.path(), "tracked.txt", "feature\n");
    git(repo.path(), ["add", "tracked.txt"]);
    commit(repo.path(), "feature");
    git(repo.path(), ["checkout", "main"]);
    write_file(repo.path(), "tracked.txt", "main\n");
    git(repo.path(), ["add", "tracked.txt"]);
    commit(repo.path(), "main");
    let merge = git_failure(repo.path(), ["merge", "feature"]);
    assert!(
        merge.contains("CONFLICT") || merge.contains("conflict"),
        "unexpected merge output: {merge}"
    );
    let head = git_stdout(repo.path(), ["rev-parse", "HEAD"]);

    let error = execute_git_error(
        &ctx,
        repo.path(),
        "git-stage-conflict",
        json!({
            "operation": "git_stage",
            "path": "tracked.txt",
            "expectedHead": head,
            "reason": "test conflict",
            "maxStatusBytes": 1,
            "idempotencyKey": "git-stage-conflict"
        }),
    )
    .await;
    assert!(
        error.contains("conflicted pathspecs"),
        "unexpected conflict error: {error}"
    );
    assert!(
        git_stdout(
            repo.path(),
            ["status", "--porcelain=v1", "--", "tracked.txt"]
        )
        .contains("UU tracked.txt"),
        "conflicted pathspec must remain unmerged"
    );
}

#[tokio::test]
async fn execute_git_commit_rejects_stale_head_and_stale_index_tree_before_commit() {
    let ctx = make_test_context();
    let repo = tempdir().expect("repo");
    init_repo(repo.path());
    write_file(repo.path(), "tracked.txt", "before\n");
    git(repo.path(), ["add", "tracked.txt"]);
    commit(repo.path(), "initial");
    let parent = git_stdout(repo.path(), ["rev-parse", "HEAD"]);
    let parent_count = git_stdout(repo.path(), ["rev-list", "--count", "HEAD"]);
    write_file(repo.path(), "tracked.txt", "after\n");
    git(repo.path(), ["add", "tracked.txt"]);
    let expected_tree = status(repo.path(), json!({})).await["repository"]["indexTreeOid"]
        .as_str()
        .unwrap()
        .to_owned();

    let stale_head = execute_git_error(
        &ctx,
        repo.path(),
        "git-commit-stale-head",
        json!({
            "operation": "git_commit",
            "message": "stale head",
            "expectedHead": "0000000000000000000000000000000000000000",
            "expectedIndexTree": expected_tree,
            "reason": "test stale head",
            "idempotencyKey": "git-commit-stale-head"
        }),
    )
    .await;
    assert!(stale_head.contains("expectedHead mismatch"));

    let stale_tree = execute_git_error(
        &ctx,
        repo.path(),
        "git-commit-stale-tree",
        json!({
            "operation": "git_commit",
            "message": "stale tree",
            "expectedHead": parent,
            "expectedIndexTree": "0000000000000000000000000000000000000000",
            "reason": "test stale tree",
            "idempotencyKey": "git-commit-stale-tree"
        }),
    )
    .await;
    assert!(stale_tree.contains("expectedIndexTree mismatch"));
    assert_eq!(
        git_stdout(repo.path(), ["rev-list", "--count", "HEAD"]),
        parent_count
    );
}

#[tokio::test]
async fn execute_git_commit_rejects_stale_head_at_guarded_ref_update() {
    let repo = tempdir().expect("repo");
    init_repo(repo.path());
    write_file(repo.path(), "tracked.txt", "before\n");
    git(repo.path(), ["add", "tracked.txt"]);
    commit(repo.path(), "initial");
    let stale_expected = git_stdout(repo.path(), ["rev-parse", "HEAD"]);
    write_file(repo.path(), "tracked.txt", "concurrent\n");
    git(repo.path(), ["add", "tracked.txt"]);
    commit(repo.path(), "concurrent");
    let current_head = git_stdout(repo.path(), ["rev-parse", "HEAD"]);

    let error = super::commit::update_branch_ref_guarded(
        repo.path(),
        "refs/heads/main",
        &stale_expected,
        &stale_expected,
    )
    .expect_err("stale guarded ref update should fail")
    .to_string();

    assert!(error.contains("expectedHead changed before ref update"));
    assert_eq!(git_stdout(repo.path(), ["rev-parse", "HEAD"]), current_head);
}

#[tokio::test]
async fn execute_git_commit_rejects_resolved_merge_state() {
    let ctx = make_test_context();
    let repo = tempdir().expect("repo");
    init_repo(repo.path());
    write_file(repo.path(), "tracked.txt", "base\n");
    git(repo.path(), ["add", "tracked.txt"]);
    commit(repo.path(), "base");
    git(repo.path(), ["checkout", "-b", "feature"]);
    write_file(repo.path(), "tracked.txt", "feature\n");
    git(repo.path(), ["add", "tracked.txt"]);
    commit(repo.path(), "feature");
    git(repo.path(), ["checkout", "main"]);
    write_file(repo.path(), "tracked.txt", "main\n");
    git(repo.path(), ["add", "tracked.txt"]);
    commit(repo.path(), "main");
    let head_before = git_stdout(repo.path(), ["rev-parse", "HEAD"]);
    let merge = git_failure(repo.path(), ["merge", "feature"]);
    assert!(merge.contains("CONFLICT") || merge.contains("conflict"));
    write_file(repo.path(), "tracked.txt", "resolved\n");
    git(repo.path(), ["add", "tracked.txt"]);
    assert_eq!(
        git_stdout(repo.path(), ["ls-files", "-u", "--", "tracked.txt"]),
        ""
    );
    let expected_tree = status(repo.path(), json!({})).await["repository"]["indexTreeOid"]
        .as_str()
        .unwrap()
        .to_owned();

    let error = execute_git_error(
        &ctx,
        repo.path(),
        "git-commit-resolved-merge",
        json!({
            "operation": "git_commit",
            "message": "resolved merge",
            "expectedHead": head_before,
            "expectedIndexTree": expected_tree,
            "reason": "test resolved merge rejection",
            "idempotencyKey": "git-commit-resolved-merge"
        }),
    )
    .await;

    assert!(error.contains("in-progress merge state"));
    assert_eq!(git_stdout(repo.path(), ["rev-parse", "HEAD"]), head_before);
    let parents = git_stdout(repo.path(), ["rev-list", "--parents", "-n", "1", "HEAD"]);
    assert_eq!(parents.split_whitespace().count(), 2);
}

#[tokio::test]
async fn execute_git_commit_rejects_empty_index_detached_head_and_conflicts() {
    let ctx = make_test_context();
    let repo = tempdir().expect("repo");
    init_repo(repo.path());
    write_file(repo.path(), "tracked.txt", "base\n");
    git(repo.path(), ["add", "tracked.txt"]);
    commit(repo.path(), "base");
    let head = git_stdout(repo.path(), ["rev-parse", "HEAD"]);
    let clean_tree = status(repo.path(), json!({})).await["repository"]["indexTreeOid"]
        .as_str()
        .unwrap()
        .to_owned();
    let empty = execute_git_error(
        &ctx,
        repo.path(),
        "git-commit-empty-index",
        json!({
            "operation": "git_commit",
            "message": "empty",
            "expectedHead": head,
            "expectedIndexTree": clean_tree,
            "reason": "test empty",
            "idempotencyKey": "git-commit-empty-index"
        }),
    )
    .await;
    assert!(empty.contains("non-empty staged changes"));

    git(repo.path(), ["checkout", "--detach", "HEAD"]);
    write_file(repo.path(), "tracked.txt", "detached\n");
    git(repo.path(), ["add", "tracked.txt"]);
    let detached_tree = status(repo.path(), json!({})).await["repository"]["indexTreeOid"]
        .as_str()
        .unwrap()
        .to_owned();
    let detached = execute_git_error(
        &ctx,
        repo.path(),
        "git-commit-detached",
        json!({
            "operation": "git_commit",
            "message": "detached",
            "expectedHead": git_stdout(repo.path(), ["rev-parse", "HEAD"]),
            "expectedIndexTree": detached_tree,
            "reason": "test detached",
            "idempotencyKey": "git-commit-detached"
        }),
    )
    .await;
    assert!(detached.contains("named branch") || detached.contains("detached HEAD"));

    let conflicted = tempdir().expect("conflicted repo");
    init_repo(conflicted.path());
    write_file(conflicted.path(), "tracked.txt", "base\n");
    git(conflicted.path(), ["add", "tracked.txt"]);
    commit(conflicted.path(), "base");
    git(conflicted.path(), ["checkout", "-b", "feature"]);
    write_file(conflicted.path(), "tracked.txt", "feature\n");
    git(conflicted.path(), ["add", "tracked.txt"]);
    commit(conflicted.path(), "feature");
    git(conflicted.path(), ["checkout", "main"]);
    write_file(conflicted.path(), "tracked.txt", "main\n");
    git(conflicted.path(), ["add", "tracked.txt"]);
    commit(conflicted.path(), "main");
    let merge = git_failure(conflicted.path(), ["merge", "feature"]);
    assert!(merge.contains("CONFLICT") || merge.contains("conflict"));
    let conflict_error = execute_git_error(
        &ctx,
        conflicted.path(),
        "git-commit-conflict",
        json!({
            "operation": "git_commit",
            "message": "conflict",
            "expectedHead": git_stdout(conflicted.path(), ["rev-parse", "HEAD"]),
            "expectedIndexTree": "0000000000000000000000000000000000000000",
            "reason": "test conflict",
            "idempotencyKey": "git-commit-conflict"
        }),
    )
    .await;
    assert!(
        conflict_error.contains("conflicted")
            || conflict_error.contains("unmerged")
            || conflict_error.contains("in-progress merge state")
    );
}

#[tokio::test]
async fn execute_git_commit_rejects_bad_context_path_message_and_reason() {
    let ctx = make_test_context();
    let repo = tempdir().expect("repo");
    init_repo(repo.path());
    write_file(repo.path(), "tracked.txt", "before\n");
    git(repo.path(), ["add", "tracked.txt"]);
    commit(repo.path(), "initial");
    let head = git_stdout(repo.path(), ["rev-parse", "HEAD"]);
    write_file(repo.path(), "tracked.txt", "after\n");
    git(repo.path(), ["add", "tracked.txt"]);
    let tree = status(repo.path(), json!({})).await["repository"]["indexTreeOid"]
        .as_str()
        .unwrap()
        .to_owned();

    let no_metadata = ctx
        .engine_host
        .invoke(Invocation::new_sync(
            FunctionId::new("capability::execute").unwrap(),
            json!({
                "operation": "git_commit",
                "message": "missing metadata",
                "expectedHead": head,
                "expectedIndexTree": tree,
                "reason": "test",
                "idempotencyKey": "git-commit-missing-metadata"
            }),
            execute_context_without_working_directory(
                &ctx,
                repo.path(),
                "git-commit-missing-metadata",
            )
            .await,
        ))
        .await
        .error
        .expect("missing metadata should fail")
        .to_string();
    assert!(no_metadata.contains("trusted working directory metadata"));

    for (key, payload, needle) in [
        (
            "git-commit-absolute",
            json!({
                "operation": "git_commit",
                "path": repo.path().display().to_string(),
                "message": "absolute",
                "expectedHead": head,
                "expectedIndexTree": tree,
                "reason": "test absolute",
                "idempotencyKey": "git-commit-absolute"
            }),
            "relative",
        ),
        (
            "git-commit-traversal",
            json!({
                "operation": "git_commit",
                "path": "../escape",
                "message": "traversal",
                "expectedHead": head,
                "expectedIndexTree": tree,
                "reason": "test traversal",
                "idempotencyKey": "git-commit-traversal"
            }),
            "escape",
        ),
        (
            "git-commit-empty-message",
            json!({
                "operation": "git_commit",
                "message": "",
                "expectedHead": head,
                "expectedIndexTree": tree,
                "reason": "test empty message",
                "idempotencyKey": "git-commit-empty-message"
            }),
            "message must not be empty",
        ),
        (
            "git-commit-empty-reason",
            json!({
                "operation": "git_commit",
                "message": "empty reason",
                "expectedHead": head,
                "expectedIndexTree": tree,
                "reason": "",
                "idempotencyKey": "git-commit-empty-reason"
            }),
            "reason must not be empty",
        ),
    ] {
        let error = execute_git_error(&ctx, repo.path(), key, payload).await;
        assert!(
            error.contains(needle),
            "expected {needle:?} in error {error:?}"
        );
    }

    let non_repo = tempdir().expect("non repo");
    write_file(non_repo.path(), "tracked.txt", "content\n");
    let non_repo_error = execute_git_error(
        &ctx,
        non_repo.path(),
        "git-commit-non-repo",
        json!({
            "operation": "git_commit",
            "message": "non repo",
            "expectedHead": head,
            "expectedIndexTree": tree,
            "reason": "test non repo",
            "idempotencyKey": "git-commit-non-repo"
        }),
    )
    .await;
    assert!(non_repo_error.contains("not inside a Git worktree"));

    let outer = tempdir().expect("outer repo");
    init_repo(outer.path());
    write_file(outer.path(), "outer.txt", "outer\n");
    git(outer.path(), ["add", "outer.txt"]);
    commit(outer.path(), "outer");
    let nested = outer.path().join("nested");
    fs::create_dir(&nested).expect("nested");
    init_repo(&nested);
    write_file(&nested, "inner.txt", "inner\n");
    git(&nested, ["add", "inner.txt"]);
    commit(&nested, "inner");
    let nested_error = execute_git_error(
        &ctx,
        outer.path(),
        "git-commit-nested",
        json!({
            "operation": "git_commit",
            "path": "nested",
            "message": "nested",
            "expectedHead": git_stdout(outer.path(), ["rev-parse", "HEAD"]),
            "expectedIndexTree": git_stdout(outer.path(), ["rev-parse", "HEAD^{tree}"]),
            "reason": "test nested",
            "idempotencyKey": "git-commit-nested"
        }),
    )
    .await;
    assert!(nested_error.contains("trusted working-directory repository"));
}

#[tokio::test]
async fn execute_git_commit_suppresses_hooks_editors_signing_and_prompts() {
    let ctx = make_test_context();
    let repo = tempdir().expect("repo");
    init_repo(repo.path());
    write_file(repo.path(), "tracked.txt", "before\n");
    git(repo.path(), ["add", "tracked.txt"]);
    commit(repo.path(), "initial");
    let hook_sentinel = repo.path().join("hook-ran");
    let hooks = repo.path().join(".git/hooks");
    fs::write(
        hooks.join("pre-commit"),
        format!("#!/bin/sh\ntouch {}\nexit 1\n", shell_quote(&hook_sentinel)),
    )
    .expect("write hook");
    let mut permissions = fs::metadata(hooks.join("pre-commit"))
        .expect("hook metadata")
        .permissions();
    permissions.set_mode(0o755);
    fs::set_permissions(hooks.join("pre-commit"), permissions).expect("hook permissions");
    git(repo.path(), ["config", "commit.gpgSign", "true"]);
    git(repo.path(), ["config", "gpg.program", "/bin/false"]);
    git(repo.path(), ["config", "core.pager", "/bin/false"]);
    git(repo.path(), ["config", "credential.helper", "!/bin/false"]);

    let parent = git_stdout(repo.path(), ["rev-parse", "HEAD"]);
    write_file(repo.path(), "tracked.txt", "after\n");
    git(repo.path(), ["add", "tracked.txt"]);
    let expected_tree = status(repo.path(), json!({})).await["repository"]["indexTreeOid"]
        .as_str()
        .unwrap()
        .to_owned();
    let committed = execute_git_ok(
        &ctx,
        repo.path(),
        "git-commit-suppression",
        json!({
            "operation": "git_commit",
            "message": "suppression",
            "expectedHead": parent,
            "expectedIndexTree": expected_tree,
            "reason": "test suppression",
            "idempotencyKey": "git-commit-suppression"
        }),
    )
    .await;
    assert!(!hook_sentinel.exists(), "commit hook must not run");
    assert_eq!(
        committed["details"]["git"]["evidence"]["editorPolicy"],
        "not invoked by commit-tree"
    );
    assert_eq!(
        committed["details"]["git"]["evidence"]["pagerPolicy"],
        "disabled"
    );
    assert_eq!(
        committed["details"]["git"]["evidence"]["gpgSigningPolicy"],
        "disabled"
    );
    assert_eq!(
        committed["details"]["git"]["evidence"]["credentialPromptPolicy"],
        "disabled"
    );
    assert_eq!(
        committed["details"]["git"]["evidence"]["terminalPromptPolicy"],
        "disabled"
    );
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

async fn execute_git_ok(
    ctx: &ServerRuntimeContext,
    root: &Path,
    key: &str,
    payload: Value,
) -> Value {
    let result = ctx
        .engine_host
        .invoke(Invocation::new_sync(
            FunctionId::new("capability::execute").unwrap(),
            payload,
            execute_context_with_idempotency(ctx, root, key).await,
        ))
        .await;
    assert_eq!(result.error, None, "execute failed: {:?}", result.error);
    result.value.expect("value")
}

async fn execute_git_error(
    ctx: &ServerRuntimeContext,
    root: &Path,
    key: &str,
    payload: Value,
) -> String {
    let result = ctx
        .engine_host
        .invoke(Invocation::new_sync(
            FunctionId::new("capability::execute").unwrap(),
            payload,
            execute_context_with_idempotency(ctx, root, key).await,
        ))
        .await;
    result.error.expect("execute should fail").to_string()
}

async fn assert_git_lifecycle_event(
    ctx: &ServerRuntimeContext,
    before_cursor: StreamCursor,
    resource_id: &str,
) {
    ctx.engine_host
        .subscribe_stream(
            "git-stage-test".to_owned(),
            super::GIT_LIFECYCLE_TOPIC.to_owned(),
            before_cursor,
            crate::engine::VisibilityScope::Session,
            Some("git-stage-success-session".to_owned()),
            Some("git-stage-success-workspace".to_owned()),
        )
        .await
        .expect("subscribe");
    let page = ctx
        .engine_host
        .poll_stream(
            "git-stage-test",
            Some(before_cursor),
            10,
            &StreamActorScope::scoped(
                Some("git-stage-success-session".to_owned()),
                Some("git-stage-success-workspace".to_owned()),
            ),
        )
        .await
        .expect("poll");
    assert!(
        page.events.iter().any(|event| {
            event.topic == super::GIT_LIFECYCLE_TOPIC
                && event.payload["gitIndexChangeResourceId"] == json!(resource_id)
        }),
        "missing git lifecycle event in {:?}",
        page.events
    );
}

async fn assert_git_commit_lifecycle_event(
    ctx: &ServerRuntimeContext,
    before_cursor: StreamCursor,
    resource_id: &str,
    commit_oid: &str,
) {
    ctx.engine_host
        .subscribe_stream(
            "git-commit-test".to_owned(),
            super::GIT_LIFECYCLE_TOPIC.to_owned(),
            before_cursor,
            crate::engine::VisibilityScope::Session,
            Some("git-commit-success-session".to_owned()),
            Some("git-commit-success-workspace".to_owned()),
        )
        .await
        .expect("subscribe");
    let page = ctx
        .engine_host
        .poll_stream(
            "git-commit-test",
            Some(before_cursor),
            10,
            &StreamActorScope::scoped(
                Some("git-commit-success-session".to_owned()),
                Some("git-commit-success-workspace".to_owned()),
            ),
        )
        .await
        .expect("poll");
    assert!(
        page.events.iter().any(|event| {
            event.topic == super::GIT_LIFECYCLE_TOPIC
                && event.payload["type"] == json!("git.commit_created")
                && event.payload["gitCommitResourceId"] == json!(resource_id)
                && event.payload["commitOid"] == json!(commit_oid)
        }),
        "missing git commit lifecycle event in {:?}",
        page.events
    );
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

async fn execute_context_with_idempotency(
    ctx: &ServerRuntimeContext,
    root: &Path,
    key: &str,
) -> CausalContext {
    execute_context(ctx, root, key)
        .await
        .with_idempotency_key(key.to_owned())
}

async fn execute_context_without_working_directory(
    ctx: &ServerRuntimeContext,
    root: &Path,
    key: &str,
) -> CausalContext {
    let trace_id = TraceId::new(key).unwrap();
    let session_id = format!("{key}-session");
    let workspace_id = format!("{key}-workspace");
    let actor_id = ActorId::new(format!("agent:{session_id}")).unwrap();
    let grant_id = derive_execute_grant(ctx, &actor_id, trace_id.clone(), &session_id, root).await;
    CausalContext::new(actor_id, ActorKind::Agent, grant_id, trace_id)
        .with_scope("capability.execute")
        .with_session_id(session_id)
        .with_workspace_id(workspace_id)
        .with_runtime_metadata(RUNTIME_METADATA_PROVIDER_INVOCATION_ID, key)
        .with_runtime_metadata(RUNTIME_METADATA_PROVIDER_TYPE, "openai")
        .with_runtime_metadata(RUNTIME_METADATA_MODEL_PRIMITIVE_NAME, "execute")
        .with_runtime_metadata(RUNTIME_METADATA_RUN_ID, format!("run-{key}"))
        .with_runtime_metadata(RUNTIME_METADATA_TURN, "1")
        .with_idempotency_key(key.to_owned())
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
                "allowedResourceKinds": ["agent_state", "git_index_change"],
                "resourceSelectors": ["kind:agent_state", "kind:git_index_change"],
                "fileRoots": [root.display().to_string()],
                "networkPolicy": "none",
                "maxRisk": "medium",
                "budget": {"remainingInvocations": 3},
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

fn git_failure<const N: usize>(path: &Path, args: [&str; N]) -> String {
    let output = Command::new("git")
        .arg("-C")
        .arg(path)
        .args(args)
        .env("GIT_TERMINAL_PROMPT", "0")
        .output()
        .expect("run git");
    assert!(
        !output.status.success(),
        "git unexpectedly succeeded\nstdout:\n{}\nstderr:\n{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    format!(
        "{}{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    )
}

fn shell_quote(path: &Path) -> String {
    format!("'{}'", path.to_string_lossy().replace('\'', "'\\''"))
}
