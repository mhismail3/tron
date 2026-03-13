//! Settings handlers: get, update.

use async_trait::async_trait;
use serde_json::Value;
use tracing::instrument;

use crate::rpc::context::RpcContext;
use crate::rpc::errors::RpcError;
use crate::rpc::handlers::require_param;
use crate::rpc::registry::MethodHandler;
use crate::rpc::settings_service;

/// Get current settings.
pub struct GetSettingsHandler;

#[async_trait]
impl MethodHandler for GetSettingsHandler {
    #[instrument(skip(self, ctx), fields(method = "settings.get"))]
    async fn handle(&self, _params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let settings_path = ctx.settings_path.clone();
        ctx.run_blocking("settings.get", move || {
            settings_service::load_settings_value(&settings_path)
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
        let settings_path = ctx.settings_path.clone();
        ctx.run_blocking("settings.update", move || {
            settings_service::update_settings(&settings_path, updates)
        })
        .await?;

        Ok(serde_json::json!({ "success": true }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::rpc::handlers::test_helpers::make_test_context;
    use crate::rpc::settings_service::settings_reload_lock;
    use serde_json::json;
    use std::path::PathBuf;

    struct SettingsTestGuard {
        _guard: tokio::sync::MutexGuard<'static, ()>,
    }

    impl Drop for SettingsTestGuard {
        fn drop(&mut self) {
            tron_settings::init_settings(tron_settings::TronSettings::default());
        }
    }

    async fn settings_test_guard() -> SettingsTestGuard {
        let guard = settings_reload_lock().lock().await;
        tron_settings::init_settings(tron_settings::TronSettings::default());
        SettingsTestGuard { _guard: guard }
    }

    fn make_ctx_with_temp_settings() -> (crate::rpc::context::RpcContext, tempfile::TempDir) {
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
    async fn get_settings_returns_max_concurrent_sessions_in_server_section() {
        let _guard = settings_test_guard().await;
        let (ctx, _dir) = make_ctx_with_temp_settings();
        let result = GetSettingsHandler.handle(None, &ctx).await.unwrap();
        assert!(result["server"]["maxConcurrentSessions"].is_number());
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
    async fn get_settings_returns_memory_in_context_section() {
        let _guard = settings_test_guard().await;
        let (ctx, _dir) = make_ctx_with_temp_settings();
        let result = GetSettingsHandler.handle(None, &ctx).await.unwrap();
        assert!(result["context"]["memory"].is_object());
        assert!(result["context"]["memory"]["ledger"].is_object());
        assert!(result["context"]["memory"]["autoInject"].is_object());
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
            .handle(Some(json!({"settings": {"theme": "dark"}})), &ctx)
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
            .handle(Some(json!({"settings": {"theme": "dark"}})), &ctx)
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
                Some(json!({"settings": {"server": {"wsPort": 9999}, "theme": "light"}})),
                &ctx,
            )
            .await
            .unwrap();

        let _ = UpdateSettingsHandler
            .handle(Some(json!({"settings": {"theme": "dark"}})), &ctx)
            .await
            .unwrap();

        let content = std::fs::read_to_string(&ctx.settings_path).unwrap();
        let saved: Value = serde_json::from_str(&content).unwrap();
        assert_eq!(saved["theme"], "dark");
        assert_eq!(saved["server"]["wsPort"], 9999);
    }

    #[tokio::test]
    async fn update_settings_preserves_unmodified() {
        let _guard = settings_test_guard().await;
        let (ctx, _dir) = make_ctx_with_temp_settings();

        let _ = UpdateSettingsHandler
            .handle(Some(json!({"settings": {"a": 1, "b": 2}})), &ctx)
            .await
            .unwrap();

        let _ = UpdateSettingsHandler
            .handle(Some(json!({"settings": {"a": 10}})), &ctx)
            .await
            .unwrap();

        let content = std::fs::read_to_string(&ctx.settings_path).unwrap();
        let saved: Value = serde_json::from_str(&content).unwrap();
        assert_eq!(saved["a"], 10);
        assert_eq!(saved["b"], 2);
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
            .handle(Some(json!({"settings": {"x": 1}})), &ctx)
            .await
            .unwrap();
        assert!(nested_path.exists());
    }

    #[tokio::test]
    async fn update_settings_reloads_cached_singleton() {
        let _guard = settings_test_guard().await;
        let (ctx, _dir) = make_ctx_with_temp_settings();

        // Prime the cache with defaults pointing at temp path
        tron_settings::reload_settings_from_path(&ctx.settings_path);
        assert!(
            tron_settings::get_settings()
                .context
                .memory
                .auto_inject
                .enabled,
            "auto_inject should default to true"
        );

        // Simulate client toggling auto-inject off via settings.update RPC
        let _ = UpdateSettingsHandler
            .handle(
                Some(json!({
                    "settings": {
                        "context": {
                            "memory": {
                                "autoInject": {"enabled": false}
                            }
                        }
                    }
                })),
                &ctx,
            )
            .await
            .unwrap();

        // The cached singleton should now reflect the update
        let settings = tron_settings::get_settings();
        assert!(
            !settings.context.memory.auto_inject.enabled,
            "auto_inject should be false after settings.update RPC"
        );
    }

    #[tokio::test]
    async fn update_settings_reloads_ledger_toggle() {
        let _guard = settings_test_guard().await;
        let (ctx, _dir) = make_ctx_with_temp_settings();

        // Prime the cache
        tron_settings::reload_settings_from_path(&ctx.settings_path);
        assert!(
            tron_settings::get_settings().context.memory.ledger.enabled,
            "ledger should default to true"
        );

        // Toggle ledger off
        let _ = UpdateSettingsHandler
            .handle(
                Some(json!({
                    "settings": {
                        "context": {
                            "memory": {
                                "ledger": {"enabled": false}
                            }
                        }
                    }
                })),
                &ctx,
            )
            .await
            .unwrap();

        let settings = tron_settings::get_settings();
        assert!(
            !settings.context.memory.ledger.enabled,
            "ledger should be false after settings.update RPC"
        );
    }
}
