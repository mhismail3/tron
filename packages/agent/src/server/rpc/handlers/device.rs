//! Device handlers: register, unregister.
//!
//! # INVARIANT: client-supplied `bundleId` is trusted (L8, trusted-local)
//!
//! [`RegisterTokenHandler`] accepts a caller-supplied `bundleId`
//! (e.g. `com.tron.mobile`, `com.tron.mobile.beta`) with only a
//! non-empty format check, and persists it alongside the APNs device
//! token. APNs uses `bundleId` as the push `apns-topic`, so a client
//! could register a token under a bundle it doesn't actually own —
//! under trusted-local this is a non-issue (the only registrants are
//! the user's own devices, and APNs itself rejects mismatched topics
//! at delivery time). Under a shared or adversarial threat model, a
//! malicious client could register under a Prod bundle from a Beta
//! build and redirect notifications.
//!
//! Hardening path: tie `bundleId` to the authenticated caller via a
//! server-issued device certificate, or validate against a fixed
//! allow-list when `settings.devices.strictBundleId = true`.

use async_trait::async_trait;
use serde_json::Value;
use tracing::instrument;

use crate::server::rpc::context::RpcContext;
use crate::server::rpc::errors::RpcError;
use crate::server::rpc::handlers::{map_event_store_error, opt_string, require_string_param};
use crate::server::rpc::registry::MethodHandler;

/// Register an APNS device token.
pub struct RegisterTokenHandler;

#[async_trait]
impl MethodHandler for RegisterTokenHandler {
    #[instrument(skip(self, ctx), fields(method = "device.register"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let device_token = require_string_param(params.as_ref(), "deviceToken")?;

        // Validate token format: APNS device tokens are 32 bytes = 64 hex chars
        if device_token.len() != 64 || !device_token.chars().all(|c| c.is_ascii_hexdigit()) {
            return Err(RpcError::InvalidParams {
                message: format!(
                    "Invalid device token: expected 64 hex chars, got {} chars",
                    device_token.len()
                ),
            });
        }

        let session_id = opt_string(params.as_ref(), "sessionId");
        let workspace_id = opt_string(params.as_ref(), "workspaceId");
        let environment = opt_string(params.as_ref(), "environment");
        let bundle_id = opt_string(params.as_ref(), "bundleId");
        if let Some(ref bid) = bundle_id
            && bid.is_empty()
        {
            return Err(RpcError::InvalidParams {
                message: "bundleId must not be empty".into(),
            });
        }

        let event_store = ctx.event_store.clone();
        ctx.run_blocking("device.register", move || {
            let result = event_store
                .register_device_token(
                    &device_token,
                    session_id.as_deref(),
                    workspace_id.as_deref(),
                    environment.as_deref().unwrap_or("production"),
                    bundle_id.as_deref(),
                )
                .map_err(map_event_store_error)?;

            Ok(serde_json::json!({
                "id": result.id,
                "created": result.created,
            }))
        })
        .await
    }
}

/// Resolve a pending device request (sent by iOS in response to `device.request` event).
pub struct DeviceRespondHandler;

#[async_trait]
impl MethodHandler for DeviceRespondHandler {
    #[instrument(skip(self, ctx), fields(method = "device.respond"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let request_id = require_string_param(params.as_ref(), "requestId")?;
        let result = params
            .as_ref()
            .and_then(|p| p.get("result"))
            .cloned()
            .unwrap_or(Value::Null);

        if let Some(ref broker) = ctx.device_request_broker {
            let resolved = broker.resolve(&request_id, result);
            Ok(serde_json::json!({ "resolved": resolved }))
        } else {
            Err(RpcError::Internal {
                message: "Device request broker not available".into(),
            })
        }
    }
}

/// Unregister an APNS device token.
pub struct UnregisterTokenHandler;

#[async_trait]
impl MethodHandler for UnregisterTokenHandler {
    #[instrument(skip(self, ctx), fields(method = "device.unregister"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let device_token = require_string_param(params.as_ref(), "deviceToken")?;

        let event_store = ctx.event_store.clone();
        ctx.run_blocking("device.unregister", move || {
            let success = event_store
                .unregister_device_token(&device_token)
                .map_err(map_event_store_error)?;

            Ok(serde_json::json!({ "success": success }))
        })
        .await
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::server::rpc::handlers::test_helpers::make_test_context;
    use serde_json::json;

    #[tokio::test]
    async fn register_token_returns_id_and_created() {
        let ctx = make_test_context();
        let result = RegisterTokenHandler
            .handle(
                Some(json!({
                    "deviceToken": "a".repeat(64),
                    "environment": "sandbox"
                })),
                &ctx,
            )
            .await
            .unwrap();

        assert!(result["id"].is_string());
        assert!(!result["id"].as_str().unwrap().is_empty());
        assert_eq!(result["created"], true);
    }

    #[tokio::test]
    async fn register_token_existing_returns_created_false() {
        let ctx = make_test_context();
        let token = "b".repeat(64);
        let first = RegisterTokenHandler
            .handle(Some(json!({"deviceToken": token})), &ctx)
            .await
            .unwrap();
        let second = RegisterTokenHandler
            .handle(Some(json!({"deviceToken": token})), &ctx)
            .await
            .unwrap();

        assert_eq!(first["id"], second["id"]);
        assert_eq!(first["created"], true);
        assert_eq!(second["created"], false);
    }

    #[tokio::test]
    async fn register_token_missing_param() {
        let ctx = make_test_context();
        let err = RegisterTokenHandler
            .handle(Some(json!({})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
    }

    #[tokio::test]
    async fn register_token_with_optional_params() {
        let ctx = make_test_context();
        // Register without session/workspace (FK constraints prevent fake IDs in test DB)
        let result = RegisterTokenHandler
            .handle(
                Some(json!({
                    "deviceToken": "c".repeat(64),
                    "environment": "production"
                })),
                &ctx,
            )
            .await
            .unwrap();
        assert!(result["id"].is_string());
        assert_eq!(result["created"], true);
    }

    #[tokio::test]
    async fn register_token_default_environment() {
        let ctx = make_test_context();
        let result = RegisterTokenHandler
            .handle(Some(json!({"deviceToken": "d".repeat(64)})), &ctx)
            .await
            .unwrap();
        // Should succeed with default "production" environment
        assert_eq!(result["created"], true);
    }

    #[tokio::test]
    async fn unregister_token_success() {
        let ctx = make_test_context();
        let token = "e".repeat(64);
        // Register first
        let _ = RegisterTokenHandler
            .handle(Some(json!({"deviceToken": token})), &ctx)
            .await
            .unwrap();
        // Then unregister
        let result = UnregisterTokenHandler
            .handle(Some(json!({"deviceToken": token})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["success"], true);
    }

    #[tokio::test]
    async fn unregister_token_not_found() {
        let ctx = make_test_context();
        let result = UnregisterTokenHandler
            .handle(Some(json!({"deviceToken": "nonexistent"})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["success"], false);
    }

    #[tokio::test]
    async fn unregister_token_missing_param() {
        let ctx = make_test_context();
        let err = UnregisterTokenHandler
            .handle(Some(json!({})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
    }

    #[tokio::test]
    async fn register_response_matches_wire_format() {
        // Wire format: { id: String, created: Bool }
        let ctx = make_test_context();
        let result = RegisterTokenHandler
            .handle(Some(json!({"deviceToken": "f".repeat(64)})), &ctx)
            .await
            .unwrap();

        // Both fields must be present and correct types
        assert!(result.get("id").is_some(), "missing 'id' field");
        assert!(result.get("created").is_some(), "missing 'created' field");
        assert!(result["id"].is_string(), "'id' must be String");
        assert!(result["created"].is_boolean(), "'created' must be Bool");
    }

    #[tokio::test]
    async fn register_rejects_too_long_token() {
        let ctx = make_test_context();
        let err = RegisterTokenHandler
            .handle(Some(json!({"deviceToken": "a".repeat(160)})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
    }

    #[tokio::test]
    async fn register_rejects_too_short_token() {
        let ctx = make_test_context();
        let err = RegisterTokenHandler
            .handle(Some(json!({"deviceToken": "abc123"})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
    }

    #[tokio::test]
    async fn register_rejects_non_hex_token() {
        let ctx = make_test_context();
        let token = "g".repeat(64); // 'g' is not hex
        let err = RegisterTokenHandler
            .handle(Some(json!({"deviceToken": token})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
    }

    #[tokio::test]
    async fn unregister_response_matches_wire_format() {
        // Wire format: { success: Bool }
        let ctx = make_test_context();
        let result = UnregisterTokenHandler
            .handle(Some(json!({"deviceToken": "x"})), &ctx)
            .await
            .unwrap();

        assert!(result.get("success").is_some(), "missing 'success' field");
        assert!(result["success"].is_boolean(), "'success' must be Bool");
    }

    // ── bundleId flow (v006) ─────────────────────────────────────────

    #[tokio::test]
    async fn register_token_with_bundle_id_stores_it() {
        let ctx = make_test_context();
        let token = "1".repeat(64);
        let _ = RegisterTokenHandler
            .handle(
                Some(json!({
                    "deviceToken": token,
                    "environment": "sandbox",
                    "bundleId": "com.tron.mobile.beta",
                })),
                &ctx,
            )
            .await
            .unwrap();

        let rows = ctx.event_store.get_all_active_device_tokens().unwrap();
        let row = rows.iter().find(|r| r.device_token == token).unwrap();
        assert_eq!(row.bundle_id.as_deref(), Some("com.tron.mobile.beta"));
        assert_eq!(row.environment, "sandbox");
    }

    #[tokio::test]
    async fn register_token_without_bundle_id_stores_null() {
        let ctx = make_test_context();
        let token = "2".repeat(64);
        let _ = RegisterTokenHandler
            .handle(Some(json!({"deviceToken": token})), &ctx)
            .await
            .unwrap();

        let rows = ctx.event_store.get_all_active_device_tokens().unwrap();
        let row = rows.iter().find(|r| r.device_token == token).unwrap();
        assert!(row.bundle_id.is_none());
    }

    #[tokio::test]
    async fn register_token_rejects_empty_bundle_id() {
        let ctx = make_test_context();
        let err = RegisterTokenHandler
            .handle(
                Some(json!({
                    "deviceToken": "3".repeat(64),
                    "bundleId": "",
                })),
                &ctx,
            )
            .await
            .unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
    }

    #[tokio::test]
    async fn register_token_with_different_bundle_creates_distinct_row() {
        // M3: the same APNs push token registered twice with different
        // bundle_ids is now TWO distinct rows (one per apns-topic). Before
        // v007 the second register clobbered the first, so a device running
        // both Prod and Beta schemes from the same iOS install had only the
        // most-recently-registered bundle receiving pushes. Post-v007, both
        // rows coexist and APNs can fan out to both topics.
        let ctx = make_test_context();
        let token = "4".repeat(64);

        RegisterTokenHandler
            .handle(
                Some(json!({
                    "deviceToken": token,
                    "environment": "production",
                    "bundleId": "com.tron.mobile",
                })),
                &ctx,
            )
            .await
            .unwrap();

        RegisterTokenHandler
            .handle(
                Some(json!({
                    "deviceToken": token,
                    "environment": "sandbox",
                    "bundleId": "com.tron.mobile.beta",
                })),
                &ctx,
            )
            .await
            .unwrap();

        let rows: Vec<_> = ctx
            .event_store
            .get_all_active_device_tokens()
            .unwrap()
            .into_iter()
            .filter(|r| r.device_token == token)
            .collect();
        assert_eq!(
            rows.len(),
            2,
            "two distinct bundle_ids must produce two rows post-v007"
        );

        let prod = rows
            .iter()
            .find(|r| r.bundle_id.as_deref() == Some("com.tron.mobile"))
            .expect("production-bundle row must be present and active");
        assert_eq!(prod.environment, "production");
        assert!(prod.is_active);

        let beta = rows
            .iter()
            .find(|r| r.bundle_id.as_deref() == Some("com.tron.mobile.beta"))
            .expect("beta-bundle row must be present and active");
        assert_eq!(beta.environment, "sandbox");
        assert!(beta.is_active);
    }

    #[tokio::test]
    async fn register_token_same_bundle_is_idempotent_update() {
        // Regression guard for the M3 happy path: re-registering the SAME
        // (token, bundle_id, workspace_id) triple within the same identity
        // is still a single-row update, not a new insert. Only cross-bundle
        // or cross-workspace re-registers fan out into distinct rows.
        let ctx = make_test_context();
        let token = "5".repeat(64);

        let first = RegisterTokenHandler
            .handle(
                Some(json!({
                    "deviceToken": token,
                    "environment": "sandbox",
                    "bundleId": "com.tron.mobile.beta",
                })),
                &ctx,
            )
            .await
            .unwrap();
        assert_eq!(first["created"], true);

        let second = RegisterTokenHandler
            .handle(
                Some(json!({
                    "deviceToken": token,
                    "environment": "sandbox",
                    "bundleId": "com.tron.mobile.beta",
                })),
                &ctx,
            )
            .await
            .unwrap();
        assert_eq!(second["created"], false);
        assert_eq!(first["id"], second["id"]);

        let rows: Vec<_> = ctx
            .event_store
            .get_all_active_device_tokens()
            .unwrap()
            .into_iter()
            .filter(|r| r.device_token == token)
            .collect();
        assert_eq!(rows.len(), 1, "same-identity reregister must stay single-row");
        assert_eq!(rows[0].bundle_id.as_deref(), Some("com.tron.mobile.beta"));
        assert_eq!(rows[0].environment, "sandbox");
    }
}
