//! Settings operation bodies.

use serde_json::{Value, json};

use crate::domains::settings::Deps;
use crate::shared::server::context::run_blocking_task;
use crate::shared::server::errors::CapabilityError;
use crate::shared::server::params::require_param;

fn settings_error(error: crate::domains::settings::SettingsError) -> CapabilityError {
    CapabilityError::Internal {
        message: error.to_string(),
    }
}

pub(crate) async fn settings_update_value(
    params: Option<&Value>,
    deps: &Deps,
) -> std::result::Result<Value, CapabilityError> {
    let updates = require_param(params, "settings")?.clone();
    let settings_path = deps.settings_path.clone();

    let _operation_guard = crate::domains::settings::SettingsStore::operation_lock().await;
    let previous_sparse = read_sparse_settings_snapshot(deps).await?;
    run_blocking_task("settings::update", move || {
        crate::domains::settings::SettingsStore::new(settings_path)
            .update(updates)
            .map_err(settings_error)
    })
    .await?;
    reload_settings_runtime_or_rollback(deps, previous_sparse.clone(), "settings::update").await?;

    Ok(json!({ "success": true }))
}

pub(crate) async fn settings_reset_to_defaults_value(
    deps: &Deps,
) -> std::result::Result<Value, CapabilityError> {
    let _operation_guard = crate::domains::settings::SettingsStore::operation_lock().await;
    let previous_sparse = read_sparse_settings_snapshot(deps).await?;
    let settings_path = deps.settings_path.clone();
    let result = run_blocking_task("settings::reset_to_defaults", move || {
        crate::domains::settings::SettingsStore::new(settings_path)
            .reset()
            .map_err(settings_error)
    })
    .await?;
    reload_settings_runtime_or_rollback(
        deps,
        previous_sparse.clone(),
        "settings::reset_to_defaults",
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

async fn reload_settings_runtime_or_rollback(
    deps: &Deps,
    previous_sparse: Value,
    reason: &'static str,
) -> std::result::Result<(), CapabilityError> {
    match deps.settings_runtime.reload_now(reason) {
        Ok(_) => Ok(()),
        Err(error) => {
            restore_sparse_settings_file(deps, previous_sparse, reason).await?;
            Err(CapabilityError::Internal {
                message: format!(
                    "settings runtime rejected the update; sparse settings were rolled back: {error}"
                ),
            })
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn update_and_reset_swap_only_the_settings_runtime_snapshot() {
        let context = crate::shared::server::test_support::make_test_context();
        let deps = Deps {
            settings_runtime: context.settings_runtime.clone(),
            settings_path: context.settings_path.clone(),
        };
        let default_max_turns = crate::domains::settings::TronSettings::default()
            .agent
            .max_turns;
        let initial = deps.settings_runtime.current();
        let params = json!({"settings": {"agent": {"maxTurns": 123}}});

        settings_update_value(Some(&params), &deps).await.unwrap();

        let updated = deps.settings_runtime.current();
        assert_eq!(updated.settings.agent.max_turns, 123);
        assert_eq!(initial.settings.agent.max_turns, default_max_turns);
        assert!(!std::sync::Arc::ptr_eq(&initial, &updated));

        let reset = settings_reset_to_defaults_value(&deps).await.unwrap();

        let current = deps.settings_runtime.current();
        assert_eq!(reset["agent"]["maxTurns"], default_max_turns);
        assert_eq!(current.settings.agent.max_turns, default_max_turns);
        assert_eq!(
            crate::domains::settings::SettingsStore::new(&deps.settings_path)
                .read_sparse_value()
                .unwrap(),
            json!({})
        );
        assert!(!deps.settings_path.exists());
    }
}
