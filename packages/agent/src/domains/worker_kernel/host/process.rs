//! Bounded trusted-local command execution.

use std::process::Stdio;
use std::time::Duration;

use serde_json::{Value, json};

use crate::engine::Invocation;

use super::super::process::{
    MAX_PROCESS_CAPTURE_BYTES, ProcessTree, trusted_local_command_path, wait_with_bounded_output,
};
use super::super::runtime::WorkerRuntime;
use super::claims::claim_process;
use super::support::resolve_path;

const MAX_PROCESS_ARGUMENTS: usize = 256;
const MAX_PROCESS_INPUT_BYTES: usize = 4 * 1_048_576;
#[cfg(unix)]
const PROCESS_ADMISSION_SCRIPT: &str = r#"
while [ -d "$1" ] && [ ! -f "$1/go" ]; do
  sleep 0.01
done
[ -f "$1/go" ] || exit 125
shift
exec "$@"
"#;

pub(in crate::domains::worker_kernel) async fn process_run(
    invocation: &Invocation,
    runtime: &WorkerRuntime,
) -> Result<Value, String> {
    let command = invocation
        .payload
        .get("command")
        .and_then(Value::as_array)
        .ok_or_else(|| "command must be an array".to_owned())?
        .iter()
        .map(|value| {
            value
                .as_str()
                .map(ToOwned::to_owned)
                .ok_or_else(|| "command entries must be strings".to_owned())
        })
        .collect::<Result<Vec<_>, _>>()?;
    if command.is_empty() || command.len() > MAX_PROCESS_ARGUMENTS {
        return Err(format!(
            "command must contain 1 to {MAX_PROCESS_ARGUMENTS} entries"
        ));
    }
    let (program, arguments) = command.split_first().expect("non-empty command");
    let cwd = invocation
        .payload
        .get("cwd")
        .and_then(Value::as_str)
        .map_or_else(
            || resolve_path(invocation, "."),
            |path| resolve_path(invocation, path),
        )?;
    let timeout = invocation
        .payload
        .get("timeoutSeconds")
        .and_then(Value::as_u64)
        .unwrap_or(300)
        .clamp(1, 7_200);
    let input = invocation.payload.get("stdin").map(|input| {
        input.as_str().map_or_else(
            || serde_json::to_vec(input).unwrap_or_default(),
            |text| text.as_bytes().to_vec(),
        )
    });
    if input
        .as_ref()
        .is_some_and(|input| input.len() > MAX_PROCESS_INPUT_BYTES)
    {
        return Err(format!(
            "process stdin exceeds the {MAX_PROCESS_INPUT_BYTES}-byte reliability ceiling"
        ));
    }
    let mut claim = claim_process(invocation, runtime).await?;
    #[cfg(unix)]
    let process_gate = match claim.as_mut() {
        Some(claim) => Some(claim.prepare_process_gate()?),
        None => None,
    };
    #[cfg(unix)]
    let mut process = if let Some(process_gate) = process_gate.as_ref() {
        let mut process = tokio::process::Command::new("/bin/sh");
        process
            .arg("-c")
            .arg(PROCESS_ADMISSION_SCRIPT)
            .arg("tron-process-admission")
            .arg(process_gate)
            .arg(program)
            .args(arguments);
        process
    } else {
        let mut process = tokio::process::Command::new(program);
        process.args(arguments);
        process
    };
    #[cfg(not(unix))]
    let mut process = {
        let mut process = tokio::process::Command::new(program);
        process.args(arguments);
        process
    };
    process
        .current_dir(&cwd)
        .env("PATH", trusted_local_command_path(None)?)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    if let Some(worker_id) = invocation.causal_context.origin_worker_id() {
        process.env(
            "TRON_WORKER_STATE_DIR",
            runtime.store().state_dir(worker_id)?,
        );
    }
    let child =
        ProcessTree::spawn(&mut process).map_err(|error| format!("start process: {error}"))?;
    if let Some(claim) = &claim {
        claim.bind_process(
            child
                .id()
                .ok_or_else(|| "spawned process did not expose a durable process id".to_owned())?,
        )?;
        #[cfg(unix)]
        claim.allow_process()?;
    }
    let output = wait_with_bounded_output(
        child,
        input,
        Duration::from_secs(timeout),
        format!("process timed out after {timeout} seconds"),
        MAX_PROCESS_CAPTURE_BYTES,
    )
    .await
    .map_err(|error| format!("wait for process: {error}"))?;
    if let Some((kind, error)) = output.input_error
        && kind != std::io::ErrorKind::BrokenPipe
    {
        return Err(format!("write process input: {error}"));
    }
    let result = Ok(json!({
        "command": command,
        "cwd": cwd,
        "status": output.status.code(),
        "success": output.status.success(),
        "stdout": String::from_utf8_lossy(&output.stdout),
        "stderr": String::from_utf8_lossy(&output.stderr),
        "stdoutTruncated": output.stdout_truncated,
        "stderrTruncated": output.stderr_truncated,
    }));
    match claim {
        Some(claim) => claim.finish(result),
        None => result,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domains::worker_kernel::persistence::WorkerStore;
    use crate::engine::{ActorId, CausalContext, FunctionId, TraceId};

    fn test_runtime(home: &std::path::Path) -> std::sync::Arc<WorkerRuntime> {
        let context = crate::shared::server::test_support::make_test_context();
        WorkerRuntime::new(
            WorkerStore::open_without_snapshot(home.to_path_buf()).unwrap(),
            context.engine_host.clone(),
            context.orchestrator.clone(),
            context.session_manager.clone(),
            context.event_store.clone(),
            context.settings_runtime.clone(),
        )
        .unwrap()
    }

    fn test_runtime_with_session(
        home: &std::path::Path,
        checkout: &std::path::Path,
    ) -> (std::sync::Arc<WorkerRuntime>, String, String) {
        let context = crate::shared::server::test_support::make_test_context();
        let session_id = context
            .session_manager
            .create_session(
                "test-model",
                checkout.to_str().unwrap(),
                Some("process claims"),
            )
            .unwrap();
        let workspace_id = context
            .event_store
            .get_session(&session_id)
            .unwrap()
            .unwrap()
            .workspace_id;
        let runtime = WorkerRuntime::new(
            WorkerStore::open_without_snapshot(home.to_path_buf()).unwrap(),
            context.engine_host,
            context.orchestrator,
            context.session_manager,
            context.event_store,
            context.settings_runtime,
        )
        .unwrap();
        (runtime, session_id, workspace_id)
    }

    fn workspace_process(
        checkout: &std::path::Path,
        session_id: &str,
        workspace_id: &str,
        seconds: f64,
    ) -> Invocation {
        Invocation::new_sync(
            FunctionId::new("worker_kernel::process_run").unwrap(),
            json!({
                "command":["python3","-c",format!("import time; time.sleep({seconds})")],
                "timeoutSeconds":5
            }),
            CausalContext::new(
                ActorId::new(format!("agent:{session_id}")).unwrap(),
                crate::engine::ActorKind::Agent,
                TraceId::generate(),
            )
            .with_session_id(session_id)
            .with_workspace_id(workspace_id)
            .with_working_directory(checkout.display().to_string())
            .with_declared_workspace_effect(crate::engine::WorkspaceEffect::ArbitraryProcess),
        )
    }

    fn environment_probe(
        home: &std::path::Path,
        actor_id: &str,
        kind: crate::engine::ActorKind,
    ) -> Invocation {
        Invocation::new_sync(
            FunctionId::new("worker_kernel::process_run").unwrap(),
            json!({
                "command": [
                    "python3",
                    "-c",
                    "import os; print(os.environ.get('TRON_WORKER_STATE_DIR', 'missing'))"
                ]
            }),
            CausalContext::new(ActorId::new(actor_id).unwrap(), kind, TraceId::generate())
                .with_working_directory(home.display().to_string())
                .with_declared_workspace_effect(crate::engine::WorkspaceEffect::ArbitraryProcess),
        )
    }

    #[tokio::test]
    async fn worker_actor_processes_receive_their_durable_state_directory() {
        let home = tempfile::tempdir().unwrap();
        let runtime = test_runtime(home.path());

        let result = process_run(
            &environment_probe(
                home.path(),
                "worker:durable-helper",
                crate::engine::ActorKind::Worker,
            ),
            &runtime,
        )
        .await
        .unwrap();

        let expected = home
            .path()
            .join("workspace/worker-state/durable-helper")
            .display()
            .to_string();
        assert_eq!(result["stdout"], format!("{expected}\n"));
    }

    #[tokio::test]
    async fn engine_owned_agent_hops_retain_worker_state_binding() {
        let home = tempfile::tempdir().unwrap();
        let runtime = test_runtime(home.path());
        let mut invocation = environment_probe(
            home.path(),
            "system:agent-runtime",
            crate::engine::ActorKind::System,
        );
        invocation.causal_context = invocation
            .causal_context
            .clone()
            .with_origin_worker_id("durable-helper".to_owned());

        let result = process_run(&invocation, &runtime).await.unwrap();
        let expected = home
            .path()
            .join("workspace/worker-state/durable-helper")
            .display()
            .to_string();
        assert_eq!(result["stdout"], format!("{expected}\n"));
    }

    #[tokio::test]
    async fn non_worker_processes_do_not_receive_worker_state() {
        let home = tempfile::tempdir().unwrap();
        let runtime = test_runtime(home.path());

        let result = process_run(
            &environment_probe(
                home.path(),
                "agent:ordinary",
                crate::engine::ActorKind::Agent,
            ),
            &runtime,
        )
        .await
        .unwrap();

        assert_eq!(result["stdout"], "missing\n");
    }

    #[tokio::test]
    async fn structured_stdin_is_serialized_as_json_once() {
        let home = tempfile::tempdir().unwrap();
        let runtime = test_runtime(home.path());
        let result = process_run(
            &Invocation::new_sync(
                FunctionId::new("worker_kernel::process_run").unwrap(),
                json!({
                    "command":[
                        "python3",
                        "-c",
                        "import json,sys; value=json.load(sys.stdin); print(value['action'], len(value['metrics']))"
                    ],
                    "stdin":{
                        "action":"record_case",
                        "metrics":{}
                    }
                }),
                CausalContext::new(
                    ActorId::new("agent:structured-stdin").unwrap(),
                    crate::engine::ActorKind::Agent,
                    TraceId::generate(),
                )
                .with_working_directory(home.path().display().to_string())
                .with_declared_workspace_effect(crate::engine::WorkspaceEffect::ArbitraryProcess),
            ),
            &runtime,
        )
        .await
        .unwrap();

        assert_eq!(result["status"], 0);
        assert_eq!(result["stdout"], "record_case 0\n");
    }

    #[tokio::test]
    async fn whole_workspace_process_claim_serializes_root_session_processes() {
        let home = tempfile::tempdir().unwrap();
        let checkout = home.path().join("checkout");
        std::fs::create_dir_all(&checkout).unwrap();
        let (runtime, session_id, workspace_id) =
            test_runtime_with_session(&home.path().join("tron-home"), &checkout);
        let first = workspace_process(&checkout, &session_id, &workspace_id, 0.3);
        let second = workspace_process(&checkout, &session_id, &workspace_id, 0.0);
        let first_runtime = std::sync::Arc::clone(&runtime);
        let first_task = tokio::spawn(async move { process_run(&first, &first_runtime).await });
        let mut first_claim_ready = false;
        for _ in 0..100 {
            first_claim_ready = runtime
                .store()
                .list_workspace_claims(None, Some(&workspace_id), false, 20)
                .unwrap()
                .iter()
                .any(|claim| claim.process_id.is_some());
            if first_claim_ready {
                break;
            }
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
        assert!(
            first_claim_ready,
            "first process never bound its workspace claim"
        );

        let second_started = std::time::Instant::now();
        let second_result = process_run(&second, &runtime).await.unwrap();
        let second_elapsed = second_started.elapsed();
        first_task.await.unwrap().unwrap();

        assert_eq!(second_result["success"], true);
        assert!(
            second_elapsed >= Duration::from_millis(180),
            "later process did not wait for the workspace lease: {second_elapsed:?}"
        );
        assert!(
            runtime
                .store()
                .list_workspace_claims(None, Some(&workspace_id), false, 20)
                .unwrap()
                .is_empty()
        );
    }
}
