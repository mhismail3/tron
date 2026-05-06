//! Settings handlers: get, update, reset.

use async_trait::async_trait;
use serde_json::Value;
use tracing::instrument;

use crate::server::rpc::context::RpcContext;
use crate::server::rpc::errors::RpcError;
use crate::server::rpc::handlers::{mcp, require_param};
use crate::server::rpc::registry::MethodHandler;

fn settings_error(error: crate::settings::SettingsError) -> RpcError {
    RpcError::Internal {
        message: error.to_string(),
    }
}

async fn refresh_codex_app_server_if_needed(
    ctx: &RpcContext,
    updates: &Value,
    previous_sparse: Value,
    previous_settings: crate::settings::CodexAppServerSettings,
) -> Result<(), RpcError> {
    if updates.pointer("/server/codexAppServer").is_none() {
        return Ok(());
    }

    let Some(manager) = &ctx.codex_app_server else {
        return Ok(());
    };

    let settings = crate::settings::get_settings();
    if let Err(error) = manager
        .reconfigure(settings.server.codex_app_server.clone())
        .await
    {
        restore_sparse_settings_file(
            ctx,
            previous_sparse,
            "settings.rollbackCodexAppServerUpdate",
        )
        .await?;
        ctx.profile_runtime
            .reload_now("settings.rollbackCodexAppServerUpdate")
            .map_err(|rollback_error| RpcError::Internal {
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
        return Err(RpcError::Internal {
            message: format!(
                "Codex App Server reconfiguration failed; sparse settings were rolled back: {error}"
            ),
        });
    }
    Ok(())
}

async fn read_sparse_settings_snapshot(ctx: &RpcContext) -> Result<Value, RpcError> {
    let path = ctx.settings_path.clone();
    ctx.run_blocking("settings.readSparseSnapshot", move || {
        crate::settings::SettingsStore::new(path)
            .read_sparse_value()
            .map_err(settings_error)
    })
    .await
}

async fn restore_sparse_settings_file(
    ctx: &RpcContext,
    previous_sparse: Value,
    reason: &str,
) -> Result<(), RpcError> {
    let path = ctx.settings_path.clone();
    ctx.run_blocking("settings.rollbackSparseSettings", move || {
        crate::settings::SettingsStore::new(path)
            .restore_sparse_value_for_rollback(previous_sparse)
            .map_err(settings_error)
    })
    .await?;
    tracing::warn!(reason, "settings sparse overlay restored");
    Ok(())
}

async fn rollback_sparse_settings(
    ctx: &RpcContext,
    previous_sparse: Value,
    reason: &str,
) -> Result<(), RpcError> {
    restore_sparse_settings_file(ctx, previous_sparse, reason).await?;
    crate::settings::init_settings(ctx.profile_runtime.current().settings.clone());
    Ok(())
}

async fn reload_profile_runtime_or_rollback(
    ctx: &RpcContext,
    previous_sparse: Value,
    reason: &'static str,
) -> Result<(), RpcError> {
    match ctx.profile_runtime.reload_now(reason) {
        Ok(_) => Ok(()),
        Err(error) => {
            rollback_sparse_settings(ctx, previous_sparse, reason).await?;
            Err(RpcError::Internal {
                message: format!(
                    "profile runtime rejected the updated settings; sparse settings were rolled back: {error}"
                ),
            })
        }
    }
}

/// Reset all settings to defaults.
pub struct ResetSettingsHandler;

#[async_trait]
impl MethodHandler for ResetSettingsHandler {
    #[instrument(skip(self, ctx), fields(method = "settings.resetToDefaults"))]
    async fn handle(&self, _params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let _operation_guard = crate::settings::SettingsStore::operation_lock().await;
        let previous_sparse = read_sparse_settings_snapshot(ctx).await?;
        let previous_codex_app_server = ctx
            .profile_runtime
            .current()
            .settings
            .server
            .codex_app_server
            .clone();
        let settings_path = ctx.settings_path.clone();
        let result = ctx
            .run_blocking("settings.resetToDefaults", move || {
                crate::settings::SettingsStore::new(settings_path)
                    .reset()
                    .map_err(settings_error)
            })
            .await?;
        reload_profile_runtime_or_rollback(
            ctx,
            previous_sparse.clone(),
            "settings.resetToDefaults",
        )
        .await?;

        refresh_codex_app_server_if_needed(
            ctx,
            &serde_json::json!({"server": {"codexAppServer": true}}),
            previous_sparse,
            previous_codex_app_server,
        )
        .await?;

        Ok(result)
    }
}

/// Update settings.
pub struct UpdateSettingsHandler;

#[async_trait]
impl MethodHandler for UpdateSettingsHandler {
    #[instrument(skip(self, ctx), fields(method = "settings.update"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let updates = require_param(params.as_ref(), "settings")?.clone();
        let codex_updates = updates.clone();
        let has_codex_changes = updates.pointer("/server/codexAppServer").is_some();
        let has_mcp_changes = updates.get("mcp").is_some();
        let settings_path = ctx.settings_path.clone();

        if has_mcp_changes && let Some(ref router) = ctx.mcp_router {
            let mut router_guard = router.write().await;
            let _operation_guard = crate::settings::SettingsStore::operation_lock().await;
            let previous_sparse = read_sparse_settings_snapshot(ctx).await?;
            let previous_codex_app_server = ctx
                .profile_runtime
                .current()
                .settings
                .server
                .codex_app_server
                .clone();
            ctx.run_blocking("settings.update", move || {
                crate::settings::SettingsStore::new(settings_path)
                    .update(updates)
                    .map_err(settings_error)
            })
            .await?;

            if let Err(message) = router_guard.reload_from_settings().await {
                rollback_sparse_settings(ctx, previous_sparse, "settings.rollbackMcpUpdate")
                    .await?;
                return Err(RpcError::Internal { message });
            }
            if let Err(error) = ctx.profile_runtime.reload_now("settings.update") {
                rollback_sparse_settings(
                    ctx,
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
                return Err(RpcError::Internal {
                    message: format!(
                        "profile runtime rejected the updated settings; sparse settings were rolled back: {error}"
                    ),
                });
            }
            drop(router_guard);
            mcp::broadcast_status_changed(ctx).await;
            refresh_codex_app_server_if_needed(
                ctx,
                &codex_updates,
                previous_sparse,
                previous_codex_app_server,
            )
            .await?;
            return Ok(serde_json::json!({ "success": true }));
        }

        let _operation_guard = crate::settings::SettingsStore::operation_lock().await;
        let previous_sparse = read_sparse_settings_snapshot(ctx).await?;
        let previous_codex_app_server = ctx
            .profile_runtime
            .current()
            .settings
            .server
            .codex_app_server
            .clone();
        ctx.run_blocking("settings.update", move || {
            crate::settings::SettingsStore::new(settings_path)
                .update(updates)
                .map_err(settings_error)
        })
        .await?;
        reload_profile_runtime_or_rollback(ctx, previous_sparse.clone(), "settings.update").await?;

        if has_codex_changes {
            refresh_codex_app_server_if_needed(
                ctx,
                &codex_updates,
                previous_sparse,
                previous_codex_app_server,
            )
            .await?;
        }

        Ok(serde_json::json!({ "success": true }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::server::codex_app::{
        CodexAppServerChild, CodexAppServerExit, CodexAppServerLaunchSpec, CodexAppServerManager,
        CodexAppServerSpawner, CodexAppServerState,
    };
    use crate::server::rpc::handlers::test_helpers::make_test_context;
    use crate::server::rpc::registry::MethodRegistry;
    use crate::server::rpc::types::RpcRequest;
    use crate::settings::CodexAppServerSettings;
    use async_trait::async_trait;
    use serde_json::json;
    use std::io;
    use std::sync::{Arc, Mutex};
    use std::time::Duration;

    struct SettingsTestGuard {
        _guard: std::sync::MutexGuard<'static, ()>,
    }

    impl Drop for SettingsTestGuard {
        fn drop(&mut self) {
            crate::settings::init_settings(crate::settings::TronSettings::default());
        }
    }

    // M31: use the shared `crate::settings::test_settings_lock()` so async
    // handler tests here serialize with the sync tests in `settings::tests`
    // against the single process-global `SETTINGS`. Before M31 these two
    // test surfaces used disjoint mutexes, which caused sporadic races
    // (observable as poisoned mutexes when any parallel test failed).
    async fn settings_test_guard() -> SettingsTestGuard {
        let guard = crate::settings::test_settings_lock()
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        crate::settings::init_settings(crate::settings::TronSettings::default());
        SettingsTestGuard { _guard: guard }
    }

    fn make_ctx_with_temp_settings() -> (crate::server::rpc::context::RpcContext, tempfile::TempDir)
    {
        let ctx = make_test_context();
        let dir = tempfile::tempdir().unwrap();
        let _ = std::fs::remove_file(&ctx.settings_path);
        (ctx, dir)
    }

    async fn get_settings_result(ctx: &RpcContext) -> Value {
        let mut registry = MethodRegistry::new();
        crate::server::rpc::handlers::register_all(&mut registry);
        let response = registry
            .dispatch(
                RpcRequest {
                    id: "test-settings-get".to_owned(),
                    method: "settings.get".to_owned(),
                    params: Some(json!({})),
                },
                ctx,
            )
            .await;
        assert!(response.success, "settings.get: {:?}", response.error);
        response.result.unwrap()
    }

    #[derive(Default)]
    struct SettingsFakeSpawner {
        specs: Mutex<Vec<CodexAppServerLaunchSpec>>,
    }

    #[async_trait]
    impl CodexAppServerSpawner for SettingsFakeSpawner {
        async fn spawn(
            &self,
            spec: CodexAppServerLaunchSpec,
        ) -> io::Result<Box<dyn CodexAppServerChild>> {
            self.specs.lock().unwrap().push(spec);
            Ok(Box::new(SettingsFakeChild))
        }
    }

    struct SettingsFakeChild;

    #[async_trait]
    impl CodexAppServerChild for SettingsFakeChild {
        fn id(&self) -> Option<u32> {
            Some(456)
        }

        fn try_wait(&mut self) -> io::Result<Option<CodexAppServerExit>> {
            Ok(None)
        }

        async fn terminate(&mut self, _timeout: Duration) -> io::Result<()> {
            Ok(())
        }
    }

    fn attach_codex_manager(
        ctx: &mut crate::server::rpc::context::RpcContext,
        token_dir: &tempfile::TempDir,
    ) -> (Arc<CodexAppServerManager>, Arc<SettingsFakeSpawner>) {
        let spawner = Arc::new(SettingsFakeSpawner::default());
        let manager = Arc::new(
            CodexAppServerManager::with_deps(
                CodexAppServerSettings::default(),
                token_dir.path().join("codex-token"),
                spawner.clone(),
                Duration::ZERO,
                Duration::from_millis(1),
            )
            .unwrap(),
        );
        ctx.codex_app_server = Some(manager.clone());
        (manager, spawner)
    }

    #[tokio::test]
    async fn get_settings_returns_defaults() {
        let _guard = settings_test_guard().await;
        let (ctx, _dir) = make_ctx_with_temp_settings();
        let result = get_settings_result(&ctx).await;
        assert!(result.is_object());
        assert!(result.get("server").is_some());
    }

    #[tokio::test]
    async fn get_settings_uses_last_valid_profile_runtime_snapshot() {
        let _guard = settings_test_guard().await;
        let (ctx, _dir) = make_ctx_with_temp_settings();
        let profile_path = ctx
            .profile_runtime
            .home()
            .join(crate::core::paths::dirs::PROFILES)
            .join(crate::core::profile::DEFAULT_PROFILE)
            .join(crate::core::paths::files::PROFILE_TOML);
        std::fs::write(profile_path, "{broken").unwrap();

        let result = get_settings_result(&ctx).await;

        assert_eq!(result["server"]["defaultModel"], "claude-sonnet-4-6");
    }

    #[tokio::test]
    async fn get_settings_has_no_models_key() {
        let _guard = settings_test_guard().await;
        let (ctx, _dir) = make_ctx_with_temp_settings();
        let result = get_settings_result(&ctx).await;
        // ModelSettings removed — default_model lives in server, subagent_model in agent
        assert!(result.get("models").is_none());
        assert!(result["server"]["defaultModel"].is_string());
        assert!(result["agent"]["subagentModel"].is_string());
    }

    #[tokio::test]
    async fn get_settings_has_server() {
        let _guard = settings_test_guard().await;
        let (ctx, _dir) = make_ctx_with_temp_settings();
        let result = get_settings_result(&ctx).await;
        assert!(result["server"].is_object());
    }

    #[tokio::test]
    async fn get_settings_wire_format() {
        let _guard = settings_test_guard().await;
        let (ctx, _dir) = make_ctx_with_temp_settings();
        let result = get_settings_result(&ctx).await;
        assert!(result.get("version").is_some());
        assert!(result.get("server").is_some());
        assert!(result.get("context").is_some());
    }

    #[tokio::test]
    async fn get_settings_returns_default_model_in_server_section() {
        let _guard = settings_test_guard().await;
        let (ctx, _dir) = make_ctx_with_temp_settings();
        let result = get_settings_result(&ctx).await;
        assert_eq!(result["server"]["defaultModel"], "claude-sonnet-4-6");
    }

    #[tokio::test]
    async fn get_settings_returns_compaction_in_context_section() {
        let _guard = settings_test_guard().await;
        let (ctx, _dir) = make_ctx_with_temp_settings();
        let result = get_settings_result(&ctx).await;
        assert!(result["context"]["compactor"].is_object());
        assert!(result["context"]["compactor"]["maxTokens"].is_number());
    }

    #[tokio::test]
    async fn get_settings_returns_tools() {
        let _guard = settings_test_guard().await;
        let (ctx, _dir) = make_ctx_with_temp_settings();
        let result = get_settings_result(&ctx).await;
        assert!(result["tools"].is_object());
    }

    #[tokio::test]
    async fn update_settings_returns_success() {
        let _guard = settings_test_guard().await;
        let (ctx, _dir) = make_ctx_with_temp_settings();
        let result = UpdateSettingsHandler
            .handle(
                Some(json!({"settings": {"server": {"heartbeatIntervalMs": 40_000}}})),
                &ctx,
            )
            .await
            .unwrap();
        assert_eq!(result["success"], true);
    }

    #[tokio::test]
    async fn update_settings_writes_to_disk() {
        let _guard = settings_test_guard().await;
        let (ctx, _dir) = make_ctx_with_temp_settings();
        assert!(!ctx.settings_path.exists());

        let _ = UpdateSettingsHandler
            .handle(
                Some(json!({"settings": {"server": {"heartbeatIntervalMs": 40_000}}})),
                &ctx,
            )
            .await
            .unwrap();

        assert!(ctx.settings_path.exists());
    }

    #[tokio::test]
    async fn update_settings_merges_deep() {
        let _guard = settings_test_guard().await;
        let (ctx, _dir) = make_ctx_with_temp_settings();

        let _ = UpdateSettingsHandler
            .handle(
                Some(json!({"settings": {"server": {"defaultModel": "model-a", "defaultProvider": "anthropic"}}})),
                &ctx,
            )
            .await
            .unwrap();

        let _ = UpdateSettingsHandler
            .handle(
                Some(json!({"settings": {"server": {"defaultProvider": "openai"}}})),
                &ctx,
            )
            .await
            .unwrap();

        let saved = crate::settings::SettingsStore::new(&ctx.settings_path)
            .read_sparse_value()
            .unwrap();
        assert_eq!(saved["server"]["defaultProvider"], "openai");
        assert_eq!(saved["server"]["defaultModel"], "model-a");
    }

    #[tokio::test]
    async fn update_settings_rejects_malformed_existing_toml() {
        let _guard = settings_test_guard().await;
        let (ctx, _dir) = make_ctx_with_temp_settings();
        std::fs::write(&ctx.settings_path, "{broken").unwrap();

        let err = UpdateSettingsHandler
            .handle(
                Some(json!({"settings": {"server": {"heartbeatIntervalMs": 99_000}}})),
                &ctx,
            )
            .await
            .unwrap_err();

        assert!(err.to_string().contains("parse settings TOML"));
        assert_eq!(
            std::fs::read_to_string(&ctx.settings_path).unwrap(),
            "{broken"
        );
    }

    #[tokio::test]
    async fn update_settings_rejects_removed_auth_setting() {
        let _guard = settings_test_guard().await;
        let (ctx, _dir) = make_ctx_with_temp_settings();

        let err = UpdateSettingsHandler
            .handle(
                Some(json!({"settings": {"server": {"auth": {"enforced": true}}}})),
                &ctx,
            )
            .await
            .unwrap_err();

        assert!(err.to_string().contains("unknown field"));
        assert!(!ctx.settings_path.exists());
    }

    #[tokio::test]
    async fn update_settings_accepts_mcp_camel_case_wire_keys() {
        let _guard = settings_test_guard().await;
        let (ctx, _dir) = make_ctx_with_temp_settings();

        let _ = UpdateSettingsHandler
            .handle(
                Some(json!({
                    "settings": {
                        "mcp": {
                            "schemaRefreshTtlMs": 45_000,
                            "servers": [{
                                "name": "example",
                                "command": "example-mcp",
                                "args": [],
                                "env": {},
                                "toolTimeoutMs": 12_000,
                                "enabled": false
                            }]
                        }
                    }
                })),
                &ctx,
            )
            .await
            .unwrap();

        let settings = crate::settings::get_settings();
        assert_eq!(settings.mcp.schema_refresh_ttl_ms, 45_000);
        assert_eq!(settings.mcp.servers[0].tool_timeout_ms, 12_000);
    }

    #[tokio::test]
    async fn update_settings_rolls_back_when_mcp_apply_fails() {
        let _guard = settings_test_guard().await;
        let (mut ctx, _dir) = make_ctx_with_temp_settings();
        crate::settings::SettingsStore::new(&ctx.settings_path)
            .reset()
            .unwrap();
        ctx.mcp_router = Some(std::sync::Arc::new(tokio::sync::RwLock::new(
            crate::mcp::router::McpRouter::new(Vec::new(), ctx.settings_path.clone(), 0).await,
        )));

        let err = UpdateSettingsHandler
            .handle(
                Some(json!({
                    "settings": {
                        "mcp": {
                            "servers": [{
                                "name": "broken",
                                "command": "nonexistent-mcp-binary-12345",
                                "args": [],
                                "env": {},
                                "toolTimeoutMs": 30000,
                                "enabled": true
                            }]
                        }
                    }
                })),
                &ctx,
            )
            .await
            .unwrap_err();

        assert!(err.to_string().contains("broken"));
        let saved = crate::settings::SettingsStore::new(&ctx.settings_path)
            .read_sparse_value()
            .unwrap();
        assert_eq!(saved, json!({}));
        assert!(
            ctx.mcp_router
                .as_ref()
                .unwrap()
                .read()
                .await
                .status()
                .is_empty()
        );
    }

    #[tokio::test]
    async fn update_settings_preserves_unmodified() {
        let _guard = settings_test_guard().await;
        let (ctx, _dir) = make_ctx_with_temp_settings();

        let _ = UpdateSettingsHandler
            .handle(
                Some(json!({"settings": {"server": {"defaultModel": "model-a", "defaultProvider": "anthropic"}}})),
                &ctx,
            )
            .await
            .unwrap();

        let _ = UpdateSettingsHandler
            .handle(
                Some(json!({"settings": {"server": {"defaultProvider": "openai"}}})),
                &ctx,
            )
            .await
            .unwrap();

        let saved = crate::settings::SettingsStore::new(&ctx.settings_path)
            .read_sparse_value()
            .unwrap();
        assert_eq!(saved["server"]["defaultProvider"], "openai");
        assert_eq!(saved["server"]["defaultModel"], "model-a");
    }

    #[tokio::test]
    async fn update_settings_missing_settings_param() {
        let _guard = settings_test_guard().await;
        let (ctx, _dir) = make_ctx_with_temp_settings();
        let err = UpdateSettingsHandler
            .handle(Some(json!({})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
    }

    #[tokio::test]
    async fn update_settings_creates_file_if_missing() {
        let _guard = settings_test_guard().await;
        let (ctx, _dir) = make_ctx_with_temp_settings();

        let _ = UpdateSettingsHandler
            .handle(
                Some(json!({"settings": {"server": {"heartbeatIntervalMs": 40_000}}})),
                &ctx,
            )
            .await
            .unwrap();
        assert!(ctx.settings_path.exists());
    }

    #[tokio::test]
    async fn update_settings_reconfigures_codex_app_server_runtime() {
        let _guard = settings_test_guard().await;
        let (mut ctx, dir) = make_ctx_with_temp_settings();
        let (manager, spawner) = attach_codex_manager(&mut ctx, &dir);

        let _ = UpdateSettingsHandler
            .handle(
                Some(json!({"settings": {"server": {"codexAppServer": {"port": 4517}}}})),
                &ctx,
            )
            .await
            .unwrap();

        let status = manager.status().await;
        assert_eq!(status.state, CodexAppServerState::Running);
        assert_eq!(status.endpoint.unwrap().port, 4517);
        assert_eq!(spawner.specs.lock().unwrap().len(), 1);
    }

    #[tokio::test]
    async fn reset_settings_returns_defaults() {
        let _guard = settings_test_guard().await;
        let (ctx, _dir) = make_ctx_with_temp_settings();

        // Customize a setting first
        let _ = UpdateSettingsHandler
            .handle(
                Some(json!({"settings": {"server": {"heartbeatIntervalMs": 99_000}}})),
                &ctx,
            )
            .await
            .unwrap();

        // Reset
        let result = ResetSettingsHandler.handle(None, &ctx).await.unwrap();
        assert!(result.is_object());
        // heartbeatIntervalMs should be back to default (30_000)
        assert_eq!(result["server"]["heartbeatIntervalMs"], 30_000);
    }

    #[tokio::test]
    async fn reset_settings_reconfigures_codex_app_server_to_defaults() {
        let _guard = settings_test_guard().await;
        let (mut ctx, dir) = make_ctx_with_temp_settings();
        let (manager, spawner) = attach_codex_manager(&mut ctx, &dir);

        let _ = UpdateSettingsHandler
            .handle(
                Some(json!({"settings": {"server": {"codexAppServer": {"port": 4518}}}})),
                &ctx,
            )
            .await
            .unwrap();

        let _ = ResetSettingsHandler.handle(None, &ctx).await.unwrap();

        let status = manager.status().await;
        assert_eq!(status.state, CodexAppServerState::Running);
        assert_eq!(status.endpoint.unwrap().port, 4500);
        assert_eq!(spawner.specs.lock().unwrap().len(), 2);
    }

    #[tokio::test]
    async fn reset_settings_clears_disk_customizations() {
        let _guard = settings_test_guard().await;
        let (ctx, _dir) = make_ctx_with_temp_settings();

        // Write some customizations
        let _ = UpdateSettingsHandler
            .handle(
                Some(json!({"settings": {"server": {"heartbeatIntervalMs": 40_000}}})),
                &ctx,
            )
            .await
            .unwrap();
        assert!(ctx.settings_path.exists());

        // Reset
        let _ = ResetSettingsHandler.handle(None, &ctx).await.unwrap();

        // The file should still exist but contain only {}
        let saved = crate::settings::SettingsStore::new(&ctx.settings_path)
            .read_sparse_value()
            .unwrap();
        assert_eq!(saved, json!({}));
    }

    #[tokio::test]
    async fn update_settings_reloads_cached_singleton() {
        let _guard = settings_test_guard().await;
        let (ctx, _dir) = make_ctx_with_temp_settings();

        // Prime the cache with defaults pointing at temp path
        crate::settings::reload_settings_from_path(&ctx.settings_path).unwrap();
        assert!(
            crate::settings::get_settings()
                .context
                .rules
                .discover_standalone_files,
            "discover_standalone_files should default to true"
        );

        // Simulate client toggling discover_standalone_files off via settings.update RPC
        let _ = UpdateSettingsHandler
            .handle(
                Some(json!({
                    "settings": {
                        "context": {
                            "rules": {
                                "discoverStandaloneFiles": false
                            }
                        }
                    }
                })),
                &ctx,
            )
            .await
            .unwrap();

        // The cached singleton should now reflect the update
        let settings = crate::settings::get_settings();
        assert!(
            !settings.context.rules.discover_standalone_files,
            "discover_standalone_files should be false after settings.update RPC"
        );
    }
}
