use serde_json::{Value, json};

use super::*;

pub(super) async fn handle(
    method: &str,
    invocation: &Invocation,
    deps: &EngineCapabilityDeps,
) -> Result<Value, CapabilityError> {
    match method {
        "browser::get_status" => Ok(json!({
            "hasBrowser": false,
            "isStreaming": false,
        })),
        "voice_notes::list" => voice_notes_list(&invocation.payload, deps).await,
        "transcription::list_models" => transcribe_list_models(deps).await,
        "sandbox::list_containers" => sandbox_list_containers(deps).await,
        _ => Err(CapabilityError::Internal {
            message: format!("safe read method {method} is not engine-owned"),
        }),
    }
}

async fn voice_notes_list(
    payload: &Value,
    deps: &EngineCapabilityDeps,
) -> Result<Value, CapabilityError> {
    let limit = usize::try_from(opt_u64(Some(payload), "limit", 50)).unwrap_or(usize::MAX);
    let offset = usize::try_from(opt_u64(Some(payload), "offset", 0)).unwrap_or(0);
    let dir = crate::server::services::voice_notes_service::notes_dir();
    deps.capability_context
        .run_blocking("voice_notes::list", move || {
            Ok(crate::server::services::voice_notes_service::list_notes(
                &dir, limit, offset,
            ))
        })
        .await
}

async fn transcribe_list_models(deps: &EngineCapabilityDeps) -> Result<Value, CapabilityError> {
    let engine_loaded = deps.capability_context.transcription_engine.get().is_some();
    let enabled = crate::settings::get_settings().server.transcription.enabled;
    Ok(json!({
        "models": [
            {
                "id": "parakeet-tdt-0.6b-v3",
                "name": "Parakeet TDT 0.6B v3",
                "size": "600M",
                "language": "en",
                "default": true,
                "enabled": enabled,
                "cached": engine_loaded,
                "engineLoaded": engine_loaded,
            }
        ]
    }))
}

async fn sandbox_list_containers(deps: &EngineCapabilityDeps) -> Result<Value, CapabilityError> {
    let path = crate::server::services::sandbox_service::containers_json_path();
    let mut containers = deps
        .capability_context
        .run_blocking("sandbox.list_containers.load_metadata", move || {
            crate::server::services::sandbox_service::load_containers(&path)
        })
        .await?;
    let statuses = crate::server::services::sandbox_service::query_container_statuses().await;
    for container in &mut containers {
        let name = container
            .get("name")
            .and_then(Value::as_str)
            .unwrap_or_default();
        let status = statuses.get(name).cloned().unwrap_or_else(|| "gone".into());
        let _ = container
            .as_object_mut()
            .expect("container entry must be an object")
            .insert("status".into(), Value::String(status));
    }
    let host_ip = crate::settings::get_settings().server.tailscale_ip.clone();
    Ok(json!({
        "containers": containers,
        "hostIp": host_ip,
    }))
}
