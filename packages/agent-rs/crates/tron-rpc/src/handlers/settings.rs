//! Settings handlers: get, update.

use async_trait::async_trait;
use serde_json::Value;
use tracing::instrument;

use crate::context::RpcContext;
use crate::errors::RpcError;
use crate::handlers::require_param;
use crate::registry::MethodHandler;

/// Transform `TronSettings` into an iOS-compatible flat shape.
/// iOS expects top-level keys like `defaultModel`, `maxConcurrentSessions`,
/// `compaction`, `memory`, `rules`, `tasks`, `tools`.
/// We merge these flat keys into the full settings object so both iOS (which
/// ignores unknown keys) and other consumers (which use the nested shape) work.
fn add_ios_compat_fields(settings: &mut Value) {
    let Some(obj) = settings.as_object_mut() else {
        return;
    };

    // defaultModel from models.default
    if let Some(model) = obj
        .get("models")
        .and_then(|m| m.get("default"))
        .cloned()
    {
        let _ = obj.insert("defaultModel".into(), model);
    }

    // maxConcurrentSessions from server.maxConcurrentSessions
    if let Some(val) = obj
        .get("server")
        .and_then(|s| s.get("maxConcurrentSessions"))
        .cloned()
    {
        let _ = obj.insert("maxConcurrentSessions".into(), val);
    }

    // defaultWorkspace from server.defaultWorkspace
    if let Some(val) = obj
        .get("server")
        .and_then(|s| s.get("defaultWorkspace"))
        .cloned()
    {
        let _ = obj.insert("defaultWorkspace".into(), val);
    }

    // Hoist context sub-sections to top level
    if let Some(context) = obj.get("context").cloned() {
        if let Some(mut compaction) = context.get("compactor").cloned() {
            // iOS expects `preserveRecentTurns`, Rust serializes `preserveRecentCount`
            if let Some(c) = compaction.as_object_mut() {
                if let Some(val) = c.remove("preserveRecentCount") {
                    let _ = c.insert("preserveRecentTurns".into(), val);
                }
            }
            let _ = obj.insert("compaction".into(), compaction);
        }
        if let Some(memory) = context.get("memory").cloned() {
            let _ = obj.insert("memory".into(), memory);
        }
        if let Some(rules) = context.get("rules").cloned() {
            let _ = obj.insert("rules".into(), rules);
        }
        if let Some(tasks) = context.get("tasks").cloned() {
            let _ = obj.insert("tasks".into(), tasks);
        }
    }
}

/// Get current settings.
pub struct GetSettingsHandler;

#[async_trait]
impl MethodHandler for GetSettingsHandler {
    #[instrument(skip(self, ctx), fields(method = "settings.get"))]
    async fn handle(&self, _params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let settings =
            tron_settings::load_settings_from_path(&ctx.settings_path).unwrap_or_default();

        let mut value = serde_json::to_value(settings).map_err(|e| RpcError::Internal {
            message: e.to_string(),
        })?;

        add_ios_compat_fields(&mut value);

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
    async fn get_settings_returns_default_model() {
        let (ctx, _dir) = make_ctx_with_temp_settings();
        let result = GetSettingsHandler.handle(None, &ctx).await.unwrap();
        assert!(result["defaultModel"].is_string());
    }

    #[tokio::test]
    async fn get_settings_returns_max_concurrent_sessions() {
        let (ctx, _dir) = make_ctx_with_temp_settings();
        let result = GetSettingsHandler.handle(None, &ctx).await.unwrap();
        assert!(result["maxConcurrentSessions"].is_number());
    }

    #[tokio::test]
    async fn get_settings_returns_compaction() {
        let (ctx, _dir) = make_ctx_with_temp_settings();
        let result = GetSettingsHandler.handle(None, &ctx).await.unwrap();
        assert!(result["compaction"].is_object());
        assert!(result["compaction"]["maxTokens"].is_number());
    }

    #[tokio::test]
    async fn get_settings_returns_memory() {
        let (ctx, _dir) = make_ctx_with_temp_settings();
        let result = GetSettingsHandler.handle(None, &ctx).await.unwrap();
        assert!(result["memory"].is_object());
        assert!(result["memory"]["ledger"].is_object());
        assert!(result["memory"]["autoInject"].is_object());
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
