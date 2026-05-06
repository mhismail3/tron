//! Settings RPC group.
//!
//! `settings.get`, `settings.update`, and `settings.resetToDefaults` are
//! marker-registered in `handlers::mod` and executed by engine-owned
//! canonical functions under `settings::*`. This module remains as progressive
//! disclosure docs plus wire-compatibility tests for the collapsed settings
//! group.

#[cfg(test)]
mod tests {
    use crate::server::codex_app::{
        CodexAppServerChild, CodexAppServerExit, CodexAppServerLaunchSpec, CodexAppServerManager,
        CodexAppServerSpawner, CodexAppServerState,
    };
    use crate::server::rpc::context::RpcContext;
    use crate::server::rpc::handlers::test_helpers::make_test_context;
    use crate::server::rpc::registry::MethodRegistry;
    use crate::server::rpc::types::{RpcErrorBody, RpcRequest, RpcResponse};
    use crate::settings::CodexAppServerSettings;
    use async_trait::async_trait;
    use serde_json::{Value, json};
    use std::io;
    use std::sync::atomic::{AtomicUsize, Ordering};
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

    fn next_request_id(method: &str) -> String {
        static NEXT_ID: AtomicUsize = AtomicUsize::new(1);
        format!("{method}-{}", NEXT_ID.fetch_add(1, Ordering::SeqCst))
    }

    async fn dispatch_settings_response(
        ctx: &RpcContext,
        method: &str,
        params: Option<Value>,
    ) -> RpcResponse {
        let mut registry = MethodRegistry::new();
        crate::server::rpc::handlers::register_all(&mut registry);
        registry
            .dispatch(
                RpcRequest {
                    id: next_request_id(method),
                    method: method.to_owned(),
                    params,
                },
                ctx,
            )
            .await
    }

    async fn dispatch_settings_ok(ctx: &RpcContext, method: &str, params: Option<Value>) -> Value {
        let response = dispatch_settings_response(ctx, method, params).await;
        assert!(response.success, "{method}: {:?}", response.error);
        response.result.unwrap()
    }

    async fn dispatch_settings_err(
        ctx: &RpcContext,
        method: &str,
        params: Option<Value>,
    ) -> RpcErrorBody {
        let response = dispatch_settings_response(ctx, method, params).await;
        assert!(!response.success, "{method}: {:?}", response.result);
        response.error.unwrap()
    }

    async fn update_settings_ok(ctx: &RpcContext, settings: Value) -> Value {
        dispatch_settings_ok(
            ctx,
            "settings.update",
            Some(json!({ "settings": settings })),
        )
        .await
    }

    async fn reset_settings_ok(ctx: &RpcContext) -> Value {
        dispatch_settings_ok(ctx, "settings.resetToDefaults", None).await
    }

    async fn get_settings_result(ctx: &RpcContext) -> Value {
        dispatch_settings_ok(ctx, "settings.get", Some(json!({}))).await
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
        refresh_engine_bridge(ctx);
        (manager, spawner)
    }

    fn refresh_engine_bridge(ctx: &mut RpcContext) {
        ctx.engine_host = crate::engine::EngineHostHandle::new_in_memory().unwrap();
        let mut registry = MethodRegistry::new();
        crate::server::rpc::handlers::register_all(&mut registry);
        crate::server::rpc::engine_bridge::register_rpc_worker_for_context(ctx, &registry).unwrap();
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
        let result =
            update_settings_ok(&ctx, json!({"server": {"heartbeatIntervalMs": 40_000}})).await;
        assert_eq!(result["success"], true);
    }

    #[tokio::test]
    async fn update_settings_writes_to_disk() {
        let _guard = settings_test_guard().await;
        let (ctx, _dir) = make_ctx_with_temp_settings();
        assert!(!ctx.settings_path.exists());

        let _ = update_settings_ok(&ctx, json!({"server": {"heartbeatIntervalMs": 40_000}})).await;

        assert!(ctx.settings_path.exists());
    }

    #[tokio::test]
    async fn update_settings_merges_deep() {
        let _guard = settings_test_guard().await;
        let (ctx, _dir) = make_ctx_with_temp_settings();

        let _ = update_settings_ok(
            &ctx,
            json!({"server": {"defaultModel": "model-a", "defaultProvider": "anthropic"}}),
        )
        .await;

        let _ = update_settings_ok(&ctx, json!({"server": {"defaultProvider": "openai"}})).await;

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

        let err = dispatch_settings_err(
            &ctx,
            "settings.update",
            Some(json!({"settings": {"server": {"heartbeatIntervalMs": 99_000}}})),
        )
        .await;

        assert_eq!(err.message, "Internal error");
        assert_eq!(
            std::fs::read_to_string(&ctx.settings_path).unwrap(),
            "{broken"
        );
    }

    #[tokio::test]
    async fn update_settings_rejects_removed_auth_setting() {
        let _guard = settings_test_guard().await;
        let (ctx, _dir) = make_ctx_with_temp_settings();

        let err = dispatch_settings_err(
            &ctx,
            "settings.update",
            Some(json!({"settings": {"server": {"auth": {"enforced": true}}}})),
        )
        .await;

        assert_eq!(err.message, "Internal error");
        assert!(!ctx.settings_path.exists());
    }

    #[tokio::test]
    async fn update_settings_accepts_mcp_camel_case_wire_keys() {
        let _guard = settings_test_guard().await;
        let (ctx, _dir) = make_ctx_with_temp_settings();

        let _ = update_settings_ok(
            &ctx,
            json!({
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
            }),
        )
        .await;

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
        refresh_engine_bridge(&mut ctx);

        let err = dispatch_settings_err(
            &ctx,
            "settings.update",
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
        )
        .await;

        assert_eq!(err.message, "Internal error");
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

        let _ = update_settings_ok(
            &ctx,
            json!({"server": {"defaultModel": "model-a", "defaultProvider": "anthropic"}}),
        )
        .await;

        let _ = update_settings_ok(&ctx, json!({"server": {"defaultProvider": "openai"}})).await;

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
        let err = dispatch_settings_err(&ctx, "settings.update", Some(json!({}))).await;
        assert_eq!(err.code, "INVALID_PARAMS");
    }

    #[tokio::test]
    async fn update_settings_creates_file_if_missing() {
        let _guard = settings_test_guard().await;
        let (ctx, _dir) = make_ctx_with_temp_settings();

        let _ = update_settings_ok(&ctx, json!({"server": {"heartbeatIntervalMs": 40_000}})).await;
        assert!(ctx.settings_path.exists());
    }

    #[tokio::test]
    async fn update_settings_reconfigures_codex_app_server_runtime() {
        let _guard = settings_test_guard().await;
        let (mut ctx, dir) = make_ctx_with_temp_settings();
        let (manager, spawner) = attach_codex_manager(&mut ctx, &dir);

        let _ =
            update_settings_ok(&ctx, json!({"server": {"codexAppServer": {"port": 4517}}})).await;

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
        let _ = update_settings_ok(&ctx, json!({"server": {"heartbeatIntervalMs": 99_000}})).await;

        // Reset
        let result = reset_settings_ok(&ctx).await;
        assert!(result.is_object());
        // heartbeatIntervalMs should be back to default (30_000)
        assert_eq!(result["server"]["heartbeatIntervalMs"], 30_000);
    }

    #[tokio::test]
    async fn reset_settings_reconfigures_codex_app_server_to_defaults() {
        let _guard = settings_test_guard().await;
        let (mut ctx, dir) = make_ctx_with_temp_settings();
        let (manager, spawner) = attach_codex_manager(&mut ctx, &dir);

        let _ =
            update_settings_ok(&ctx, json!({"server": {"codexAppServer": {"port": 4518}}})).await;

        let _ = reset_settings_ok(&ctx).await;

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
        let _ = update_settings_ok(&ctx, json!({"server": {"heartbeatIntervalMs": 40_000}})).await;
        assert!(ctx.settings_path.exists());

        // Reset
        let _ = reset_settings_ok(&ctx).await;

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
        let _ = update_settings_ok(
            &ctx,
            json!({
                "context": {
                    "rules": {
                        "discoverStandaloneFiles": false
                    }
                }
            }),
        )
        .await;

        // The cached singleton should now reflect the update
        let settings = crate::settings::get_settings();
        assert!(
            !settings.context.rules.discover_standalone_files,
            "discover_standalone_files should be false after settings.update RPC"
        );
    }
}
