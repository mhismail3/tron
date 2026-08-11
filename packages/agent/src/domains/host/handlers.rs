//! Handler bindings for the minimal host vocabulary.

use serde_json::{Value, json};

use crate::domains::registration::bindings::operation_bindings;
use crate::engine::Invocation;

use super::{Deps, contract};

operation_bindings! {
    deps = Deps;
    hidden = [];
    bindings = [
        contract::READ_FUNCTION => |invocation, deps| { read(invocation, deps).await },
        contract::WRITE_FUNCTION => |invocation, deps| { map_result(crate::domains::worker_kernel::host::filesystem_write(invocation, &deps.runtime).await) },
        contract::EDIT_FUNCTION => |invocation, deps| { map_result(crate::domains::worker_kernel::host::filesystem_edit(invocation, &deps.runtime).await) },
        contract::BASH_FUNCTION => |invocation, deps| { bash(invocation, deps).await },
    ];
}

pub(super) async fn read(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, crate::shared::server::errors::ToolError> {
    let requested = invocation
        .payload
        .get("path")
        .and_then(Value::as_str)
        .ok_or_else(|| invalid("path is required"))?;
    if requested.starts_with("tron://") {
        return Err(invalid(
            "this resource reference is not readable by the active core version",
        ));
    }
    let path = crate::domains::worker_kernel::host::resolve_path(invocation, requested)
        .map_err(invalid)?;
    let metadata = tokio::fs::metadata(&path)
        .await
        .map_err(|error| invalid(format!("inspect {}: {error}", path.display())))?;
    let mut delegated = invocation.clone();
    let result = if metadata.is_dir() {
        let max_results = invocation
            .payload
            .get("maxEntries")
            .cloned()
            .unwrap_or_else(|| json!(500));
        delegated.payload = json!({"path":requested,"maxResults":max_results});
        crate::domains::worker_kernel::host::filesystem_list(&delegated, &deps.runtime)
            .await
            .map(|mut value| {
                value["kind"] = json!("directory");
                value
            })
    } else {
        delegated.payload = json!({
            "path":requested,
            "maxBytes":invocation.payload.get("maxBytes").cloned().unwrap_or_else(|| json!(262144))
        });
        crate::domains::worker_kernel::host::filesystem_read(&delegated, &deps.runtime)
            .await
            .map(|mut value| {
                value["kind"] = json!("file");
                value
            })
    };
    map_result(result)
}

pub(super) async fn bash(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, crate::shared::server::errors::ToolError> {
    let script = invocation
        .payload
        .get("script")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|script| !script.is_empty())
        .ok_or_else(|| invalid("script is required"))?;
    let mut delegated = invocation.clone();
    let mut payload = json!({
        "command":["/bin/bash","-lc",script],
    });
    for key in ["cwd", "stdin", "timeoutSeconds"] {
        if let Some(value) = invocation.payload.get(key) {
            payload[key] = value.clone();
        }
    }
    delegated.payload = payload;
    let mut value = crate::domains::worker_kernel::host::process_run(&delegated, &deps.runtime)
        .await
        .map_err(invalid)?;
    value["script"] = json!(script);
    let _ = value
        .as_object_mut()
        .and_then(|object| object.remove("command"));
    Ok(value)
}

fn map_result(
    result: Result<Value, String>,
) -> Result<Value, crate::shared::server::errors::ToolError> {
    result.map_err(invalid)
}

fn invalid(message: impl Into<String>) -> crate::shared::server::errors::ToolError {
    crate::shared::server::errors::ToolError::InvalidParams {
        message: message.into(),
    }
}
