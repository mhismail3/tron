//! Bounded trusted-local command execution.

use std::process::Stdio;
use std::time::Duration;

use serde_json::{Value, json};

use crate::engine::Invocation;

use super::super::process::{
    MAX_PROCESS_CAPTURE_BYTES, ProcessTree, trusted_local_command_path, wait_with_bounded_output,
};
use super::super::runtime::WorkerRuntime;
use super::support::resolve_path;

const MAX_PROCESS_ARGUMENTS: usize = 256;
const MAX_PROCESS_INPUT_BYTES: usize = 4 * 1_048_576;

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
    let mut process = tokio::process::Command::new(program);
    process
        .args(arguments)
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
    Ok(json!({
        "command": command,
        "cwd": cwd,
        "status": output.status.code(),
        "success": output.status.success(),
        "stdout": String::from_utf8_lossy(&output.stdout),
        "stderr": String::from_utf8_lossy(&output.stderr),
        "stdoutTruncated": output.stdout_truncated,
        "stderrTruncated": output.stderr_truncated,
    }))
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
                .with_working_directory(home.display().to_string()),
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
}
