use serde_json::json;

use crate::engine::{ActorId, ActorKind, CausalContext, FunctionId, Invocation, TraceId};

fn invocation(function: &str, cwd: &std::path::Path, payload: serde_json::Value) -> Invocation {
    let workspace_effect = match function {
        "host::read" => crate::engine::WorkspaceEffect::Read,
        "host::write" | "host::edit" => crate::engine::WorkspaceEffect::ScopedWrite,
        "host::bash" => crate::engine::WorkspaceEffect::ArbitraryProcess,
        _ => crate::engine::WorkspaceEffect::None,
    };
    Invocation::new_sync(
        FunctionId::new(function).unwrap(),
        payload,
        CausalContext::new(
            ActorId::new("agent:host-test").unwrap(),
            ActorKind::Agent,
            TraceId::generate(),
        )
        .with_session_id("host-test")
        .with_working_directory(cwd.display().to_string())
        .with_declared_workspace_effect(workspace_effect),
    )
}

fn test_runtime() -> std::sync::Arc<crate::domains::worker_kernel::WorkerRuntime> {
    let context = crate::shared::server::test_support::make_test_context();
    let deps = crate::domains::registration::composition::DomainRegistrationContext::from_context(
        &context,
    );
    crate::domains::worker_kernel::registration(&deps)
        .unwrap()
        .runtime
}

#[tokio::test]
async fn read_routes_files_and_directories_through_one_contract() {
    let home = tempfile::tempdir().unwrap();
    std::fs::write(home.path().join("note.txt"), "hello").unwrap();
    let deps = super::Deps {
        runtime: test_runtime(),
    };

    let file = super::handlers::read(
        &invocation("host::read", home.path(), json!({"path":"note.txt"})),
        &deps,
    )
    .await
    .unwrap();
    assert_eq!(file["kind"], "file");
    assert_eq!(file["content"], "hello");

    let directory = super::handlers::read(
        &invocation("host::read", home.path(), json!({"path":"."})),
        &deps,
    )
    .await
    .unwrap();
    assert_eq!(directory["kind"], "directory");
    assert!(
        directory["entries"]
            .as_array()
            .unwrap()
            .iter()
            .any(|entry| entry["name"] == "note.txt")
    );
}

#[tokio::test]
async fn bash_executes_a_composed_script_with_bounded_process_custody() {
    let home = tempfile::tempdir().unwrap();
    let deps = super::Deps {
        runtime: test_runtime(),
    };
    let result = super::handlers::bash(
        &invocation(
            "host::bash",
            home.path(),
            json!({"script":"printf 'alpha\\n' | tr a-z A-Z"}),
        ),
        &deps,
    )
    .await
    .unwrap();
    assert_eq!(result["success"], true);
    assert_eq!(result["stdout"], "ALPHA\n");
    assert!(result.get("command").is_none());
}
