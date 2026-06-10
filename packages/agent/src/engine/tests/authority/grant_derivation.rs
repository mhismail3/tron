use super::*;

#[tokio::test]
async fn grant_derive_rejects_child_expansion_by_authority_dimension() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    let tmp = tempfile::tempdir().unwrap();
    let allowed_root = tmp.path().join("allowed");
    std::fs::create_dir_all(&allowed_root).unwrap();
    let sibling_root = tmp.path().join("sibling");
    std::fs::create_dir_all(&sibling_root).unwrap();
    let prefix_sibling_root = tmp.path().join("allowed-sibling");
    std::fs::create_dir_all(&prefix_sibling_root).unwrap();
    let parent_component_escape = allowed_root
        .join("missing")
        .join("..")
        .join("..")
        .join("sibling")
        .join("escape.txt");
    let allowed_root = allowed_root.to_string_lossy().to_string();
    let sibling_root = sibling_root.to_string_lossy().to_string();
    let prefix_sibling_root = prefix_sibling_root.to_string_lossy().to_string();
    let parent_component_escape = parent_component_escape.to_string_lossy().to_string();
    let parent_expiry = Utc::now() + ChronoDuration::hours(1);

    let parent = derive_grant(
        &handle,
        json!({
            "grantId": "grant-authority-parent",
            "parentGrantId": "grant",
            "allowedCapabilities": ["demo::write", "demo::read"],
            "allowedNamespaces": ["demo"],
            "allowedAuthorityScopes": ["demo.write", "demo.read"],
            "allowedResourceKinds": ["artifact"],
            "resourceSelectors": ["resource:artifact-a", "kind:artifact"],
            "fileRoots": [allowed_root],
            "networkPolicy": "loopback",
            "maxRisk": "medium",
            "budget": {"remainingInvocations": 10, "maxTokens": 100},
            "expiresAt": parent_expiry.to_rfc3339(),
            "canDelegate": true,
            "provenance": {"source": "grant-authority-test"}
        }),
        "grant-authority-parent",
    )
    .await;
    assert_eq!(parent.error, None);

    let cases: Vec<(&str, Value, &str)> = vec![
        (
            "capability",
            json!({"allowedCapabilities": ["other::write"]}),
            "capabilities",
        ),
        (
            "namespace",
            json!({"allowedNamespaces": ["other"]}),
            "namespaces",
        ),
        (
            "authority-scope",
            json!({"allowedAuthorityScopes": ["other.write"]}),
            "authority scopes",
        ),
        (
            "resource-kind",
            json!({"allowedResourceKinds": ["materialized_file"]}),
            "resource kinds",
        ),
        (
            "resource-selector",
            json!({"resourceSelectors": ["resource:artifact-b"]}),
            "resource selectors",
        ),
        (
            "file-root",
            json!({"fileRoots": [sibling_root]}),
            "file roots",
        ),
        (
            "file-root-prefix-sibling",
            json!({"fileRoots": [prefix_sibling_root]}),
            "file roots",
        ),
        (
            "file-root-parent-component-escape",
            json!({"fileRoots": [parent_component_escape]}),
            "file roots",
        ),
        (
            "network",
            json!({"networkPolicy": "declared"}),
            "network policy",
        ),
        ("risk", json!({"maxRisk": "high"}), "risk"),
        (
            "budget",
            json!({"budget": {"remainingInvocations": 11, "maxTokens": 100}}),
            "budget",
        ),
        (
            "expiry",
            json!({"expiresAt": (parent_expiry + ChronoDuration::minutes(1)).to_rfc3339()}),
            "expiry",
        ),
        (
            "empty-selector",
            json!({"resourceSelectors": []}),
            "resourceSelectors",
        ),
    ];

    for (case, override_fields, expected) in cases {
        let grant_id = format!("grant-authority-child-{case}");
        let mut payload =
            base_child_grant_payload(&grant_id, "grant-authority-parent", &allowed_root);
        let payload_object = payload.as_object_mut().unwrap();
        for (key, value) in override_fields.as_object().unwrap() {
            payload_object.insert(key.clone(), value.clone());
        }
        let result = derive_grant(&handle, payload, &grant_id).await;
        assert!(
            matches!(
                result.error,
                Some(EngineError::PolicyViolation(ref message)) if message.contains(expected)
            ),
            "case {case} should reject with `{expected}`, got {:?}",
            result.error
        );
        assert!(
            !grant_exists(&handle, &grant_id).await,
            "rejected child grant {grant_id} must not be persisted"
        );
    }
}

#[tokio::test]
async fn grant_derivation_rejects_broader_child_grants() {
    let handle = EngineHostHandle::new_in_memory().unwrap();

    let broader = handle
        .invoke(host_invocation(
            "grant::derive",
            json!({
                "grantId": "narrow-parent-grant",
                "parentGrantId": "grant",
                "allowedCapabilities": ["artifact::inspect"],
                "allowedNamespaces": ["artifact"],
                "allowedAuthorityScopes": ["resource.read"],
                "allowedResourceKinds": ["artifact"],
                "resourceSelectors": ["*"],
                "fileRoots": ["*"],
                "networkPolicy": "none",
                "maxRisk": "low",
                "canDelegate": true
            }),
            CausalContext::new(
                actor("system"),
                ActorKind::System,
                grant("grant"),
                trace("grant-derive-parent"),
            )
            .with_scope("grant.write")
            .with_idempotency_key("derive-parent"),
        ))
        .await;
    assert_eq!(broader.error, None);

    let rejected = handle
        .invoke(host_invocation(
            "grant::derive",
            json!({
                "grantId": "broader-grandchild",
                "parentGrantId": "narrow-parent-grant",
                "allowedCapabilities": ["artifact::inspect", "artifact::create"],
                "allowedNamespaces": ["artifact"],
                "allowedAuthorityScopes": ["resource.read"],
                "allowedResourceKinds": ["artifact"],
                "resourceSelectors": ["*"],
                "fileRoots": ["*"],
                "networkPolicy": "none",
                "maxRisk": "low"
            }),
            CausalContext::new(
                actor("system"),
                ActorKind::System,
                grant("grant"),
                trace("grant-derive-child"),
            )
            .with_scope("grant.write")
            .with_idempotency_key("derive-child"),
        ))
        .await;

    assert!(matches!(
        rejected.error,
        Some(EngineError::PolicyViolation(message)) if message.contains("capabilities exceeds parent")
    ));
}

#[tokio::test]
async fn bootstrap_grants_are_explicit_engine_owned_roots() {
    let handle = EngineHostHandle::new_in_memory().unwrap();

    for grant_id in crate::engine::authority::grants::BOOTSTRAP_GRANT_IDS {
        let inspected = handle
            .invoke(host_invocation(
                "grant::inspect",
                json!({"grantId": grant_id}),
                CausalContext::new(
                    actor("system"),
                    ActorKind::System,
                    grant("grant"),
                    trace(&format!("inspect-bootstrap-{grant_id}")),
                )
                .with_scope("grant.read"),
            ))
            .await;
        assert_eq!(
            inspected.error, None,
            "bootstrap grant {grant_id} should inspect"
        );
        let grant = &inspected.value.as_ref().unwrap()["grant"];
        assert_eq!(grant["grantId"], json!(grant_id));
        assert_eq!(grant["parentGrantId"], Value::Null);
        assert_eq!(grant["lifecycle"], json!("active"));
        assert_eq!(grant["allowedCapabilities"], json!(["*"]));
        assert_eq!(grant["allowedNamespaces"], json!(["*"]));
        assert_eq!(grant["allowedAuthorityScopes"], json!(["*"]));
        assert_eq!(grant["allowedResourceKinds"], json!(["*"]));
        assert_eq!(grant["resourceSelectors"], json!(["*"]));
        assert_eq!(grant["fileRoots"], json!(["*"]));
        assert_eq!(grant["networkPolicy"], json!("unrestricted"));
        assert_eq!(grant["maxRisk"], json!("Critical"));
        assert_eq!(grant["budget"], json!({"class": "bootstrap"}));
        assert_eq!(grant["expiresAt"], Value::Null);
        assert_eq!(grant["canDelegate"], json!(true));
        assert_eq!(grant["provenance"], json!({"source": "engine.bootstrap"}));
        assert_eq!(grant["traceId"], json!("bootstrap"));
    }
}
