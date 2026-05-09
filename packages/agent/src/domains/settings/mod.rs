//! settings domain worker.
//!
//! This module owns canonical function execution for the settings namespace and keeps
//! domain contracts, services, and tests beside the worker that uses them.
//! Settings changes that force MCP router reloads publish MCP health through
//! the MCP domain stream publisher, so the stream topic owner remains explicit.

pub(crate) mod contract;
pub(crate) mod deps;
pub(crate) mod handlers;
pub mod implementation;
pub(crate) use deps::Deps;
pub use implementation::*;

use crate::domains::worker::DomainRegistrationContext;
use crate::domains::worker::DomainWorkerModule;
use crate::engine::Invocation;
use crate::shared::server::context::run_blocking_task;
use crate::shared::server::errors::CapabilityError;
use crate::shared::server::params::require_param;
use serde_json::Value;
use serde_json::json;

pub(crate) fn worker_module(
    deps: &DomainRegistrationContext,
) -> crate::engine::Result<DomainWorkerModule> {
    {
        let domain_deps = Deps::from_engine(deps);
        crate::domains::worker::domain_worker_module(
            "settings",
            contract::STREAM_TOPICS,
            handlers::function_registrations(contract::capabilities()?, domain_deps)?,
        )
    }
}

fn settings_error(error: crate::domains::settings::SettingsError) -> CapabilityError {
    CapabilityError::Internal {
        message: error.to_string(),
    }
}

async fn settings_update_value(
    params: Option<&Value>,
    invocation: &Invocation,
    deps: &Deps,
) -> std::result::Result<Value, CapabilityError> {
    let updates = require_param(params, "settings")?.clone();
    let codex_updates = updates.clone();
    let has_codex_changes = updates.pointer("/server/codexAppServer").is_some();
    let has_mcp_changes = updates.get("mcp").is_some();
    let settings_path = deps.settings_path.clone();

    if has_mcp_changes && let Some(ref router) = deps.mcp_router {
        let mut router_guard = router.write().await;
        let _operation_guard = crate::domains::settings::SettingsStore::operation_lock().await;
        let previous_sparse = read_sparse_settings_snapshot(deps).await?;
        let previous_codex_app_server = deps
            .profile_runtime
            .current()
            .settings
            .server
            .codex_app_server
            .clone();
        run_blocking_task("settings::update", move || {
            crate::domains::settings::SettingsStore::new(settings_path)
                .update(updates)
                .map_err(settings_error)
        })
        .await?;

        if let Err(message) = router_guard.reload_from_settings().await {
            rollback_sparse_settings(deps, previous_sparse, "settings.rollbackMcpUpdate").await?;
            return Err(CapabilityError::Internal { message });
        }
        if let Err(error) = deps.profile_runtime.reload_now("settings::update") {
            rollback_sparse_settings(
                deps,
                previous_sparse,
                "settings.rollbackAfterProfileRuntimeFailure",
            )
            .await?;
            if let Err(rollback_error) = router_guard.reload_from_settings().await {
                tracing::warn!(
                    error = %rollback_error,
                    "MCP router failed to reload after profile-runtime rollback"
                );
            }
            return Err(CapabilityError::Internal {
                message: format!(
                    "profile runtime rejected the updated settings; sparse settings were rolled back: {error}"
                ),
            });
        }
        drop(router_guard);
        publish_mcp_status_changed(invocation, deps).await;
        refresh_codex_app_server_if_needed(
            deps,
            &codex_updates,
            previous_sparse,
            previous_codex_app_server,
        )
        .await?;
        return Ok(json!({ "success": true }));
    }

    let _operation_guard = crate::domains::settings::SettingsStore::operation_lock().await;
    let previous_sparse = read_sparse_settings_snapshot(deps).await?;
    let previous_codex_app_server = deps
        .profile_runtime
        .current()
        .settings
        .server
        .codex_app_server
        .clone();
    run_blocking_task("settings::update", move || {
        crate::domains::settings::SettingsStore::new(settings_path)
            .update(updates)
            .map_err(settings_error)
    })
    .await?;
    reload_profile_runtime_or_rollback(deps, previous_sparse.clone(), "settings::update").await?;

    if has_codex_changes {
        refresh_codex_app_server_if_needed(
            deps,
            &codex_updates,
            previous_sparse,
            previous_codex_app_server,
        )
        .await?;
    }

    Ok(json!({ "success": true }))
}

async fn settings_reset_to_defaults_value(
    deps: &Deps,
) -> std::result::Result<Value, CapabilityError> {
    let _operation_guard = crate::domains::settings::SettingsStore::operation_lock().await;
    let previous_sparse = read_sparse_settings_snapshot(deps).await?;
    let previous_codex_app_server = deps
        .profile_runtime
        .current()
        .settings
        .server
        .codex_app_server
        .clone();
    let settings_path = deps.settings_path.clone();
    let result = run_blocking_task("settings::reset_to_defaults", move || {
        crate::domains::settings::SettingsStore::new(settings_path)
            .reset()
            .map_err(settings_error)
    })
    .await?;
    reload_profile_runtime_or_rollback(
        deps,
        previous_sparse.clone(),
        "settings::reset_to_defaults",
    )
    .await?;

    refresh_codex_app_server_if_needed(
        deps,
        &json!({"server": {"codexAppServer": true}}),
        previous_sparse,
        previous_codex_app_server,
    )
    .await?;

    Ok(result)
}

async fn read_sparse_settings_snapshot(deps: &Deps) -> std::result::Result<Value, CapabilityError> {
    let path = deps.settings_path.clone();
    run_blocking_task("settings.readSparseSnapshot", move || {
        crate::domains::settings::SettingsStore::new(path)
            .read_sparse_value()
            .map_err(settings_error)
    })
    .await
}

async fn restore_sparse_settings_file(
    deps: &Deps,
    previous_sparse: Value,
    reason: &str,
) -> std::result::Result<(), CapabilityError> {
    let path = deps.settings_path.clone();
    run_blocking_task("settings.rollbackSparseSettings", move || {
        crate::domains::settings::SettingsStore::new(path)
            .restore_sparse_value_for_rollback(previous_sparse)
            .map_err(settings_error)
    })
    .await?;
    tracing::warn!(reason, "settings sparse overlay restored");
    Ok(())
}

async fn rollback_sparse_settings(
    deps: &Deps,
    previous_sparse: Value,
    reason: &str,
) -> std::result::Result<(), CapabilityError> {
    restore_sparse_settings_file(deps, previous_sparse, reason).await?;
    crate::domains::settings::init_settings(deps.profile_runtime.current().settings.clone());
    Ok(())
}

async fn reload_profile_runtime_or_rollback(
    deps: &Deps,
    previous_sparse: Value,
    reason: &'static str,
) -> std::result::Result<(), CapabilityError> {
    match deps.profile_runtime.reload_now(reason) {
        Ok(_) => Ok(()),
        Err(error) => {
            rollback_sparse_settings(deps, previous_sparse, reason).await?;
            Err(CapabilityError::Internal {
                message: format!(
                    "profile runtime rejected the updated settings; sparse settings were rolled back: {error}"
                ),
            })
        }
    }
}

async fn refresh_codex_app_server_if_needed(
    deps: &Deps,
    updates: &Value,
    previous_sparse: Value,
    previous_settings: crate::domains::settings::CodexAppServerSettings,
) -> std::result::Result<(), CapabilityError> {
    if updates.pointer("/server/codexAppServer").is_none() {
        return Ok(());
    }

    let Some(manager) = &deps.codex_app_server else {
        return Ok(());
    };

    let settings = crate::domains::settings::get_settings();
    if let Err(error) = manager
        .reconfigure(settings.server.codex_app_server.clone())
        .await
    {
        restore_sparse_settings_file(
            deps,
            previous_sparse,
            "settings.rollbackCodexAppServerUpdate",
        )
        .await?;
        deps.profile_runtime
            .reload_now("settings.rollbackCodexAppServerUpdate")
            .map_err(|rollback_error| CapabilityError::Internal {
                message: format!(
                    "Codex App Server reconfiguration failed ({error}); sparse settings were restored, but profile runtime reload failed during rollback: {rollback_error}"
                ),
            })?;
        if let Err(rollback_error) = manager.reconfigure(previous_settings).await {
            tracing::warn!(
                error = %rollback_error,
                "Codex App Server failed to reconfigure back to previous settings after rollback"
            );
        }
        return Err(CapabilityError::Internal {
            message: format!(
                "Codex App Server reconfiguration failed; sparse settings were rolled back: {error}"
            ),
        });
    }
    Ok(())
}

async fn publish_mcp_status_changed(invocation: &Invocation, deps: &Deps) {
    let Some(ref router_arc) = deps.mcp_router else {
        return;
    };

    let router = router_arc.read().await;
    let status = router.status();
    crate::domains::mcp::stream::McpStreamPublisher::new(&deps.engine_host)
        .status_changed(invocation, serde_json::to_value(status).unwrap_or_default())
        .await;
}
