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

/// Get current settings.
pub struct GetSettingsHandler;

#[async_trait]
impl MethodHandler for GetSettingsHandler {
    #[instrument(skip(self, ctx), fields(method = "settings.get"))]
    async fn handle(&self, _params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let settings_path = ctx.settings_path.clone();
        ctx.run_blocking("settings.get", move || {
            crate::settings::SettingsStore::new(settings_path)
                .load_value()
                .map_err(settings_error)
        })
        .await
    }
}

/// Reset all settings to defaults.
pub struct ResetSettingsHandler;

#[async_trait]
impl MethodHandler for ResetSettingsHandler {
    #[instrument(skip(self, ctx), fields(method = "settings.resetToDefaults"))]
    async fn handle(&self, _params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let _operation_guard = crate::settings::SettingsStore::operation_lock().await;
        let settings_path = ctx.settings_path.clone();
        ctx.run_blocking("settings.resetToDefaults", move || {
            crate::settings::SettingsStore::new(settings_path)
                .reset()
                .map_err(settings_error)
        })
        .await
    }
}

/// Update settings.
pub struct UpdateSettingsHandler;

#[async_trait]
impl MethodHandler for UpdateSettingsHandler {
    #[instrument(skip(self, ctx), fields(method = "settings.update"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let updates = require_param(params.as_ref(), "settings")?.clone();
        let has_mcp_changes = updates.get("mcp").is_some();
        let settings_path = ctx.settings_path.clone();

        if has_mcp_changes && let Some(ref router) = ctx.mcp_router {
            let mut router_guard = router.write().await;
            let _operation_guard = crate::settings::SettingsStore::operation_lock().await;
            let previous_sparse = {
                let path = settings_path.clone();
                ctx.run_blocking("settings.readSparseBeforeMcpUpdate", move || {
                    crate::settings::SettingsStore::new(path)
                        .read_sparse_value()
                        .map_err(settings_error)
                })
                .await?
            };
            ctx.run_blocking("settings.update", move || {
                crate::settings::SettingsStore::new(settings_path)
                    .update(updates)
                    .map_err(settings_error)
            })
            .await?;

            if let Err(message) = router_guard.reload_from_settings().await {
                let path = ctx.settings_path.clone();
                ctx.run_blocking("settings.rollbackMcpUpdate", move || {
                    crate::settings::SettingsStore::new(path)
                        .replace_sparse_value(previous_sparse)
                        .map_err(settings_error)
                })
                .await?;
                return Err(RpcError::Internal { message });
            }
            drop(router_guard);
            mcp::broadcast_status_changed(ctx).await;
            return Ok(serde_json::json!({ "success": true }));
        }

        let _operation_guard = crate::settings::SettingsStore::operation_lock().await;
        ctx.run_blocking("settings.update", move || {
            crate::settings::SettingsStore::new(settings_path)
                .update(updates)
                .map_err(settings_error)
        })
        .await?;

        Ok(serde_json::json!({ "success": true }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::server::rpc::handlers::test_helpers::make_test_context;
    use serde_json::json;
    use std::path::PathBuf;

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
        let mut ctx = make_test_context();
        let dir = tempfile::tempdir().unwrap();
        ctx.settings_path = dir.path().join("settings.json");
        (ctx, dir)
    }

    #[tokio::test]
    async fn get_settings_returns_defaults() {
        let _guard = settings_test_guard().await;
        let (ctx, _dir) = make_ctx_with_temp_settings();
        let result = GetSettingsHandler.handle(None, &ctx).await.unwrap();
        assert!(result.is_object());
        assert!(result.get("server").is_some());
    }

    #[tokio::test]
    async fn get_settings_has_no_models_key() {
        let _guard = settings_test_guard().await;
        let (ctx, _dir) = make_ctx_with_temp_settings();
        let result = GetSettingsHandler.handle(None, &ctx).await.unwrap();
        // ModelSettings removed — default_model lives in server, subagent_model in agent
        assert!(result.get("models").is_none());
        assert!(result["server"]["defaultModel"].is_string());
        assert!(result["agent"]["subagentModel"].is_string());
    }

    #[tokio::test]
    async fn get_settings_has_server() {
        let _guard = settings_test_guard().await;
        let (ctx, _dir) = make_ctx_with_temp_settings();
        let result = GetSettingsHandler.handle(None, &ctx).await.unwrap();
        assert!(result["server"].is_object());
    }

    #[tokio::test]
    async fn get_settings_wire_format() {
        let _guard = settings_test_guard().await;
        let (ctx, _dir) = make_ctx_with_temp_settings();
        let result = GetSettingsHandler.handle(None, &ctx).await.unwrap();
        assert!(result.get("version").is_some());
        assert!(result.get("server").is_some());
        assert!(result.get("context").is_some());
    }

    #[tokio::test]
    async fn get_settings_returns_default_model_in_server_section() {
        let _guard = settings_test_guard().await;
        let (ctx, _dir) = make_ctx_with_temp_settings();
        let result = GetSettingsHandler.handle(None, &ctx).await.unwrap();
        assert_eq!(result["server"]["defaultModel"], "claude-sonnet-4-6");
    }

    #[tokio::test]
    async fn get_settings_returns_compaction_in_context_section() {
        let _guard = settings_test_guard().await;
        let (ctx, _dir) = make_ctx_with_temp_settings();
        let result = GetSettingsHandler.handle(None, &ctx).await.unwrap();
        assert!(result["context"]["compactor"].is_object());
        assert!(result["context"]["compactor"]["maxTokens"].is_number());
    }

    #[tokio::test]
    async fn get_settings_returns_tools() {
        let _guard = settings_test_guard().await;
        let (ctx, _dir) = make_ctx_with_temp_settings();
        let result = GetSettingsHandler.handle(None, &ctx).await.unwrap();
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

        let content = std::fs::read_to_string(&ctx.settings_path).unwrap();
        let saved: Value = serde_json::from_str(&content).unwrap();
        assert_eq!(saved["server"]["defaultProvider"], "openai");
        assert_eq!(saved["server"]["defaultModel"], "model-a");
    }

    #[tokio::test]
    async fn update_settings_rejects_malformed_existing_json() {
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

        assert!(err.to_string().contains("parse settings JSON"));
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
        let saved: Value =
            serde_json::from_str(&std::fs::read_to_string(&ctx.settings_path).unwrap()).unwrap();
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

        let content = std::fs::read_to_string(&ctx.settings_path).unwrap();
        let saved: Value = serde_json::from_str(&content).unwrap();
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
        let nested_path = PathBuf::from(ctx.settings_path.parent().unwrap())
            .join("subdir")
            .join("settings.json");
        let mut ctx = ctx;
        ctx.settings_path = nested_path.clone();

        let _ = UpdateSettingsHandler
            .handle(
                Some(json!({"settings": {"server": {"heartbeatIntervalMs": 40_000}}})),
                &ctx,
            )
            .await
            .unwrap();
        assert!(nested_path.exists());
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
        let content = std::fs::read_to_string(&ctx.settings_path).unwrap();
        let saved: Value = serde_json::from_str(&content).unwrap();
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
