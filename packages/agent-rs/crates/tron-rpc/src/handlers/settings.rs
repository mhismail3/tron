//! Settings handlers: get, update.

use async_trait::async_trait;
use serde_json::Value;

use crate::context::RpcContext;
use crate::errors::RpcError;
use crate::handlers::require_param;
use crate::registry::MethodHandler;

/// Get current settings.
pub struct GetSettingsHandler;

#[async_trait]
impl MethodHandler for GetSettingsHandler {
    async fn handle(&self, _params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let settings =
            tron_settings::load_settings_from_path(&ctx.settings_path).unwrap_or_default();

        serde_json::to_value(settings).map_err(|e| RpcError::Internal {
            message: e.to_string(),
        })
    }
}

/// Update settings.
pub struct UpdateSettingsHandler;

#[async_trait]
impl MethodHandler for UpdateSettingsHandler {
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let updates = require_param(params.as_ref(), "settings")?.clone();

        // Load current settings as JSON
        let current = if ctx.settings_path.exists() {
            let content = std::fs::read_to_string(&ctx.settings_path).map_err(|e| {
                RpcError::Internal {
                    message: format!("Failed to read settings: {e}"),
                }
            })?;
            serde_json::from_str::<Value>(&content).unwrap_or_else(|_| Value::Object(serde_json::Map::default()))
        } else {
            Value::Object(serde_json::Map::default())
        };

        // Deep merge updates over current
        let merged = tron_settings::deep_merge(current, updates);

        // Ensure parent directory exists
        if let Some(parent) = ctx.settings_path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }

        // Write back
        let content = serde_json::to_string_pretty(&merged).map_err(|e| RpcError::Internal {
            message: e.to_string(),
        })?;
        std::fs::write(&ctx.settings_path, content).map_err(|e| RpcError::Internal {
            message: format!("Failed to write settings: {e}"),
        })?;

        Ok(serde_json::json!({ "success": true }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::handlers::test_helpers::make_test_context;
    use serde_json::json;
    use std::path::PathBuf;

    fn make_ctx_with_temp_settings() -> (crate::context::RpcContext, tempfile::TempDir) {
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
        // Should have top-level keys
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
        // camelCase keys from serde(rename_all = "camelCase")
        assert!(result.get("version").is_some());
        assert!(result.get("models").is_some());
        assert!(result.get("server").is_some());
        assert!(result.get("context").is_some());
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

        // Write initial settings
        let _ = UpdateSettingsHandler
            .handle(
                Some(json!({"settings": {"server": {"wsPort": 9999}, "theme": "light"}})),
                &ctx,
            )
            .await
            .unwrap();

        // Update only theme, server should be preserved
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
            .handle(
                Some(json!({"settings": {"a": 1, "b": 2}})),
                &ctx,
            )
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
