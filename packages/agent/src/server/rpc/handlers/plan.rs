//! Plan RPC group.
//!
//! `plan.enter`, `plan.exit`, and `plan.getState` are marker-registered in
//! `handlers::mod` and executed by engine-owned generic trigger functions.
//! This module remains as progressive disclosure docs plus wire-compatibility
//! tests for the collapsed plan group.

#[cfg(test)]
mod tests {
    use crate::server::rpc::context::RpcContext;
    use crate::server::rpc::handlers::test_helpers::make_test_context;
    use crate::server::rpc::registry::MethodRegistry;
    use crate::server::rpc::types::{RpcErrorBody, RpcRequest};
    use serde_json::{Value, json};

    async fn dispatch_plan_ok(ctx: &RpcContext, method: &str, params: Value) -> Value {
        let mut registry = MethodRegistry::new();
        crate::server::rpc::handlers::register_all(&mut registry);
        let response = registry
            .dispatch(
                RpcRequest {
                    id: format!("test-{method}"),
                    method: method.to_owned(),
                    params: Some(params),
                },
                ctx,
            )
            .await;
        assert!(response.success, "{method}: {:?}", response.error);
        response.result.unwrap()
    }

    async fn dispatch_plan_err(ctx: &RpcContext, method: &str, params: Value) -> RpcErrorBody {
        let mut registry = MethodRegistry::new();
        crate::server::rpc::handlers::register_all(&mut registry);
        let response = registry
            .dispatch(
                RpcRequest {
                    id: format!("test-{method}"),
                    method: method.to_owned(),
                    params: Some(params),
                },
                ctx,
            )
            .await;
        assert!(!response.success, "{method}: {:?}", response.result);
        response.error.unwrap()
    }

    #[tokio::test]
    async fn enter_plan_sets_true() {
        let ctx = make_test_context();
        let result = dispatch_plan_ok(&ctx, "plan.enter", json!({"sessionId": "s1"})).await;
        assert_eq!(result["planMode"], true);
        assert!(ctx.session_manager.is_plan_mode("s1"));
    }

    #[tokio::test]
    async fn enter_plan_missing_session() {
        let ctx = make_test_context();
        let err = dispatch_plan_err(&ctx, "plan.enter", json!({})).await;
        assert_eq!(err.code, "INVALID_PARAMS");
    }

    #[tokio::test]
    async fn exit_plan_sets_false() {
        let ctx = make_test_context();
        ctx.session_manager.set_plan_mode("s1", true);
        let result = dispatch_plan_ok(&ctx, "plan.exit", json!({"sessionId": "s1"})).await;
        assert_eq!(result["planMode"], false);
        assert!(!ctx.session_manager.is_plan_mode("s1"));
    }

    #[tokio::test]
    async fn get_state_reads_actual_state() {
        let ctx = make_test_context();
        let result = dispatch_plan_ok(&ctx, "plan.getState", json!({"sessionId": "s1"})).await;
        assert_eq!(result["planMode"], false);

        ctx.session_manager.set_plan_mode("s1", true);
        let result = dispatch_plan_ok(&ctx, "plan.getState", json!({"sessionId": "s1"})).await;
        assert_eq!(result["planMode"], true);
    }

    #[tokio::test]
    async fn toggle_round_trip() {
        let ctx = make_test_context();
        let _ = dispatch_plan_ok(&ctx, "plan.enter", json!({"sessionId": "s1"})).await;
        assert!(ctx.session_manager.is_plan_mode("s1"));

        let _ = dispatch_plan_ok(&ctx, "plan.exit", json!({"sessionId": "s1"})).await;
        assert!(!ctx.session_manager.is_plan_mode("s1"));
    }

    #[tokio::test]
    async fn different_sessions_independent() {
        let ctx = make_test_context();
        ctx.session_manager.set_plan_mode("s1", true);
        ctx.session_manager.set_plan_mode("s2", false);

        assert!(ctx.session_manager.is_plan_mode("s1"));
        assert!(!ctx.session_manager.is_plan_mode("s2"));
    }

    #[tokio::test]
    async fn missing_session_defaults_to_false() {
        let ctx = make_test_context();
        let result =
            dispatch_plan_ok(&ctx, "plan.getState", json!({"sessionId": "nonexistent"})).await;
        assert_eq!(result["planMode"], false);
    }
}
