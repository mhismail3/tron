//! Artifacts presentation persistence tests.

use super::*;

#[test]
fn artifact_delivery_requires_the_reserved_output_property() {
    let mut candidate = bundle();
    candidate.client_deliveries = vec![WorkerClientDelivery::ArtifactDelivery];
    assert_eq!(
        validate_bundle(&candidate).unwrap_err(),
        "outputSchema must explicitly declare the reserved artifactDeliveries property when clientDeliveries contains artifact_delivery"
    );
}

#[test]
fn presentation_binding_is_immutable_indexed_and_reconstructed() {
    let temp = tempfile::tempdir().unwrap();
    let store = WorkerStore::open_without_snapshot(temp.path().to_path_buf()).unwrap();
    let mut candidate = bundle();
    candidate.presentation = Some(WorkerPresentation {
        experience_id: "research-suite".to_owned(),
        contract_version: 1,
        suite_id: Some("research".to_owned()),
        component_role: Some("search".to_owned()),
        primary: false,
        sections: vec![
            serde_json::from_value(json!({
                "sectionId":"summary",
                "kind":"text",
                "title":"Summary",
                "valuePointer":"/summary"
            }))
            .unwrap(),
        ],
    });
    let mut prepared = store.prepare(candidate, None).unwrap();
    store.finalize(&mut prepared).unwrap();
    let version = prepared.version.clone();
    let outcome = store.publish(prepared).unwrap();
    assert_eq!(
        outcome
            .worker
            .presentation
            .as_ref()
            .unwrap()
            .suite_id
            .as_deref(),
        Some("research")
    );
    assert_eq!(
        store
            .load_version("recent-research", &version)
            .unwrap()
            .bundle
            .presentation
            .as_ref()
            .unwrap()
            .component_role
            .as_deref(),
        Some("search")
    );
    assert_eq!(
        store
            .load_version("recent-research", &version)
            .unwrap()
            .bundle
            .presentation
            .as_ref()
            .unwrap()
            .sections[0]
            .value_pointer
            .as_deref(),
        Some("/summary")
    );

    store
        .connection()
        .unwrap()
        .execute("UPDATE workers SET presentation_json=NULL", [])
        .unwrap();
    super::super::super::rebuild::rebuild_indexes(&store.root, &store.database).unwrap();
    assert_eq!(
        store
            .summary("recent-research")
            .unwrap()
            .unwrap()
            .presentation
            .as_ref()
            .unwrap()
            .experience_id,
        "research-suite"
    );
    assert_eq!(
        store
            .summary("recent-research")
            .unwrap()
            .unwrap()
            .presentation
            .as_ref()
            .unwrap()
            .sections
            .len(),
        1
    );
}

#[test]
fn declarative_presentation_is_bounded_result_bound_and_schema_validated() {
    let mut candidate = bundle();
    candidate.input_schema = json!({
        "type":"object",
        "additionalProperties":false,
        "required":["action"],
        "properties":{"action":{"type":"string","enum":["refresh","approve"]}}
    });
    candidate.presentation = Some(
        serde_json::from_value(json!({
            "experienceId":"generic-workflow",
            "contractVersion":1,
            "sections":[
                {"sectionId":"summary","kind":"text","title":"Summary","valuePointer":"/summary"},
                {"sectionId":"state","kind":"status","valuePointer":"/status"},
                {"sectionId":"completion","kind":"progress","valuePointer":"/progress"},
                {
                    "sectionId":"records","kind":"table","title":"Records","valuePointer":"/records",
                    "columns":[
                        {"label":"Name","valuePointer":"/name"},
                        {"label":"State","valuePointer":"/status"}
                    ]
                },
                {"sectionId":"notes","kind":"list","valuePointer":"/notes"},
                {"sectionId":"source","kind":"link","label":"Open source","url":"https://example.com/source"},
                {"sectionId":"artifact","kind":"artifact","label":"Inspect report","valuePointer":"/report"},
                {
                    "sectionId":"approve","kind":"confirmation","title":"Approve result",
                    "detail":"Run the immutable approval action?",
                    "action":{"actionId":"approve","label":"Approve","input":{"action":"approve"}}
                },
                {
                    "sectionId":"refresh","kind":"worker_action",
                    "action":{"actionId":"refresh","label":"Refresh","input":{"action":"refresh"}}
                }
            ]
        }))
        .unwrap(),
    );
    validate_bundle(&candidate).expect("closed presentation is valid");

    let mut unsafe_link = candidate.clone();
    unsafe_link
        .presentation
        .as_mut()
        .unwrap()
        .sections
        .iter_mut()
        .find(|section| section.section_id == "source")
        .unwrap()
        .url = Some("javascript:alert(1)".to_owned());
    assert!(
        validate_bundle(&unsafe_link)
            .unwrap_err()
            .contains("absolute public HTTPS URL")
    );
    unsafe_link
        .presentation
        .as_mut()
        .unwrap()
        .sections
        .iter_mut()
        .find(|section| section.section_id == "source")
        .unwrap()
        .url = Some("https://127.0.0.1/private".to_owned());
    assert!(
        validate_bundle(&unsafe_link)
            .unwrap_err()
            .contains("absolute public HTTPS URL")
    );

    let mut invalid_pointer = candidate.clone();
    invalid_pointer.presentation.as_mut().unwrap().sections[0].value_pointer =
        Some("/bad~2pointer".to_owned());
    assert!(
        validate_bundle(&invalid_pointer)
            .unwrap_err()
            .contains("invalid RFC 6901 escape")
    );

    let mut invalid_action = candidate;
    invalid_action
        .presentation
        .as_mut()
        .unwrap()
        .sections
        .last_mut()
        .unwrap()
        .action
        .as_mut()
        .unwrap()
        .input = json!({"action":"delete-device"});
    assert!(
        validate_bundle(&invalid_action)
            .unwrap_err()
            .contains("does not match inputSchema")
    );
}

#[test]
fn declarative_presentation_struct_rejects_arbitrary_native_code_fields() {
    for field in ["html", "javascript", "swiftView", "clientCommand"] {
        let mut value = json!({
            "experienceId":"generic-workflow",
            "contractVersion":1,
            "sections":[
                {"sectionId":"summary","kind":"text","valuePointer":"/summary"}
            ]
        });
        value["sections"][0][field] = json!("unsafe");
        let error = serde_json::from_value::<WorkerPresentation>(value).unwrap_err();
        assert!(error.to_string().contains("unknown field"), "{error}");
    }
}

#[test]
fn artifact_custody_is_atomic_content_addressed_and_explicitly_deleted() {
    use crate::domains::worker_kernel::artifacts::artifact_intents_for_bundle;

    let temp = tempfile::tempdir().unwrap();
    let store = WorkerStore::open_without_snapshot(temp.path().to_path_buf()).unwrap();
    let mut candidate = bundle();
    candidate.worker_id = Some("document-artifact".to_owned());
    candidate.name = "Document Artifact".to_owned();
    candidate.client_deliveries = vec![WorkerClientDelivery::ArtifactDelivery];
    candidate.output_schema = json!({
        "type":"object",
        "additionalProperties":false,
        "required":["document","artifactDeliveries"],
        "properties":{
            "document":{
                "type":"object","required":["data"],
                "properties":{"data":{"type":"string"}}
            },
            "artifactDeliveries":{"type":"array"}
        }
    });
    let mut prepared = store.prepare(candidate, None).unwrap();
    store.finalize(&mut prepared).unwrap();
    let published = store.publish(prepared).unwrap();

    let (run, replayed) = store
        .begin_invocation(
            &published.worker.worker_id,
            &published.version,
            &json!({"title":"Report"}),
            "artifact-run-one",
            "trace-artifact-one",
            0,
            "manual",
            Some("session-artifact"),
        )
        .unwrap();
    assert!(!replayed);
    assert!(store.claim_running(&run.invocation_id).unwrap());
    let output = json!({
        "document":{"data":"aGVsbG8="},
        "artifactDeliveries":[{
            "artifactId":"report-1",
            "displayName":"report.md",
            "mediaType":"text/markdown",
            "sizeBytes":5,
            "contentReference":{
                "kind":"worker_result_reference",
                "invocationId":run.invocation_id,
                "pointer":"/document/data",
                "encoding":"base64"
            }
        }]
    });
    let active = store
        .load_version(&published.worker.worker_id, &published.version)
        .unwrap();
    let intents = artifact_intents_for_bundle(&active.bundle, &run.invocation_id, &output).unwrap();
    store
        .complete_invocation_with_effects(
            &run.invocation_id,
            &published.worker.worker_id,
            &output,
            &[],
            &intents,
            &[],
            None,
        )
        .unwrap();

    let inbox = store.artifact_deliveries(20, 0).unwrap();
    assert_eq!(inbox["returned"], 1);
    assert_eq!(inbox["artifacts"][0]["artifactId"], "report-1");
    assert_eq!(inbox["artifacts"][0]["traceId"], "trace-artifact-one");
    assert_eq!(
        inbox["artifacts"][0]["contentReference"]["kind"],
        "artifact_content_reference"
    );
    let content = store
        .artifact_content(&published.worker.worker_id, "report-1")
        .unwrap();
    assert_eq!(content["data"], "aGVsbG8=");
    assert_eq!(content["artifact"]["sizeBytes"], 5);

    let connection = store.connection().unwrap();
    assert_eq!(
        connection
            .query_row(
                "SELECT COUNT(*) FROM storage_payload_refs
                 WHERE owner_kind='worker_artifact'
                   AND retention_class='user_artifact'",
                [],
                |row| row.get::<_, i64>(0),
            )
            .unwrap(),
        1
    );
    let schema_version = connection
        .query_row("SELECT MAX(version) FROM worker_schema", [], |row| {
            row.get::<_, i64>(0)
        })
        .unwrap();
    assert!(schema_version >= 14);
    drop(connection);

    assert_eq!(
        store
            .delete_artifact(&published.worker.worker_id, "report-1")
            .unwrap()["deleted"],
        true
    );
    assert_eq!(
        store
            .delete_artifact(&published.worker.worker_id, "report-1")
            .unwrap()["deleted"],
        false
    );
    assert!(
        store.artifact_deliveries(20, 0).unwrap()["artifacts"]
            .as_array()
            .unwrap()
            .is_empty()
    );
    let connection = store.connection().unwrap();
    assert_eq!(
        connection
            .query_row(
                "SELECT COUNT(*) FROM storage_payload_refs
                 WHERE owner_kind='worker_artifact'",
                [],
                |row| row.get::<_, i64>(0),
            )
            .unwrap(),
        0
    );
}

#[test]
fn immutable_artifact_collision_rolls_back_invocation_completion() {
    use crate::domains::worker_kernel::artifacts::artifact_intents_for_bundle;

    let temp = tempfile::tempdir().unwrap();
    let store = WorkerStore::open_without_snapshot(temp.path().to_path_buf()).unwrap();
    let mut candidate = bundle();
    candidate.worker_id = Some("document-artifact".to_owned());
    candidate.client_deliveries = vec![WorkerClientDelivery::ArtifactDelivery];
    candidate.output_schema = json!({
        "type":"object",
        "properties":{
            "document":{"type":"object"},
            "artifactDeliveries":{"type":"array"}
        }
    });
    let mut prepared = store.prepare(candidate, None).unwrap();
    store.finalize(&mut prepared).unwrap();
    let published = store.publish(prepared).unwrap();
    let active = store
        .load_version(&published.worker.worker_id, &published.version)
        .unwrap();

    for (index, encoded) in ["b25l", "dHdv"].into_iter().enumerate() {
        let (run, _) = store
            .begin_invocation(
                &published.worker.worker_id,
                &published.version,
                &json!({}),
                &format!("artifact-collision-{index}"),
                &format!("trace-artifact-{index}"),
                0,
                "manual",
                None,
            )
            .unwrap();
        assert!(store.claim_running(&run.invocation_id).unwrap());
        let output = json!({
            "document":{"data":encoded},
            "artifactDeliveries":[{
                "artifactId":"stable-report",
                "displayName":"report.txt",
                "mediaType":"text/plain",
                "sizeBytes":3,
                "contentReference":{
                    "kind":"worker_result_reference",
                    "invocationId":run.invocation_id,
                    "pointer":"/document/data",
                    "encoding":"base64"
                }
            }]
        });
        let intents =
            artifact_intents_for_bundle(&active.bundle, &run.invocation_id, &output).unwrap();
        let result = store.complete_invocation_with_effects(
            &run.invocation_id,
            &published.worker.worker_id,
            &output,
            &[],
            &intents,
            &[],
            None,
        );
        if index == 0 {
            result.unwrap();
        } else {
            assert!(
                result
                    .unwrap_err()
                    .contains("immutable and already names different content")
            );
            assert_eq!(
                store
                    .invocation(&run.invocation_id)
                    .unwrap()
                    .unwrap()
                    .status,
                "running"
            );
        }
    }
    assert_eq!(store.artifact_deliveries(20, 0).unwrap()["returned"], 1);
}

#[test]
fn artifact_storage_attention_is_transition_aware_and_resolvable() {
    let temp = tempfile::tempdir().unwrap();
    let store = WorkerStore::open_without_snapshot(temp.path().to_path_buf()).unwrap();
    let mut prepared = store.prepare(bundle(), None).unwrap();
    store.finalize(&mut prepared).unwrap();
    let published = store.publish(prepared).unwrap();
    let (run, _) = store
        .begin_invocation(
            &published.worker.worker_id,
            &published.version,
            &json!({}),
            "artifact-pressure-source",
            "trace-artifact-pressure",
            0,
            "manual",
            None,
        )
        .unwrap();
    let created_at = chrono::Utc::now().to_rfc3339();

    let mut connection = store.connection().unwrap();
    let transaction = connection.transaction().unwrap();
    super::artifacts::reconcile_artifact_storage_attention_with_budget(
        &transaction,
        &run.invocation_id,
        &published.worker.worker_id,
        &created_at,
        1,
    )
    .unwrap();
    super::artifacts::reconcile_artifact_storage_attention_with_budget(
        &transaction,
        &run.invocation_id,
        &published.worker.worker_id,
        &created_at,
        1,
    )
    .unwrap();
    transaction.commit().unwrap();

    let attention = store
        .inbox_filtered_page(None, None, None, true, 20, 0)
        .unwrap();
    assert_eq!(attention.len(), 1);
    assert_eq!(
        attention[0]["result"]["status"],
        "artifact_storage_pressure"
    );

    let mut connection = store.connection().unwrap();
    let transaction = connection.transaction().unwrap();
    super::artifacts::reconcile_artifact_storage_attention_with_budget(
        &transaction,
        &run.invocation_id,
        &published.worker.worker_id,
        &chrono::Utc::now().to_rfc3339(),
        u64::MAX,
    )
    .unwrap();
    transaction.commit().unwrap();
    assert!(
        store
            .inbox_filtered_page(None, None, None, true, 20, 0)
            .unwrap()
            .is_empty()
    );
    assert_eq!(
        store
            .connection()
            .unwrap()
            .query_row(
                "SELECT COUNT(*) FROM worker_inbox
                 WHERE json_extract(result_json,'$.status')='artifact_storage_pressure'",
                [],
                |row| row.get::<_, i64>(0),
            )
            .unwrap(),
        1,
        "resolved attention remains immutable audit evidence"
    );
}
