use super::support::*;

#[tokio::test]
async fn harness_docs_are_versioned_resources() {
    let engine_host = crate::engine::EngineHostHandle::new_in_memory().expect("engine host");
    let session_id = "session-hmh-c4";
    let workspace_id = "workspace-hmh-c4";
    let policy = CapabilityContextPrimerPolicy {
        enabled: true,
        mode: "coreFirstParty".to_owned(),
        max_tokens: 2600,
        include_examples: true,
        include_compact_schemas: true,
    };
    let catalog_revision = engine_host.catalog_revision().await.0;

    let primer = render_capability_primer(&engine_host, session_id, Some(workspace_id), &policy)
        .await
        .expect("render primer")
        .expect("primer");

    assert!(primer.contains("Harness docs resource:"), "{primer}");
    assert!(primer.contains("resource::inspect"), "{primer}");
    let resource_id = primer_field(&primer, "resourceId").expect("resource id");
    let version_id = primer_field(&primer, "versionId").expect("version id");

    let inspected = engine_host
        .invoke(crate::engine::Invocation::new_sync(
            crate::engine::FunctionId::new("resource::inspect").expect("function id"),
            json!({"resourceId": resource_id}),
            crate::engine::CausalContext::new(
                crate::engine::ActorId::new("system:hmh-c4").expect("actor id"),
                crate::engine::ActorKind::System,
                crate::engine::AuthorityGrantId::new("engine-system").expect("grant id"),
                crate::engine::TraceId::new("trace:hmh-c4-inspect").expect("trace id"),
            )
            .with_scope("resource.read")
            .with_session_id(session_id)
            .with_workspace_id(workspace_id),
        ))
        .await;
    assert_eq!(inspected.error, None);
    let inspection = inspected
        .value
        .as_ref()
        .and_then(|value| value.get("inspection"))
        .expect("inspection");
    assert_eq!(inspection["resource"]["kind"], json!("harness_doc"));
    assert_eq!(
        inspection["resource"]["currentVersionId"],
        json!(version_id)
    );

    let current_version = inspection["versions"]
        .as_array()
        .expect("versions")
        .iter()
        .find(|version| version["versionId"] == json!(version_id))
        .expect("current version");
    let payload = &current_version["payload"];
    assert_eq!(payload["docId"], json!("capability-primer"));
    assert_eq!(payload["catalogRevision"], json!(catalog_revision));
    assert_eq!(payload["policy"]["mode"], json!("coreFirstParty"));
    assert_eq!(payload["metadata"]["sessionId"], json!(session_id));
    assert_eq!(payload["metadata"]["workspaceId"], json!(workspace_id));
    assert!(
        payload["body"]
            .as_str()
            .expect("body")
            .contains("To customize the harness"),
        "{payload}"
    );
    assert!(
        payload["body"]
            .as_str()
            .expect("body")
            .contains("worker::spawn"),
        "{payload}"
    );
}

fn primer_field(text: &str, field: &str) -> Option<String> {
    let prefix = format!("{field}=");
    text.lines()
        .find(|line| line.contains("Harness docs resource:"))
        .and_then(|line| {
            line.split_whitespace()
                .find_map(|part| part.strip_prefix(&prefix))
        })
        .map(|value| value.trim_matches('`').trim_matches('.').to_owned())
}
