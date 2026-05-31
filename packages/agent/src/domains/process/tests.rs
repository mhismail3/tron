use std::sync::Arc;

use serde_json::json;

use super::*;
use crate::domains::session::event_store::EventStore;
use crate::domains::session::event_store::sqlite::connection::{self, ConnectionConfig};
use crate::domains::session::event_store::sqlite::migrations::run_migrations;
use crate::engine::{ActorId, ActorKind, AuthorityGrantId, CausalContext, FunctionId, TraceId};

fn event_store() -> Arc<EventStore> {
    let pool = connection::new_in_memory(&ConnectionConfig::default()).unwrap();
    {
        let conn = pool.get().unwrap();
        run_migrations(&conn).unwrap();
    }
    Arc::new(EventStore::new(pool))
}

fn invocation(payload: Value, session_id: Option<&str>) -> Invocation {
    let mut causal = CausalContext::new(
        ActorId::new("agent:test").unwrap(),
        ActorKind::Agent,
        AuthorityGrantId::new("grant:test").unwrap(),
        TraceId::generate(),
    );
    if let Some(session_id) = session_id {
        causal = causal.with_session_id(session_id.to_owned());
    }
    Invocation::new_sync(FunctionId::new("process::run").unwrap(), payload, causal)
}

#[test]
fn process_run_defaults_to_session_working_directory() {
    let store = event_store();
    let created = store
        .create_session(
            "gpt-5.5",
            "/tmp/tron-process-default-cwd",
            None,
            None,
            None,
            None,
        )
        .unwrap();
    let deps = Deps::for_test(Arc::clone(&store));
    let invocation = invocation(
        json!({"command": "pwd", "executionMode": "read_only"}),
        Some(&created.session.id),
    );

    assert_eq!(
        default_cwd(&invocation, &deps),
        "/tmp/tron-process-default-cwd"
    );
}

#[test]
fn process_timeout_accepts_timeout_ms_and_timeout() {
    assert_eq!(
        command_timeout_ms(Some(&json!({"timeoutMs": 42, "timeout": 1000}))),
        42
    );
    assert_eq!(command_timeout_ms(Some(&json!({"timeout": 1000}))), 1000);
    assert_eq!(command_timeout_ms(Some(&json!({}))), DEFAULT_TIMEOUT_MS);
}

#[test]
fn process_response_schema_accepts_materialized_output_summaries() {
    let spec = contract::capabilities()
        .unwrap()
        .into_iter()
        .find(|spec| spec.function_id.as_str() == "process::run")
        .unwrap();
    crate::engine::schema::validate_payload(
        &spec.function_id,
        "response",
        spec.response_schema.as_ref().unwrap(),
        &json!({
            "stdout": "wrote result.txt\n",
            "stderr": "",
            "exitCode": 0,
            "durationMs": 12,
            "timedOut": false,
            "outputTruncated": false,
            "resourceRefs": [{
                "resourceId": "materialized_file:test",
                "kind": "materialized_file",
                "role": "updated",
                "versionId": "ver_test",
                "contentHash": "version-hash",
                "fileContentHash": "file-hash",
                "materializedPath": "/tmp/result.txt"
            }],
            "materializedOutputs": [{
                "path": "result.txt",
                "targetPath": "/tmp/result.txt",
                "resourceId": "materialized_file:test",
                "versionId": "ver_test",
                "contentHash": "file-hash",
                "sizeBytes": 7,
                "contentPreview": "result\n",
                "previewTruncated": false
            }]
        }),
    )
    .unwrap();
}

#[test]
fn process_request_schema_rejects_empty_command() {
    let spec = contract::capabilities()
        .unwrap()
        .into_iter()
        .find(|spec| spec.function_id.as_str() == "process::run")
        .unwrap();
    let err = crate::engine::schema::validate_payload(
        &spec.function_id,
        "request",
        spec.request_schema.as_ref().unwrap(),
        &json!({"command": "", "executionMode": "read_only"}),
    )
    .unwrap_err();

    assert!(err.to_string().contains("minLength 1"));
}

#[tokio::test]
async fn blank_process_command_is_rejected_before_execution() {
    let store = event_store();
    let deps = Deps::for_test(store);
    let invocation = invocation(
        json!({"command": "   ", "executionMode": "read_only"}),
        None,
    );
    let err = process_run_value(&invocation, &deps).await.unwrap_err();

    assert!(
        matches!(err, CapabilityError::InvalidParams { message } if message.contains("non-empty command"))
    );
}

#[tokio::test]
async fn write_like_read_only_process_is_rejected_before_execution() {
    let store = event_store();
    let deps = Deps::for_test(store);
    let invocation = invocation(
        json!({"command": "touch should-not-exist", "executionMode": "read_only"}),
        None,
    );
    let err = process_run_value(&invocation, &deps).await.unwrap_err();
    assert!(
        matches!(err, CapabilityError::InvalidParams { message } if message.contains("sandbox_materialized"))
    );
}

#[tokio::test]
async fn composed_read_only_file_checks_execute_in_session_worktree() {
    let store = event_store();
    let tmp = tempfile::tempdir().unwrap();
    std::fs::write(tmp.path().join("README.md"), "alpha\nbeta\ngamma\n").unwrap();
    let created = store
        .create_session(
            "gpt-5.5",
            &tmp.path().to_string_lossy(),
            None,
            None,
            None,
            None,
        )
        .unwrap();
    let deps = Deps::for_test(store);
    let invocation = invocation(
        json!({
            "command": "pwd && printf 'hi\n' && test ! -e should_not_exist.txt && test -f README.md && sed -n '1,3p' README.md",
            "executionMode": "read_only"
        }),
        Some(&created.session.id),
    );

    let value = process_run_value(&invocation, &deps).await.unwrap();
    assert_eq!(value.get("exitCode").and_then(Value::as_i64), Some(0));
    let stdout = value.get("stdout").and_then(Value::as_str).unwrap();
    assert!(stdout.contains(&tmp.path().to_string_lossy().to_string()));
    assert!(stdout.contains("hi\nalpha\nbeta\ngamma"));
    assert!(!tmp.path().join("should_not_exist.txt").exists());
}

#[tokio::test]
async fn read_only_process_rejects_paths_outside_session_worktree() {
    let store = event_store();
    let tmp = tempfile::tempdir().unwrap();
    let created = store
        .create_session(
            "gpt-5.5",
            &tmp.path().to_string_lossy(),
            None,
            None,
            None,
            None,
        )
        .unwrap();
    let deps = Deps::for_test(store);
    let cases = [
        "cat /etc/passwd",
        "git -C /tmp status --short",
        "cd /tmp && pwd",
        "cat ../secret.txt",
        "cat $HOME/.ssh/id_rsa",
    ];

    for command in cases {
        let invocation = invocation(
            json!({"command": command, "executionMode": "read_only"}),
            Some(&created.session.id),
        );
        let err = process_run_value(&invocation, &deps).await.unwrap_err();
        assert!(
            matches!(err, CapabilityError::InvalidParams { ref message } if message.contains("active session worktree")),
            "{command} should be rejected, got {err:?}"
        );
    }
}

#[tokio::test]
async fn read_only_process_allows_search_patterns_but_bounds_search_paths() {
    let store = event_store();
    let tmp = tempfile::tempdir().unwrap();
    std::fs::write(tmp.path().join("README.md"), "alpha\nneedle\n").unwrap();
    let created = store
        .create_session(
            "gpt-5.5",
            &tmp.path().to_string_lossy(),
            None,
            None,
            None,
            None,
        )
        .unwrap();
    let deps = Deps::for_test(store);
    let allowed = invocation(
        json!({"command": "grep 'needle$' README.md", "executionMode": "read_only"}),
        Some(&created.session.id),
    );

    let value = process_run_value(&allowed, &deps).await.unwrap();
    assert_eq!(value.get("exitCode").and_then(Value::as_i64), Some(0));
    assert_eq!(
        value.get("stdout").and_then(Value::as_str),
        Some("needle\n")
    );

    let denied = invocation(
        json!({"command": "grep needle /etc/passwd", "executionMode": "read_only"}),
        Some(&created.session.id),
    );
    let err = process_run_value(&denied, &deps).await.unwrap_err();
    assert!(
        matches!(err, CapabilityError::InvalidParams { message } if message.contains("active session worktree"))
    );
}

#[tokio::test]
async fn read_only_process_rejects_shell_glob_path_operands() {
    let store = event_store();
    let tmp = tempfile::tempdir().unwrap();
    std::fs::write(tmp.path().join("README.md"), "safe\n").unwrap();
    let created = store
        .create_session(
            "gpt-5.5",
            &tmp.path().to_string_lossy(),
            None,
            None,
            None,
            None,
        )
        .unwrap();
    let deps = Deps::for_test(store);
    let denied = invocation(
        json!({"command": "cat *.md", "executionMode": "read_only"}),
        Some(&created.session.id),
    );

    let err = process_run_value(&denied, &deps).await.unwrap_err();
    assert!(
        matches!(err, CapabilityError::InvalidParams { message } if message.contains("glob or brace expansion"))
    );
}

#[tokio::test]
async fn read_only_find_allows_name_globs_but_bounds_search_roots() {
    let store = event_store();
    let tmp = tempfile::tempdir().unwrap();
    std::fs::write(tmp.path().join("README.md"), "safe\n").unwrap();
    let created = store
        .create_session(
            "gpt-5.5",
            &tmp.path().to_string_lossy(),
            None,
            None,
            None,
            None,
        )
        .unwrap();
    let deps = Deps::for_test(store);
    let allowed = invocation(
        json!({"command": "find . -maxdepth 1 -name '*.md'", "executionMode": "read_only"}),
        Some(&created.session.id),
    );

    let value = process_run_value(&allowed, &deps).await.unwrap();
    assert_eq!(value.get("exitCode").and_then(Value::as_i64), Some(0));
    assert!(
        value
            .get("stdout")
            .and_then(Value::as_str)
            .is_some_and(|stdout| stdout.contains("README.md"))
    );

    let denied = invocation(
        json!({"command": "find /tmp -maxdepth 1 -name '*.md'", "executionMode": "read_only"}),
        Some(&created.session.id),
    );
    let err = process_run_value(&denied, &deps).await.unwrap_err();
    assert!(
        matches!(err, CapabilityError::InvalidParams { message } if message.contains("active session worktree"))
    );
}

#[tokio::test]
async fn read_only_process_rejects_symlink_operands_that_escape_worktree() {
    let store = event_store();
    let tmp = tempfile::tempdir().unwrap();
    let outside = tempfile::tempdir().unwrap();
    std::fs::write(outside.path().join("secret.txt"), "secret").unwrap();
    std::os::unix::fs::symlink(
        outside.path().join("secret.txt"),
        tmp.path().join("linked-secret.txt"),
    )
    .unwrap();
    let created = store
        .create_session(
            "gpt-5.5",
            &tmp.path().to_string_lossy(),
            None,
            None,
            None,
            None,
        )
        .unwrap();
    let deps = Deps::for_test(store);
    let invocation = invocation(
        json!({"command": "cat linked-secret.txt", "executionMode": "read_only"}),
        Some(&created.session.id),
    );

    let err = process_run_value(&invocation, &deps).await.unwrap_err();
    assert!(
        matches!(err, CapabilityError::InvalidParams { message } if message.contains("active session worktree"))
    );
}

#[test]
fn safe_process_environment_is_explicitly_allowlisted() {
    let env = safe_process_environment();

    assert!(!env.contains_key("OPENAI_API_KEY"));
    assert!(!env.contains_key("TRON_ENGINE_BEARER_TOKEN"));
    assert!(env.keys().all(|key| !bounds::secret_like_env_key(key)));
}

#[tokio::test]
async fn process_run_rejects_secret_like_env_payloads() {
    let store = event_store();
    let tmp = tempfile::tempdir().unwrap();
    let created = store
        .create_session(
            "gpt-5.5",
            &tmp.path().to_string_lossy(),
            None,
            None,
            None,
            None,
        )
        .unwrap();
    let deps = Deps::for_test(store);
    let invocation = invocation(
        json!({
            "command": "printf ok",
            "executionMode": "read_only",
            "env": {"API_TOKEN": "secret_ref:test"}
        }),
        Some(&created.session.id),
    );

    let err = process_run_value(&invocation, &deps).await.unwrap_err();
    assert!(
        matches!(err, CapabilityError::InvalidParams { message } if message.contains("secret-like"))
    );
}

#[tokio::test]
async fn unknown_read_only_process_is_rejected_before_execution() {
    let store = event_store();
    let deps = Deps::for_test(store);
    let target = std::env::temp_dir().join(format!(
        "tron-process-read-only-{}.txt",
        uuid::Uuid::now_v7()
    ));
    let invocation = invocation(
        json!({
            "command": format!("python3 -c 'open({:?}, \"w\").write(\"nope\")'", target),
            "executionMode": "read_only"
        }),
        None,
    );

    let err = process_run_value(&invocation, &deps).await.unwrap_err();
    assert!(
        matches!(err, CapabilityError::InvalidParams { message } if message.contains("proven low-risk"))
    );
    assert!(
        !target.exists(),
        "read_only rejection must happen before process spawn"
    );
}

#[tokio::test]
async fn process_run_requires_active_session_worktree() {
    let store = event_store();
    let deps = Deps::for_test(store);
    let invocation = invocation(
        json!({"command": "date", "executionMode": "read_only"}),
        None,
    );

    let err = process_run_value(&invocation, &deps).await.unwrap_err();
    assert!(
        matches!(err, CapabilityError::InvalidParams { message } if message.contains("active session worktree"))
    );
}

#[tokio::test]
async fn sandbox_materialized_process_declared_outputs_become_resources() {
    let store = event_store();
    let tmp = tempfile::tempdir().unwrap();
    let target = tmp.path().join("materialized").join("result.txt");
    let created = store
        .create_session(
            "gpt-5.5",
            &tmp.path().to_string_lossy(),
            None,
            None,
            None,
            None,
        )
        .unwrap();
    let deps = Deps::for_test(store);
    let invocation = invocation(
        json!({
            "command": "mkdir -p out && printf 'hello from sandbox' > out/result.txt",
            "executionMode": "sandbox_materialized",
            "expectedOutputs": [{
                "path": "out/result.txt",
                "targetPath": target.to_string_lossy()
            }],
            "retainOutput": true
        }),
        Some(&created.session.id),
    );

    let value = process_run_value(&invocation, &deps).await.unwrap();
    assert_eq!(value["exitCode"], 0);
    assert_eq!(
        std::fs::read_to_string(&target).unwrap(),
        "hello from sandbox"
    );
    let refs = value["resourceRefs"].as_array().unwrap();
    assert!(
        refs.iter()
            .any(|resource_ref| resource_ref["kind"] == "materialized_file")
    );
    assert!(
        refs.iter()
            .any(|resource_ref| resource_ref["kind"] == "execution_output")
    );
}

#[tokio::test]
async fn sandbox_materialized_relative_outputs_materialize_in_session_worktree() {
    let store = event_store();
    let tmp = tempfile::tempdir().unwrap();
    let created = store
        .create_session(
            "gpt-5.5",
            &tmp.path().to_string_lossy(),
            None,
            None,
            None,
            None,
        )
        .unwrap();
    let deps = Deps::for_test(store);
    let invocation = invocation(
        json!({
            "command": "printf 'session materialized\n' > result.txt",
            "executionMode": "sandbox_materialized",
            "expectedOutputs": [{"path": "result.txt"}],
            "retainOutput": true
        }),
        Some(&created.session.id),
    );

    let value = process_run_value(&invocation, &deps).await.unwrap();
    assert_eq!(value["exitCode"], 0);
    assert_eq!(
        std::fs::read_to_string(tmp.path().join("result.txt")).unwrap(),
        "session materialized\n"
    );
    let materialized = value["materializedOutputs"].as_array().unwrap();
    assert_eq!(materialized[0]["path"], "result.txt");
    let expected_target = tmp.path().join("result.txt").canonicalize().unwrap();
    assert_eq!(
        materialized[0]["targetPath"].as_str(),
        Some(expected_target.to_string_lossy().as_ref())
    );
    assert_eq!(materialized[0]["contentPreview"], "session materialized\n");
    let refs = value["resourceRefs"].as_array().unwrap();
    let file_ref = refs
        .iter()
        .find(|resource_ref| resource_ref["kind"] == "materialized_file")
        .unwrap();
    assert_eq!(
        file_ref["materializedPath"].as_str(),
        Some(expected_target.to_string_lossy().as_ref())
    );
    assert_eq!(file_ref["fileContentHash"], materialized[0]["contentHash"]);
}

#[tokio::test]
async fn sandbox_materialized_nested_output_parent_is_prepared_inside_sandbox() {
    let store = event_store();
    let tmp = tempfile::tempdir().unwrap();
    let created = store
        .create_session(
            "gpt-5.5",
            &tmp.path().to_string_lossy(),
            None,
            None,
            None,
            None,
        )
        .unwrap();
    let deps = Deps::for_test(store);
    let invocation = invocation(
        json!({
            "command": "printf 'nested\n' > reports/high-risk-test.txt",
            "executionMode": "sandbox_materialized",
            "expectedOutputs": [{"path": "reports/high-risk-test.txt"}],
            "retainOutput": true
        }),
        Some(&created.session.id),
    );

    let value = process_run_value(&invocation, &deps).await.unwrap();
    assert_eq!(value["exitCode"], 0);
    let materialized = value["materializedOutputs"].as_array().unwrap();
    assert_eq!(materialized[0]["path"], "reports/high-risk-test.txt");
    assert_eq!(materialized[0]["contentPreview"], "nested\n");
    assert_eq!(
        std::fs::read_to_string(tmp.path().join("reports/high-risk-test.txt")).unwrap(),
        "nested\n"
    );
}

#[tokio::test]
async fn sandbox_materialized_duplicate_target_path_rejects_before_spawn() {
    let store = event_store();
    let tmp = tempfile::tempdir().unwrap();
    let created = store
        .create_session(
            "gpt-5.5",
            &tmp.path().to_string_lossy(),
            None,
            None,
            None,
            None,
        )
        .unwrap();
    let deps = Deps::for_test(store);
    let invocation = invocation(
        json!({
            "command": "printf one > one.txt && printf two > two.txt",
            "executionMode": "sandbox_materialized",
            "expectedOutputs": [
                {"path": "one.txt", "targetPath": "collision.txt"},
                {"path": "two.txt", "targetPath": "./collision.txt"}
            ],
            "retainOutput": true
        }),
        Some(&created.session.id),
    );

    let err = process_run_value(&invocation, &deps).await.unwrap_err();
    assert!(
        matches!(err, CapabilityError::InvalidParams { message } if message.contains("duplicate targetPath"))
    );
    assert!(!tmp.path().join("collision.txt").exists());
}

#[tokio::test]
async fn sandbox_materialized_home_relative_command_write_rejects_before_spawn() {
    let store = event_store();
    let tmp = tempfile::tempdir().unwrap();
    let created = store
        .create_session(
            "gpt-5.5",
            &tmp.path().to_string_lossy(),
            None,
            None,
            None,
            None,
        )
        .unwrap();
    let deps = Deps::for_test(store);
    let invocation = invocation(
        json!({
            "command": "printf 'escape\n' > ~/.tron/workspace/reports/high-risk-test.txt",
            "executionMode": "sandbox_materialized",
            "expectedOutputs": [{"path": "reports/high-risk-test.txt"}]
        }),
        Some(&created.session.id),
    );

    let err = process_run_value(&invocation, &deps).await.unwrap_err();
    assert!(
        matches!(err, CapabilityError::InvalidParams { message } if message.contains("command write targets"))
    );
    assert!(!tmp.path().join("reports/high-risk-test.txt").exists());
}

#[tokio::test]
async fn sandbox_materialized_relative_target_path_cannot_escape_session_worktree() {
    let store = event_store();
    let tmp = tempfile::tempdir().unwrap();
    let created = store
        .create_session(
            "gpt-5.5",
            &tmp.path().to_string_lossy(),
            None,
            None,
            None,
            None,
        )
        .unwrap();
    let deps = Deps::for_test(store);
    let invocation = invocation(
        json!({
            "command": "printf 'escape\n' > result.txt",
            "executionMode": "sandbox_materialized",
            "expectedOutputs": [{"path": "result.txt", "targetPath": "../escape.txt"}]
        }),
        Some(&created.session.id),
    );

    let err = process_run_value(&invocation, &deps).await.unwrap_err();
    assert!(
        matches!(err, CapabilityError::InvalidParams { message } if message.contains("must stay inside"))
    );
    assert!(!tmp.path().parent().unwrap().join("escape.txt").exists());
}

#[tokio::test]
async fn sandbox_materialized_absolute_target_path_cannot_escape_session_worktree() {
    let store = event_store();
    let tmp = tempfile::tempdir().unwrap();
    let outside = tempfile::tempdir().unwrap();
    let created = store
        .create_session(
            "gpt-5.5",
            &tmp.path().to_string_lossy(),
            None,
            None,
            None,
            None,
        )
        .unwrap();
    let deps = Deps::for_test(store);
    let target = outside.path().join("escape.txt");
    let invocation = invocation(
        json!({
            "command": "printf 'escape\n' > result.txt",
            "executionMode": "sandbox_materialized",
            "expectedOutputs": [{"path": "result.txt", "targetPath": target.to_string_lossy()}]
        }),
        Some(&created.session.id),
    );

    let err = process_run_value(&invocation, &deps).await.unwrap_err();
    assert!(
        matches!(err, CapabilityError::InvalidParams { message } if message.contains("active session worktree"))
    );
    assert!(!target.exists());
}
