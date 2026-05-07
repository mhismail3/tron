use super::*;

pub(super) async fn handle(
    method: &str,
    invocation: &Invocation,
    deps: &EngineCapabilityDeps,
) -> Result<Value, CapabilityError> {
    let payload = &invocation.payload;
    match method {
        "settings::get" => {
            serde_json::to_value(&deps.profile_runtime.current().settings).map_err(|error| {
                CapabilityError::Internal {
                    message: error.to_string(),
                }
            })
        }
        "settings::update" => settings_update_value(Some(payload), invocation, deps).await,
        "settings::reset_to_defaults" => settings_reset_to_defaults_value(deps).await,
        _ => Err(CapabilityError::Internal {
            message: format!("settings method {method} is not engine-owned"),
        }),
    }
}

fn settings_error(error: crate::settings::SettingsError) -> CapabilityError {
    CapabilityError::Internal {
        message: error.to_string(),
    }
}

async fn settings_update_value(
    params: Option<&Value>,
    invocation: &Invocation,
    deps: &EngineCapabilityDeps,
) -> Result<Value, CapabilityError> {
    let updates = require_param(params, "settings")?.clone();
    let codex_updates = updates.clone();
    let has_codex_changes = updates.pointer("/server/codexAppServer").is_some();
    let has_mcp_changes = updates.get("mcp").is_some();
    let settings_path = deps.settings_path.clone();

    if has_mcp_changes && let Some(ref router) = deps.mcp_router {
        let mut router_guard = router.write().await;
        let _operation_guard = crate::settings::SettingsStore::operation_lock().await;
        let previous_sparse = read_sparse_settings_snapshot(deps).await?;
        let previous_codex_app_server = deps
            .profile_runtime
            .current()
            .settings
            .server
            .codex_app_server
            .clone();
        run_blocking_task("settings::update", move || {
            crate::settings::SettingsStore::new(settings_path)
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
        broadcast_mcp_status_changed(invocation, deps).await;
        refresh_codex_app_server_if_needed(
            deps,
            &codex_updates,
            previous_sparse,
            previous_codex_app_server,
        )
        .await?;
        return Ok(json!({ "success": true }));
    }

    let _operation_guard = crate::settings::SettingsStore::operation_lock().await;
    let previous_sparse = read_sparse_settings_snapshot(deps).await?;
    let previous_codex_app_server = deps
        .profile_runtime
        .current()
        .settings
        .server
        .codex_app_server
        .clone();
    run_blocking_task("settings::update", move || {
        crate::settings::SettingsStore::new(settings_path)
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
    deps: &EngineCapabilityDeps,
) -> Result<Value, CapabilityError> {
    let _operation_guard = crate::settings::SettingsStore::operation_lock().await;
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
        crate::settings::SettingsStore::new(settings_path)
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

async fn read_sparse_settings_snapshot(
    deps: &EngineCapabilityDeps,
) -> Result<Value, CapabilityError> {
    let path = deps.settings_path.clone();
    run_blocking_task("settings.readSparseSnapshot", move || {
        crate::settings::SettingsStore::new(path)
            .read_sparse_value()
            .map_err(settings_error)
    })
    .await
}

async fn restore_sparse_settings_file(
    deps: &EngineCapabilityDeps,
    previous_sparse: Value,
    reason: &str,
) -> Result<(), CapabilityError> {
    let path = deps.settings_path.clone();
    run_blocking_task("settings.rollbackSparseSettings", move || {
        crate::settings::SettingsStore::new(path)
            .restore_sparse_value_for_rollback(previous_sparse)
            .map_err(settings_error)
    })
    .await?;
    tracing::warn!(reason, "settings sparse overlay restored");
    Ok(())
}

async fn rollback_sparse_settings(
    deps: &EngineCapabilityDeps,
    previous_sparse: Value,
    reason: &str,
) -> Result<(), CapabilityError> {
    restore_sparse_settings_file(deps, previous_sparse, reason).await?;
    crate::settings::init_settings(deps.profile_runtime.current().settings.clone());
    Ok(())
}

async fn reload_profile_runtime_or_rollback(
    deps: &EngineCapabilityDeps,
    previous_sparse: Value,
    reason: &'static str,
) -> Result<(), CapabilityError> {
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
    deps: &EngineCapabilityDeps,
    updates: &Value,
    previous_sparse: Value,
    previous_settings: crate::settings::CodexAppServerSettings,
) -> Result<(), CapabilityError> {
    if updates.pointer("/server/codexAppServer").is_none() {
        return Ok(());
    }

    let Some(manager) = &deps.codex_app_server else {
        return Ok(());
    };

    let settings = crate::settings::get_settings();
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

async fn broadcast_mcp_status_changed(invocation: &Invocation, deps: &EngineCapabilityDeps) {
    let Some(ref router_arc) = deps.mcp_router else {
        return;
    };

    let router = router_arc.read().await;
    let status = router.status();
    let event = ServerEventPayload::new(
        "mcp.status_changed",
        None,
        Some(serde_json::to_value(status).unwrap_or_default()),
    );
    super::publish_engine_stream_event(deps, "mcp", "settings", event, Some(invocation)).await;
}
