//! Settings handlers: get, update.

use async_trait::async_trait;
use serde_json::Value;
use std::path::Path;
use tokio::task;
use tracing::instrument;

use crate::rpc::context::RpcContext;
use crate::rpc::errors::RpcError;
use crate::rpc::handlers::require_param;
use crate::rpc::registry::MethodHandler;

fn read_settings_json(path: &Path) -> Result<Value, RpcError> {
    if !path.exists() {
        return Ok(Value::Object(serde_json::Map::default()));
    }

    let content = std::fs::read_to_string(path).map_err(|e| RpcError::Internal {
        message: format!("Failed to read settings: {e}"),
    })?;

    Ok(serde_json::from_str::<Value>(&content)
        .unwrap_or_else(|_| Value::Object(serde_json::Map::default())))
}

fn write_settings_json(path: &Path, value: &Value) -> Result<(), RpcError> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|e| RpcError::Internal {
            message: format!("Failed to create settings directory: {e}"),
        })?;
    }

    let content = serde_json::to_string_pretty(value).map_err(|e| RpcError::Internal {
        message: e.to_string(),
    })?;
    std::fs::write(path, content).map_err(|e| RpcError::Internal {
        message: format!("Failed to write settings: {e}"),
    })?;
    Ok(())
}

/// Get current settings.
pub struct GetSettingsHandler;

#[async_trait]
impl MethodHandler for GetSettingsHandler {
    #[instrument(skip(self, ctx), fields(method = "settings.get"))]
    async fn handle(&self, _params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let settings_path = ctx.settings_path.clone();
        let settings = task::spawn_blocking(move || {
            tron_settings::load_settings_from_path(&settings_path).unwrap_or_default()
        })
        .await
        .map_err(|e| RpcError::Internal {
            message: format!("Failed to load settings in blocking task: {e}"),
        })?;

        let value = serde_json::to_value(settings).map_err(|e| RpcError::Internal {
            message: e.to_string(),
        })?;

        Ok(value)
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
        task::spawn_blocking(move || -> Result<(), RpcError> {
            let current = read_settings_json(&settings_path)?;

            // Deep merge updates over current
            let merged = tron_settings::deep_merge(current, updates);

            write_settings_json(&settings_path, &merged)
        })
        .await
        .map_err(|e| RpcError::Internal {
            message: format!("Settings update task failed: {e}"),
        })??;

        Ok(serde_json::json!({ "success": true }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::rpc::handlers::test_helpers::make_test_context;
    use serde_json::json;
    use std::path::PathBuf;

    fn make_ctx_with_temp_settings() -> (crate::rpc::context::RpcContext, tempfile::TempDir) {
        let mut ctx = make_test_context();
        let dir = tempfile::tempdir().unwrap();
        ctx.settings_path = dir.path().join("settings.json");
        (ctx, dir)
    }

    #[tokio::test]
    async fn get_settings_returns_defaults() {
        let (ctx, _dir) = make_ctx_with_temp_settings();
        let result = GetSettingsHandler.handle(None, &ctx).await.unwrap();
        assert!(result.is_object());
        assert!(result.get("server").is_some());
    }

    #[tokio::test]
    async fn get_settings_has_models() {
        let (ctx, _dir) = make_ctx_with_temp_settings();
        let result = GetSettingsHandler.handle(None, &ctx).await.unwrap();
        assert!(result.get("models").is_some());
        assert!(result["models"]["default"].is_string());
    }

    #[tokio::test]
    async fn get_settings_has_server() {
        let (ctx, _dir) = make_ctx_with_temp_settings();
        let result = GetSettingsHandler.handle(None, &ctx).await.unwrap();
        assert!(result["server"].is_object());
    }

    #[tokio::test]
    async fn get_settings_wire_format() {
        let (ctx, _dir) = make_ctx_with_temp_settings();
        let result = GetSettingsHandler.handle(None, &ctx).await.unwrap();
        assert!(result.get("version").is_some());
        assert!(result.get("models").is_some());
        assert!(result.get("server").is_some());
        assert!(result.get("context").is_some());
    }

    #[tokio::test]
    async fn get_settings_returns_default_model_in_models_section() {
        let (ctx, _dir) = make_ctx_with_temp_settings();
        let result = GetSettingsHandler.handle(None, &ctx).await.unwrap();
        assert!(result["models"]["default"].is_string());
    }

    #[tokio::test]
    async fn get_settings_returns_max_concurrent_sessions_in_server_section() {
        let (ctx, _dir) = make_ctx_with_temp_settings();
        let result = GetSettingsHandler.handle(None, &ctx).await.unwrap();
        assert!(result["server"]["maxConcurrentSessions"].is_number());
    }

    #[tokio::test]
    async fn get_settings_returns_compaction_in_context_section() {
        let (ctx, _dir) = make_ctx_with_temp_settings();
        let result = GetSettingsHandler.handle(None, &ctx).await.unwrap();
        assert!(result["context"]["compactor"].is_object());
        assert!(result["context"]["compactor"]["maxTokens"].is_number());
    }

    #[tokio::test]
    async fn get_settings_returns_memory_in_context_section() {
        let (ctx, _dir) = make_ctx_with_temp_settings();
        let result = GetSettingsHandler.handle(None, &ctx).await.unwrap();
        assert!(result["context"]["memory"].is_object());
        assert!(result["context"]["memory"]["ledger"].is_object());
        assert!(result["context"]["memory"]["autoInject"].is_object());
    }

    #[tokio::test]
    async fn get_settings_returns_tools() {
        let (ctx, _dir) = make_ctx_with_temp_settings();
        let result = GetSettingsHandler.handle(None, &ctx).await.unwrap();
        assert!(result["tools"].is_object());
    }

    #[tokio::test]
    async fn update_settings_returns_success() {
        let (ctx, _dir) = make_ctx_with_temp_settings();
        let result = UpdateSettingsHandler
            .handle(Some(json!({"settings": {"theme": "dark"}})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["success"], true);
    }

    #[tokio::test]
    async fn update_settings_writes_to_disk() {
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
        let (ctx, _dir) = make_ctx_with_temp_settings();
        let err = UpdateSettingsHandler
            .handle(Some(json!({})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
    }

    #[tokio::test]
    async fn update_settings_creates_file_if_missing() {
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
}
