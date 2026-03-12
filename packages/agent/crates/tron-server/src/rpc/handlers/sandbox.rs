//! Sandbox handlers: listContainers, startContainer, stopContainer, killContainer, removeContainer.

use std::collections::HashMap;
use std::path::PathBuf;

use async_trait::async_trait;
use serde_json::Value;
use tokio::time::{Duration, timeout};
use tracing::{debug, instrument, warn};

use crate::rpc::context::RpcContext;
use crate::rpc::errors::RpcError;
use crate::rpc::handlers::require_string_param;
use crate::rpc::registry::MethodHandler;

/// Path to the containers metadata file.
fn containers_json_path() -> PathBuf {
    let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".into());
    PathBuf::from(home)
        .join(".tron")
        .join("artifacts")
        .join("containers.json")
}

/// Parse containers from file content.
///
/// Handles both `{"containers": [...]}` (object wrapper) and bare `[...]` formats.
/// Returns an empty vec on any parse failure.
fn parse_containers(content: &str) -> Vec<Value> {
    let Ok(v) = serde_json::from_str::<Value>(content) else {
        return vec![];
    };
    match v {
        Value::Array(arr) => arr,
        Value::Object(ref map) => map
            .get("containers")
            .and_then(|c| c.as_array())
            .cloned()
            .unwrap_or_default(),
        _ => vec![],
    }
}

/// Inject `status` into each container entry from the runtime status map.
///
/// Containers not found in the status map get `"gone"`.
fn enrich_with_status(containers: &mut [Value], statuses: &HashMap<String, String>) {
    for c in containers.iter_mut() {
        let name = c.get("name").and_then(|n| n.as_str()).unwrap_or("");
        let status = statuses.get(name).cloned().unwrap_or_else(|| "gone".into());
        let _ = c
            .as_object_mut()
            .expect("container entry must be an object")
            .insert("status".into(), Value::String(status));
    }
}

/// Query the container runtime for live statuses. Returns name→status map.
///
/// Times out after 3 seconds. Returns an empty map on any failure.
async fn query_container_statuses() -> HashMap<String, String> {
    let result = timeout(
        Duration::from_secs(3),
        tokio::process::Command::new("container")
            .args(["list", "--all", "--format", "json"])
            .output(),
    )
    .await;

    let output = match result {
        Ok(Ok(o)) if o.status.success() => o.stdout,
        Ok(Ok(o)) => {
            let stderr = String::from_utf8_lossy(&o.stderr);
            warn!("container list failed: {stderr}");
            return HashMap::new();
        }
        Ok(Err(e)) => {
            debug!("container CLI unavailable: {e}");
            return HashMap::new();
        }
        Err(_) => {
            warn!("container list timed out");
            return HashMap::new();
        }
    };

    let Ok(parsed) = serde_json::from_slice::<Vec<Value>>(&output) else {
        return HashMap::new();
    };

    parsed
        .into_iter()
        .filter_map(|entry| {
            let name = entry.get("name")?.as_str()?.to_string();
            let status = entry.get("status")?.as_str()?.to_string();
            Some((name, status))
        })
        .collect()
}

/// List running sandbox containers.
pub struct ListContainersHandler;

#[async_trait]
impl MethodHandler for ListContainersHandler {
    #[instrument(skip(self, _ctx), fields(method = "sandbox.listContainers"))]
    async fn handle(&self, _params: Option<Value>, _ctx: &RpcContext) -> Result<Value, RpcError> {
        let path = containers_json_path();
        let mut containers = if path.exists() {
            let content = std::fs::read_to_string(&path).map_err(|e| RpcError::Internal {
                message: format!("Failed to read containers.json: {e}"),
            })?;
            parse_containers(&content)
        } else {
            debug!("containers.json not found, returning empty list");
            vec![]
        };

        let statuses = query_container_statuses().await;
        enrich_with_status(&mut containers, &statuses);

        let tailscale_ip = tron_settings::get_settings().server.tailscale_ip.clone();

        Ok(serde_json::json!({
            "containers": containers,
            "tailscaleIp": tailscale_ip,
        }))
    }
}

/// Run a container command via the CLI.
async fn run_container_command(action: &str, name: &str) -> Result<Value, RpcError> {
    let output = tokio::process::Command::new("container")
        .args([action, name])
        .output()
        .await;

    match output {
        Ok(o) if o.status.success() => Ok(serde_json::json!({
            "success": true,
        })),
        Ok(o) => {
            let stderr = String::from_utf8_lossy(&o.stderr);
            Err(RpcError::Internal {
                message: format!("container {action} failed: {stderr}"),
            })
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Err(RpcError::NotAvailable {
            message: "Container CLI not found. Install container runtime to use sandbox features."
                .into(),
        }),
        Err(e) => Err(RpcError::Internal {
            message: format!("Failed to execute container command: {e}"),
        }),
    }
}

/// Start a sandbox container.
pub struct StartContainerHandler;

#[async_trait]
impl MethodHandler for StartContainerHandler {
    #[instrument(skip(self, _ctx), fields(method = "sandbox.startContainer"))]
    async fn handle(&self, params: Option<Value>, _ctx: &RpcContext) -> Result<Value, RpcError> {
        let name = require_string_param(params.as_ref(), "name")?;
        run_container_command("start", &name).await
    }
}

/// Stop a sandbox container.
pub struct StopContainerHandler;

#[async_trait]
impl MethodHandler for StopContainerHandler {
    #[instrument(skip(self, _ctx), fields(method = "sandbox.stopContainer"))]
    async fn handle(&self, params: Option<Value>, _ctx: &RpcContext) -> Result<Value, RpcError> {
        let name = require_string_param(params.as_ref(), "name")?;
        run_container_command("stop", &name).await
    }
}

/// Kill a sandbox container.
pub struct KillContainerHandler;

#[async_trait]
impl MethodHandler for KillContainerHandler {
    #[instrument(skip(self, _ctx), fields(method = "sandbox.killContainer"))]
    async fn handle(&self, params: Option<Value>, _ctx: &RpcContext) -> Result<Value, RpcError> {
        let name = require_string_param(params.as_ref(), "name")?;
        run_container_command("kill", &name).await
    }
}

/// Remove a container entry from `containers.json`.
///
/// Reads the file, filters out entries matching `name`, and writes back
/// in the same format (object-wrapped or bare array). Silently succeeds
/// if the file doesn't exist, is empty, or contains invalid JSON.
fn remove_container_metadata(name: &str) -> Result<(), RpcError> {
    remove_container_metadata_at(&containers_json_path(), name)
}

/// Remove a container entry from a specific containers JSON file path.
fn remove_container_metadata_at(path: &std::path::Path, name: &str) -> Result<(), RpcError> {
    let content = match std::fs::read_to_string(path) {
        Ok(c) => c,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(e) => {
            return Err(RpcError::Internal {
                message: format!("Failed to read containers.json: {e}"),
            });
        }
    };

    let Ok(parsed) = serde_json::from_str::<Value>(&content) else {
        return Ok(());
    };

    let is_object_format = parsed.is_object();
    let entries = match &parsed {
        Value::Array(arr) => arr.clone(),
        Value::Object(map) => map
            .get("containers")
            .and_then(|c| c.as_array())
            .cloned()
            .unwrap_or_default(),
        _ => return Ok(()),
    };

    let filtered: Vec<Value> = entries
        .into_iter()
        .filter(|e| e.get("name").and_then(|n| n.as_str()) != Some(name))
        .collect();

    let output = if is_object_format {
        serde_json::json!({ "containers": filtered })
    } else {
        Value::Array(filtered)
    };

    let serialized = serde_json::to_string_pretty(&output).map_err(|e| RpcError::Internal {
        message: format!("Failed to serialize containers.json: {e}"),
    })?;

    std::fs::write(path, serialized).map_err(|e| RpcError::Internal {
        message: format!("Failed to write containers.json: {e}"),
    })
}

/// Remove a sandbox container from the runtime and metadata.
///
/// Step 1: Attempt `container rm <name>` — errors are ignored (container may be gone).
/// Step 2: Remove the entry from `containers.json` — errors here propagate.
pub struct RemoveContainerHandler;

#[async_trait]
impl MethodHandler for RemoveContainerHandler {
    #[instrument(skip(self, _ctx), fields(method = "sandbox.removeContainer"))]
    async fn handle(&self, params: Option<Value>, _ctx: &RpcContext) -> Result<Value, RpcError> {
        let name = require_string_param(params.as_ref(), "name")?;

        // Best-effort runtime removal — ignore all errors
        let _ = tokio::process::Command::new("container")
            .args(["rm", &name])
            .output()
            .await;

        remove_container_metadata(&name)?;

        Ok(serde_json::json!({ "success": true }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::rpc::handlers::test_helpers::make_test_context;
    use serde_json::json;

    // ── parse_containers ──────────────────────────────────────────

    #[test]
    fn parse_object_format() {
        let result = parse_containers(r#"{"containers":[{"name":"a"}]}"#);
        assert_eq!(result.len(), 1);
        assert_eq!(result[0]["name"], "a");
    }

    #[test]
    fn parse_bare_array() {
        let result = parse_containers(r#"[{"name":"a"}]"#);
        assert_eq!(result.len(), 1);
        assert_eq!(result[0]["name"], "a");
    }

    #[test]
    fn parse_empty_object() {
        let result = parse_containers(r#"{"containers":[]}"#);
        assert!(result.is_empty());
    }

    #[test]
    fn parse_empty_array() {
        let result = parse_containers("[]");
        assert!(result.is_empty());
    }

    #[test]
    fn parse_object_missing_key() {
        let result = parse_containers(r#"{"other":[]}"#);
        assert!(result.is_empty());
    }

    #[test]
    fn parse_object_non_array_value() {
        let result = parse_containers(r#"{"containers":"not-array"}"#);
        assert!(result.is_empty());
    }

    #[test]
    fn parse_invalid_json() {
        let result = parse_containers("{broken");
        assert!(result.is_empty());
    }

    #[test]
    fn parse_empty_string() {
        let result = parse_containers("");
        assert!(result.is_empty());
    }

    #[test]
    fn parse_multiple_containers() {
        let result = parse_containers(r#"{"containers":[{"name":"a"},{"name":"b"}]}"#);
        assert_eq!(result.len(), 2);
    }

    #[test]
    fn parse_scalar_json() {
        let result = parse_containers("42");
        assert!(result.is_empty());
    }

    // ── enrich_with_status ────────────────────────────────────────

    #[test]
    fn enrich_running() {
        let mut containers = vec![json!({"name": "a"})];
        let statuses = HashMap::from([("a".into(), "running".into())]);
        enrich_with_status(&mut containers, &statuses);
        assert_eq!(containers[0]["status"], "running");
    }

    #[test]
    fn enrich_stopped() {
        let mut containers = vec![json!({"name": "a"})];
        let statuses = HashMap::from([("a".into(), "stopped".into())]);
        enrich_with_status(&mut containers, &statuses);
        assert_eq!(containers[0]["status"], "stopped");
    }

    #[test]
    fn enrich_gone() {
        let mut containers = vec![json!({"name": "a"})];
        let statuses = HashMap::new();
        enrich_with_status(&mut containers, &statuses);
        assert_eq!(containers[0]["status"], "gone");
    }

    #[test]
    fn enrich_multiple_mixed() {
        let mut containers = vec![json!({"name": "a"}), json!({"name": "b"})];
        let statuses = HashMap::from([("a".into(), "running".into())]);
        enrich_with_status(&mut containers, &statuses);
        assert_eq!(containers[0]["status"], "running");
        assert_eq!(containers[1]["status"], "gone");
    }

    #[test]
    fn enrich_overwrites_existing() {
        let mut containers = vec![json!({"name": "a", "status": "old"})];
        let statuses = HashMap::from([("a".into(), "running".into())]);
        enrich_with_status(&mut containers, &statuses);
        assert_eq!(containers[0]["status"], "running");
    }

    #[test]
    fn enrich_no_name_field() {
        let mut containers = vec![json!({"image": "x"})];
        let statuses = HashMap::from([("a".into(), "running".into())]);
        enrich_with_status(&mut containers, &statuses);
        assert_eq!(containers[0]["status"], "gone");
    }

    #[test]
    fn enrich_empty_containers() {
        let mut containers: Vec<Value> = vec![];
        let statuses = HashMap::from([("a".into(), "running".into())]);
        enrich_with_status(&mut containers, &statuses);
        assert!(containers.is_empty());
    }

    // ── handler response structure ────────────────────────────────

    #[tokio::test]
    async fn list_containers_returns_array() {
        let ctx = make_test_context();
        let result = ListContainersHandler.handle(None, &ctx).await.unwrap();
        assert!(result["containers"].is_array());
    }

    #[tokio::test]
    async fn response_has_tailscale_ip_key() {
        let ctx = make_test_context();
        let result = ListContainersHandler.handle(None, &ctx).await.unwrap();
        assert!(result.get("tailscaleIp").is_some());
    }

    #[tokio::test]
    async fn response_tailscale_ip_is_null_or_string() {
        let ctx = make_test_context();
        let result = ListContainersHandler.handle(None, &ctx).await.unwrap();
        let ip = &result["tailscaleIp"];
        assert!(
            ip.is_null() || ip.is_string(),
            "tailscaleIp must be null or string"
        );
    }

    #[tokio::test]
    async fn list_containers_reads_file() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("containers.json");
        std::fs::write(&path, r#"[{"name":"test","status":"running"}]"#).unwrap();

        let content = std::fs::read_to_string(&path).unwrap();
        let containers = parse_containers(&content);
        assert_eq!(containers.len(), 1);
        assert_eq!(containers[0]["name"], "test");
    }

    // ── existing handler tests (unchanged) ────────────────────────

    #[tokio::test]
    async fn start_container_requires_name() {
        let ctx = make_test_context();
        let err = StartContainerHandler
            .handle(Some(json!({})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
    }

    #[tokio::test]
    async fn stop_container_requires_name() {
        let ctx = make_test_context();
        let err = StopContainerHandler
            .handle(Some(json!({})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
    }

    #[tokio::test]
    async fn kill_container_requires_name() {
        let ctx = make_test_context();
        let err = KillContainerHandler
            .handle(Some(json!({})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
    }

    #[tokio::test]
    async fn container_cli_not_found() {
        let ctx = make_test_context();
        let err = StartContainerHandler
            .handle(Some(json!({"name": "test-box"})), &ctx)
            .await
            .unwrap_err();
        assert!(
            err.code() == "NOT_AVAILABLE" || err.code() == "INTERNAL_ERROR",
            "unexpected error code: {}",
            err.code()
        );
    }

    // ── remove_container_metadata ────────────────────────────────

    fn write_containers_file(dir: &std::path::Path, content: &str) -> PathBuf {
        let artifacts = dir.join(".tron").join("artifacts");
        std::fs::create_dir_all(&artifacts).unwrap();
        let path = artifacts.join("containers.json");
        std::fs::write(&path, content).unwrap();
        path
    }

    fn read_file(path: &std::path::Path) -> String {
        std::fs::read_to_string(path).unwrap()
    }

    #[test]
    fn remove_from_bare_array() {
        let tmp = tempfile::tempdir().unwrap();
        let path = write_containers_file(tmp.path(), r#"[{"name":"a"},{"name":"b"}]"#);
        remove_container_metadata_at(&path, "a").unwrap();
        let result: Value = serde_json::from_str(&read_file(&path)).unwrap();
        let arr = result.as_array().unwrap();
        assert_eq!(arr.len(), 1);
        assert_eq!(arr[0]["name"], "b");
    }

    #[test]
    fn remove_from_object_format() {
        let tmp = tempfile::tempdir().unwrap();
        let path =
            write_containers_file(tmp.path(), r#"{"containers":[{"name":"a"},{"name":"b"}]}"#);
        remove_container_metadata_at(&path, "a").unwrap();
        let result: Value = serde_json::from_str(&read_file(&path)).unwrap();
        let arr = result["containers"].as_array().unwrap();
        assert_eq!(arr.len(), 1);
        assert_eq!(arr[0]["name"], "b");
    }

    #[test]
    fn remove_nonexistent_name() {
        let tmp = tempfile::tempdir().unwrap();
        let path = write_containers_file(tmp.path(), r#"[{"name":"a"}]"#);
        remove_container_metadata_at(&path, "zzz").unwrap();
        let result: Value = serde_json::from_str(&read_file(&path)).unwrap();
        assert_eq!(result.as_array().unwrap().len(), 1);
    }

    #[test]
    fn remove_last_entry_bare_array() {
        let tmp = tempfile::tempdir().unwrap();
        let path = write_containers_file(tmp.path(), r#"[{"name":"a"}]"#);
        remove_container_metadata_at(&path, "a").unwrap();
        let result: Value = serde_json::from_str(&read_file(&path)).unwrap();
        assert!(result.as_array().unwrap().is_empty());
    }

    #[test]
    fn remove_last_entry_object_format() {
        let tmp = tempfile::tempdir().unwrap();
        let path = write_containers_file(tmp.path(), r#"{"containers":[{"name":"a"}]}"#);
        remove_container_metadata_at(&path, "a").unwrap();
        let result: Value = serde_json::from_str(&read_file(&path)).unwrap();
        assert!(result["containers"].as_array().unwrap().is_empty());
    }

    #[test]
    fn remove_multiple_with_same_name() {
        let tmp = tempfile::tempdir().unwrap();
        let path = write_containers_file(tmp.path(), r#"[{"name":"a"},{"name":"a"},{"name":"b"}]"#);
        remove_container_metadata_at(&path, "a").unwrap();
        let result: Value = serde_json::from_str(&read_file(&path)).unwrap();
        let arr = result.as_array().unwrap();
        assert_eq!(arr.len(), 1);
        assert_eq!(arr[0]["name"], "b");
    }

    #[test]
    fn remove_file_not_found() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("nonexistent.json");
        remove_container_metadata_at(&path, "a").unwrap();
    }

    #[test]
    fn remove_empty_file() {
        let tmp = tempfile::tempdir().unwrap();
        let path = write_containers_file(tmp.path(), "");
        remove_container_metadata_at(&path, "a").unwrap();
    }

    #[test]
    fn remove_invalid_json() {
        let tmp = tempfile::tempdir().unwrap();
        let path = write_containers_file(tmp.path(), "{broken");
        remove_container_metadata_at(&path, "a").unwrap();
    }

    #[test]
    fn remove_preserves_other_fields() {
        let tmp = tempfile::tempdir().unwrap();
        let path = write_containers_file(
            tmp.path(),
            r#"[{"name":"a","image":"img-a","port":8080},{"name":"b","image":"img-b","port":9090}]"#,
        );
        remove_container_metadata_at(&path, "a").unwrap();
        let result: Value = serde_json::from_str(&read_file(&path)).unwrap();
        let arr = result.as_array().unwrap();
        assert_eq!(arr.len(), 1);
        assert_eq!(arr[0]["name"], "b");
        assert_eq!(arr[0]["image"], "img-b");
        assert_eq!(arr[0]["port"], 9090);
    }

    // ── RemoveContainerHandler tests ─────────────────────────────

    #[tokio::test]
    async fn remove_container_requires_name() {
        let ctx = make_test_context();
        let err = RemoveContainerHandler
            .handle(Some(json!({})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
    }
}
