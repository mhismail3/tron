use super::*;

#[tokio::test]
async fn device_read_runtime_grants_are_read_only_and_selector_bounded() {
    for operation in ["device_list", "device_inspect"] {
        let payload = if operation == "device_inspect" {
            json!({
                "operation": operation,
                "deviceRegistrationResourceId": "device_registration:runtime-grant",
                "idempotencyKey": format!("{operation}-grant")
            })
        } else {
            json!({
                "operation": operation,
                "idempotencyKey": format!("{operation}-grant")
            })
        };
        let (engine_host, invocation) = captured_execute_invocation_for_payload(payload).await;
        let grant = engine_host
            .inspect_authority_grant(&invocation.causal_context.authority_grant_id)
            .await
            .expect("inspect grant")
            .expect("derived grant");

        assert_eq!(grant.network_policy, "none");
        for scope in ["device.read", "resource.read"] {
            assert!(
                grant.allowed_authority_scopes.contains(&scope.to_owned()),
                "device read grant should include {scope}"
            );
        }
        for forbidden_scope in ["device.write", "resource.write", "notifications.write"] {
            assert!(
                !grant
                    .allowed_authority_scopes
                    .contains(&forbidden_scope.to_owned()),
                "device read grant must not include {forbidden_scope}"
            );
        }
        assert_eq!(
            grant.allowed_resource_kinds,
            vec!["agent_state".to_owned(), "device_registration".to_owned()]
        );
        assert_eq!(
            grant.resource_selectors,
            vec![
                "kind:agent_state".to_owned(),
                "kind:device_registration".to_owned()
            ]
        );
    }
}

#[tokio::test]
async fn provider_device_write_operations_do_not_gain_device_write_authority() {
    for operation in ["device_register", "device_unregister"] {
        let payload = if operation == "device_register" {
            json!({
                "operation": operation,
                "deviceId": "runtime-grant-device",
                "apnsEnvironment": "development",
                "apnsToken": "abcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcd",
                "idempotencyKey": format!("{operation}-grant")
            })
        } else {
            json!({
                "operation": operation,
                "deviceRegistrationResourceId": "device_registration:runtime-grant",
                "reason": "test",
                "idempotencyKey": format!("{operation}-grant")
            })
        };
        let (engine_host, invocation) = captured_execute_invocation_for_payload(payload).await;
        let grant = engine_host
            .inspect_authority_grant(&invocation.causal_context.authority_grant_id)
            .await
            .expect("inspect grant")
            .expect("derived grant");

        for forbidden_scope in ["device.read", "device.write", "resource.write"] {
            assert!(
                !grant
                    .allowed_authority_scopes
                    .contains(&forbidden_scope.to_owned()),
                "provider device write operation must not include {forbidden_scope}"
            );
        }
        assert!(
            !grant
                .allowed_resource_kinds
                .contains(&"device_registration".to_owned())
        );
        assert!(
            !grant
                .resource_selectors
                .contains(&"kind:device_registration".to_owned())
        );
    }
}

#[tokio::test]
async fn notification_read_runtime_grants_are_selector_bounded() {
    for operation in ["notification_list", "notification_inspect"] {
        let payload = if operation == "notification_inspect" {
            json!({
                "operation": operation,
                "notificationResourceId": "notification:runtime-grant",
                "idempotencyKey": format!("{operation}-grant")
            })
        } else {
            json!({
                "operation": operation,
                "idempotencyKey": format!("{operation}-grant")
            })
        };
        let (engine_host, invocation) = captured_execute_invocation_for_payload(payload).await;
        let grant = engine_host
            .inspect_authority_grant(&invocation.causal_context.authority_grant_id)
            .await
            .expect("inspect grant")
            .expect("derived grant");

        assert_eq!(grant.network_policy, "none");
        for scope in ["notifications.read", "resource.read"] {
            assert!(
                grant.allowed_authority_scopes.contains(&scope.to_owned()),
                "notification read grant should include {scope}"
            );
        }
        assert!(
            !grant
                .allowed_authority_scopes
                .contains(&"notifications.write".to_owned())
        );
        let expected_kinds = if operation == "notification_inspect" {
            vec![
                "agent_state".to_owned(),
                "notification".to_owned(),
                "notification_delivery".to_owned(),
            ]
        } else {
            vec!["agent_state".to_owned(), "notification".to_owned()]
        };
        assert_eq!(grant.allowed_resource_kinds, expected_kinds);
        for selector in grant.resource_selectors.iter() {
            assert!(
                selector.starts_with("kind:"),
                "notification grant should use kind selectors only, got {selector}"
            );
            assert_ne!(selector, "kind:*");
        }
    }
}

#[tokio::test]
async fn notification_write_grant_adds_device_read_only_when_push_requested() {
    for (push_requested, expect_device) in [(false, false), (true, true)] {
        let (engine_host, invocation) = captured_execute_invocation_for_payload(json!({
            "operation": "notification_send",
            "title": "Runtime grant",
            "body": "Runtime grant body",
            "pushRequested": push_requested,
            "idempotencyKey": format!("notification-send-grant-{push_requested}")
        }))
        .await;
        let grant = engine_host
            .inspect_authority_grant(&invocation.causal_context.authority_grant_id)
            .await
            .expect("inspect grant")
            .expect("derived grant");

        for scope in [
            "notifications.read",
            "notifications.write",
            "resource.read",
            "resource.write",
        ] {
            assert!(
                grant.allowed_authority_scopes.contains(&scope.to_owned()),
                "notification write grant should include {scope}"
            );
        }
        assert_eq!(
            grant
                .allowed_authority_scopes
                .contains(&"device.read".to_owned()),
            expect_device
        );
        assert_eq!(
            grant
                .allowed_resource_kinds
                .contains(&"device_registration".to_owned()),
            expect_device
        );
        assert_eq!(
            grant
                .resource_selectors
                .contains(&"kind:device_registration".to_owned()),
            expect_device
        );
        for kind in ["notification", "notification_delivery"] {
            assert!(grant.allowed_resource_kinds.contains(&kind.to_owned()));
            assert!(grant.resource_selectors.contains(&format!("kind:{kind}")));
        }
        for forbidden_scope in [
            "device.write",
            "web.write",
            "tool.execute",
            "subagents.write",
        ] {
            assert!(
                !grant
                    .allowed_authority_scopes
                    .contains(&forbidden_scope.to_owned()),
                "notification write grant must not include {forbidden_scope}"
            );
        }
    }
}
