use std::fs;
use std::path::Path;

use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use tempfile::tempdir;

use crate::engine::{
    ActorId, ActorKind, AuthorityGrantId, CausalContext, FunctionId, Invocation, InvocationResult,
    RUNTIME_METADATA_MODEL_PRIMITIVE_NAME, RUNTIME_METADATA_PROVIDER_INVOCATION_ID,
    RUNTIME_METADATA_PROVIDER_TYPE, RUNTIME_METADATA_RUN_ID, RUNTIME_METADATA_TURN,
    RUNTIME_METADATA_WORKING_DIRECTORY, TraceId,
};
use crate::shared::server::context::ServerRuntimeContext;
use crate::shared::server::test_support::make_test_context;

use super::service::{CreateDirParams, ListDirParams};
use super::*;

#[test]
fn list_dir_filters_hidden_entries_unless_requested() {
    let dir = tempdir().expect("tempdir");
    fs::create_dir(dir.path().join("visible")).expect("visible dir");
    fs::create_dir(dir.path().join(".hidden")).expect("hidden dir");
    let deps = Deps::for_home(dir.path().to_path_buf());

    let hidden_filtered = service::list_dir(
        &deps,
        ListDirParams {
            path: Some(dir.path().display().to_string()),
            show_hidden: Some(false),
            max_results: None,
        },
    )
    .expect("list without hidden");
    assert_eq!(hidden_filtered.entries.len(), 1);
    assert_eq!(hidden_filtered.entries[0].name, "visible");

    let with_hidden = service::list_dir(
        &deps,
        ListDirParams {
            path: Some(dir.path().display().to_string()),
            show_hidden: Some(true),
            max_results: None,
        },
    )
    .expect("list with hidden");
    let names = with_hidden
        .entries
        .iter()
        .map(|entry| entry.name.as_str())
        .collect::<Vec<_>>();
    assert!(names.contains(&"visible"));
    assert!(names.contains(&".hidden"));
}

#[test]
fn list_dir_sorts_directories_before_files_and_reports_truncation() {
    let dir = tempdir().expect("tempdir");
    fs::write(dir.path().join("aaa-file.txt"), "data").expect("file");
    fs::create_dir(dir.path().join("zzz-dir")).expect("dir");
    fs::create_dir(dir.path().join("aaa-dir")).expect("dir");
    let deps = Deps::for_home(dir.path().to_path_buf());

    let result = service::list_dir(
        &deps,
        ListDirParams {
            path: Some(dir.path().display().to_string()),
            show_hidden: Some(false),
            max_results: Some(2),
        },
    )
    .expect("list");

    assert!(result.truncated);
    assert_eq!(
        result
            .entries
            .iter()
            .map(|entry| (entry.name.as_str(), entry.is_directory))
            .collect::<Vec<_>>(),
        vec![("aaa-dir", true), ("zzz-dir", true)]
    );
}

#[test]
fn create_dir_is_idempotent_for_existing_directory() {
    let dir = tempdir().expect("tempdir");
    let deps = Deps::for_home(dir.path().to_path_buf());
    let target = dir.path().join("created");

    let created = service::create_dir(
        CreateDirParams {
            path: target.display().to_string(),
            recursive: Some(false),
        },
        &deps,
    )
    .expect("create");
    assert_eq!(created.created, true);
    assert!(target.is_dir());

    let replay = service::create_dir(
        CreateDirParams {
            path: target.display().to_string(),
            recursive: Some(false),
        },
        &deps,
    )
    .expect("idempotent create");
    assert_eq!(replay.created, false);
}

#[test]
fn create_dir_rejects_existing_file() {
    let dir = tempdir().expect("tempdir");
    let deps = Deps::for_home(dir.path().to_path_buf());
    let target = dir.path().join("file.txt");
    fs::write(&target, "data").expect("file");

    let error = service::create_dir(
        CreateDirParams {
            path: target.display().to_string(),
            recursive: Some(false),
        },
        &deps,
    )
    .expect_err("file cannot become directory");
    assert!(error.to_string().contains("exists but is not a directory"));
}

#[tokio::test]
async fn handlers_round_trip_workspace_browser_payloads() {
    let dir = tempdir().expect("tempdir");
    fs::create_dir(dir.path().join("project")).expect("project");
    let deps = Deps::for_home(dir.path().to_path_buf());

    let get_home = service::get_home_value(&deps).await.expect("home");
    assert_eq!(get_home["homePath"], dir.path().display().to_string());

    let listed = service::list_dir_value(
        json!({
            "path": dir.path().display().to_string(),
            "showHidden": false
        }),
        &deps,
    )
    .await
    .expect("list");
    assert_eq!(listed["entries"][0]["name"], "project");

    let created = service::create_dir_value(
        json!({
            "path": dir.path().join("from-handler").display().to_string(),
            "recursive": false
        }),
        &deps,
    )
    .await
    .expect("create");
    assert_eq!(created["created"], true);
}

#[tokio::test]
async fn agent_read_denies_parent_traversal() {
    let ctx = make_test_context();
    let root = tempdir().expect("root");
    let error = invoke_error(
        &ctx,
        contract::READ_FUNCTION,
        json!({"path": "../outside.txt"}),
        client_context(root.path(), "traversal-denied", false),
    )
    .await;
    assert!(
        error.contains("must not escape"),
        "traversal must fail closed: {error}"
    );
}

#[cfg(unix)]
#[tokio::test]
async fn agent_read_denies_symlink_escape() {
    use std::os::unix::fs::symlink;

    let ctx = make_test_context();
    let root = tempdir().expect("root");
    let outside = tempdir().expect("outside");
    fs::write(outside.path().join("secret.txt"), "secret").expect("outside file");
    symlink(
        outside.path().join("secret.txt"),
        root.path().join("link.txt"),
    )
    .expect("symlink");

    let error = invoke_error(
        &ctx,
        contract::READ_FUNCTION,
        json!({"path": "link.txt"}),
        client_context(root.path(), "symlink-denied", false),
    )
    .await;
    assert!(
        error.contains("escapes authorized root"),
        "symlink escape must fail closed: {error}"
    );
}

#[tokio::test]
async fn agent_read_bounds_binary_preview() {
    let ctx = make_test_context();
    let root = tempdir().expect("root");
    fs::write(root.path().join("bin.dat"), b"abc\0def").expect("binary");

    let value = invoke_ok(
        &ctx,
        contract::READ_FUNCTION,
        json!({"path": "bin.dat", "maxBytes": 16}),
        client_context(root.path(), "binary-read", false),
    )
    .await;
    assert_eq!(value["file"]["isBinary"], true);
    assert!(value["file"]["content"].is_null());
    assert_eq!(value["file"]["sizeBytes"], 7);
    assert_eq!(value["path"]["root"], "working_directory");
    assert!(value["path"]["canonicalPath"].is_null());
    assert!(!value.to_string().contains(root.path().to_str().unwrap()));
}

#[tokio::test]
async fn agent_search_text_is_bounded_and_skips_binary() {
    let ctx = make_test_context();
    let root = tempdir().expect("root");
    fs::write(root.path().join("one.txt"), "needle one\nneedle two\n").expect("one");
    fs::write(root.path().join("two.txt"), "needle three\n").expect("two");
    fs::write(root.path().join("bin.dat"), b"needle\0binary").expect("binary");

    let value = invoke_ok(
        &ctx,
        contract::SEARCH_TEXT_FUNCTION,
        json!({"path": ".", "query": "needle", "maxResults": 10}),
        client_context(root.path(), "search-bounded", false),
    )
    .await;
    assert!(value["matches"].as_array().unwrap().len() >= 3);
    assert_eq!(value["skippedBinaryFiles"], 1);

    let bounded = invoke_ok(
        &ctx,
        contract::SEARCH_TEXT_FUNCTION,
        json!({"path": ".", "query": "needle", "maxResults": 1}),
        client_context(root.path(), "search-result-limit", false),
    )
    .await;
    assert_eq!(bounded["matches"].as_array().unwrap().len(), 1);
}

#[tokio::test]
async fn write_preview_then_commit_records_patch_and_materialized_resources() {
    let ctx = make_test_context();
    let root = tempdir().expect("root");
    let target = root.path().join("note.txt");
    fs::write(&target, "before\n").expect("initial");
    let before_hash = sha256_hex(b"before\n");

    let preview = invoke_ok(
        &ctx,
        contract::WRITE_FUNCTION,
        json!({
            "path": "note.txt",
            "content": "after\n",
            "reason": "preview"
        }),
        client_context(root.path(), "write-preview", true),
    )
    .await;
    assert_eq!(preview["status"], "preview");
    assert_eq!(fs::read_to_string(&target).unwrap(), "before\n");
    assert_eq!(preview["resourceRefs"][0]["kind"], "patch_proposal");

    let committed = invoke_ok(
        &ctx,
        contract::WRITE_FUNCTION,
        json!({
            "path": "note.txt",
            "content": "after\n",
            "expectedHash": before_hash,
            "commit": true,
            "reason": "commit"
        }),
        client_context(root.path(), "write-commit", true),
    )
    .await;
    assert_eq!(committed["status"], "committed");
    assert_eq!(fs::read_to_string(&target).unwrap(), "after\n");
    let kinds = committed["resourceRefs"]
        .as_array()
        .unwrap()
        .iter()
        .map(|item| item["kind"].as_str().unwrap())
        .collect::<Vec<_>>();
    assert!(kinds.contains(&"patch_proposal"));
    assert!(kinds.contains(&"materialized_file"));
    assert!(
        committed["rollback"]["previousPreview"]
            .as_str()
            .unwrap()
            .contains("before")
    );
}

#[tokio::test]
async fn apply_patch_requires_hash_match_and_exact_single_match() {
    let ctx = make_test_context();
    let root = tempdir().expect("root");
    let target = root.path().join("note.txt");
    fs::write(&target, "alpha\nbeta\n").expect("initial");

    let mismatch = invoke_error(
        &ctx,
        contract::APPLY_PATCH_FUNCTION,
        json!({
            "path": "note.txt",
            "oldText": "beta",
            "newText": "gamma",
            "expectedHash": "bad",
            "commit": true
        }),
        client_context(root.path(), "patch-mismatch", true),
    )
    .await;
    assert!(mismatch.contains("expectedHash mismatch"));

    let duplicate = invoke_error(
        &ctx,
        contract::APPLY_PATCH_FUNCTION,
        json!({
            "path": "note.txt",
            "oldText": "a",
            "newText": "z"
        }),
        client_context(root.path(), "patch-duplicate", true),
    )
    .await;
    assert!(duplicate.contains("oldText must match exactly once"));

    let patched = invoke_ok(
        &ctx,
        contract::APPLY_PATCH_FUNCTION,
        json!({
            "path": "note.txt",
            "oldText": "beta",
            "newText": "gamma",
            "expectedHash": sha256_hex(b"alpha\nbeta\n"),
            "commit": true
        }),
        client_context(root.path(), "patch-commit", true),
    )
    .await;
    assert_eq!(patched["status"], "committed");
    assert_eq!(fs::read_to_string(&target).unwrap(), "alpha\ngamma\n");
}

#[tokio::test]
async fn write_commit_refuses_unverifiable_existing_hash() {
    let ctx = make_test_context();
    let root = tempdir().expect("root");
    let target = root.path().join("large.txt");
    let large = format!("header\n{}", "tail\n".repeat(70_000));
    fs::write(&target, &large).expect("large file");

    let error = invoke_error(
        &ctx,
        contract::WRITE_FUNCTION,
        json!({
            "path": "large.txt",
            "content": "replacement\n",
            "expectedHash": "missing",
            "commit": true
        }),
        client_context(root.path(), "large-write-commit", true),
    )
    .await;
    assert!(error.contains("hash is unavailable"));
    assert_eq!(fs::read_to_string(&target).unwrap(), large);
}

#[tokio::test]
async fn exact_patch_refuses_truncated_file_previews() {
    let ctx = make_test_context();
    let root = tempdir().expect("root");
    let target = root.path().join("large.txt");
    let large = format!("needle\n{}", "tail\n".repeat(70_000));
    fs::write(&target, &large).expect("large file");

    let error = invoke_error(
        &ctx,
        contract::APPLY_PATCH_FUNCTION,
        json!({
            "path": "large.txt",
            "oldText": "needle",
            "newText": "changed"
        }),
        client_context(root.path(), "large-patch-preview", true),
    )
    .await;
    assert!(error.contains("refuses files larger"));
    assert_eq!(fs::read_to_string(&target).unwrap(), large);
}

#[tokio::test]
async fn execute_filesystem_write_requires_idempotency_at_provider_boundary() {
    let ctx = make_test_context();
    let root = tempdir().expect("root");
    let trace_id = TraceId::new("execute-filesystem-write-idempotency").unwrap();
    let session_id = "fs-execute-session";
    let workspace_id = "fs-execute-workspace";
    let actor_id = ActorId::new(format!("agent:{session_id}")).unwrap();
    let grant_id = derive_execute_grant(
        &ctx,
        &actor_id,
        trace_id.clone(),
        session_id,
        workspace_id,
        root.path(),
    )
    .await;
    let error = invoke_error(
        &ctx,
        "capability::execute",
        json!({
            "operation": "filesystem_write",
            "path": "note.txt",
            "content": "content",
            "commit": true
        }),
        CausalContext::new(actor_id, ActorKind::Agent, grant_id, trace_id)
            .with_scope("capability.execute")
            .with_session_id(session_id)
            .with_workspace_id(workspace_id)
            .with_runtime_metadata(
                RUNTIME_METADATA_WORKING_DIRECTORY,
                root.path().display().to_string(),
            )
            .with_runtime_metadata(RUNTIME_METADATA_PROVIDER_INVOCATION_ID, "provider-fs-write")
            .with_runtime_metadata(RUNTIME_METADATA_PROVIDER_TYPE, "openai")
            .with_runtime_metadata(RUNTIME_METADATA_MODEL_PRIMITIVE_NAME, "execute")
            .with_runtime_metadata(RUNTIME_METADATA_RUN_ID, "run-fs-write")
            .with_runtime_metadata(RUNTIME_METADATA_TURN, "1"),
    )
    .await;
    assert!(error.contains("requires an idempotencyKey"));
}

#[tokio::test]
async fn execute_rejects_legacy_file_write_operation() {
    let ctx = make_test_context();
    let root = tempdir().expect("root");
    let target = root.path().join("legacy.txt");
    let error = invoke_error(
        &ctx,
        "capability::execute",
        json!({
            "operation": "file_write",
            "path": "legacy.txt",
            "content": "bypass"
        }),
        execute_context(&ctx, root.path(), "legacy-file-write-rejected", true).await,
    )
    .await;
    assert!(error.contains("Unsupported primitive execute operation 'file_write'"));
    assert!(!target.exists());
}

#[tokio::test]
async fn execute_filesystem_write_commit_refuses_truncated_existing_hash() {
    let ctx = make_test_context();
    let root = tempdir().expect("root");
    let target = root.path().join("large.txt");
    let large = format!("header\n{}", "tail\n".repeat(70_000));
    fs::write(&target, &large).expect("large file");

    let error = invoke_error(
        &ctx,
        "capability::execute",
        json!({
            "operation": "filesystem_write",
            "path": "large.txt",
            "content": "replacement\n",
            "expectedHash": "missing",
            "commit": true
        }),
        execute_context(&ctx, root.path(), "execute-large-write-refused", true).await,
    )
    .await;
    assert!(error.contains("hash is unavailable"));
    assert_eq!(fs::read_to_string(&target).unwrap(), large);
}

#[tokio::test]
async fn execute_filesystem_apply_patch_refuses_truncated_preview() {
    let ctx = make_test_context();
    let root = tempdir().expect("root");
    let target = root.path().join("large.txt");
    let large = format!("needle\n{}", "tail\n".repeat(70_000));
    fs::write(&target, &large).expect("large file");

    let error = invoke_error(
        &ctx,
        "capability::execute",
        json!({
            "operation": "filesystem_apply_patch",
            "path": "large.txt",
            "oldText": "needle",
            "newText": "changed",
            "commit": true
        }),
        execute_context(&ctx, root.path(), "execute-large-patch-refused", true).await,
    )
    .await;
    assert!(error.contains("refuses files larger"));
    assert_eq!(fs::read_to_string(&target).unwrap(), large);
}

async fn invoke_ok(
    ctx: &ServerRuntimeContext,
    function_id: &str,
    payload: Value,
    causal_context: CausalContext,
) -> Value {
    let result = invoke_result(ctx, function_id, payload, causal_context).await;
    assert_eq!(result.error, None, "invoke failed: {:?}", result.error);
    result.value.expect("value")
}

async fn invoke_error(
    ctx: &ServerRuntimeContext,
    function_id: &str,
    payload: Value,
    causal_context: CausalContext,
) -> String {
    let result = invoke_result(ctx, function_id, payload, causal_context).await;
    result.error.expect("expected error").to_string()
}

async fn invoke_result(
    ctx: &ServerRuntimeContext,
    function_id: &str,
    payload: Value,
    causal_context: CausalContext,
) -> InvocationResult {
    ctx.engine_host
        .invoke(Invocation::new_sync(
            FunctionId::new(function_id).unwrap(),
            payload,
            causal_context,
        ))
        .await
}

fn client_context(root: &Path, key: &str, write: bool) -> CausalContext {
    let mut context = CausalContext::new(
        ActorId::new("engine-client").unwrap(),
        ActorKind::Client,
        AuthorityGrantId::new("engine-transport").unwrap(),
        TraceId::new(key).unwrap(),
    )
    .with_scope(READ_SCOPE)
    .with_session_id("filesystem-session")
    .with_workspace_id("filesystem-workspace")
    .with_runtime_metadata(
        RUNTIME_METADATA_WORKING_DIRECTORY,
        root.display().to_string(),
    );
    if write {
        context = context.with_scope(WRITE_SCOPE).with_idempotency_key(key);
    }
    context
}

async fn execute_context(
    ctx: &ServerRuntimeContext,
    root: &Path,
    key: &str,
    idempotent: bool,
) -> CausalContext {
    let trace_id = TraceId::new(key).unwrap();
    let session_id = format!("{key}-session");
    let workspace_id = format!("{key}-workspace");
    let actor_id = ActorId::new(format!("agent:{session_id}")).unwrap();
    let grant_id = derive_execute_grant(
        ctx,
        &actor_id,
        trace_id.clone(),
        &session_id,
        &workspace_id,
        root,
    )
    .await;
    let mut context = CausalContext::new(actor_id, ActorKind::Agent, grant_id, trace_id)
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
        .with_runtime_metadata(RUNTIME_METADATA_TURN, "1");
    if idempotent {
        context = context.with_idempotency_key(key);
    }
    context
}

async fn derive_execute_grant(
    ctx: &ServerRuntimeContext,
    actor_id: &ActorId,
    trace_id: TraceId,
    session_id: &str,
    workspace_id: &str,
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
                "budget": {"remainingInvocations": 2},
                "canDelegate": false,
                "provenance": {"source": "filesystem_test"}
            }),
            CausalContext::new(
                ActorId::new("system:filesystem-test").unwrap(),
                ActorKind::System,
                AuthorityGrantId::new("grant").unwrap(),
                trace_id,
            )
            .with_scope("grant.write")
            .with_session_id(session_id)
            .with_idempotency_key(format!("derive-{workspace_id}")),
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

fn sha256_hex(bytes: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    hex::encode(hasher.finalize())
}
