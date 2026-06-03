use super::*;
use std::collections::BTreeSet;

#[tokio::test]
async fn observability_trace_get_explains_full_client_agent_worker_ui_graph() {
    let handle = EngineHostHandle::new_in_memory().unwrap();
    register_trace_spawn_handler(&handle);

    let trace_id = "hmh-f6-full-graph";
    let session_id = "hmh-f6-session";
    let workspace_id = "hmh-f6-workspace";
    let root_client = client_trace_context(trace_id)
        .with_scope("worker.write")
        .with_session_id(session_id)
        .with_workspace_id(workspace_id);

    let spawned = handle
        .invoke(host_invocation(
            "engine::invoke",
            json!({
                "functionId": "worker::spawn",
                "payload": {
                    "workerId": "hmh-f6-worker",
                    "expectedFunctionIds": ["hmh_f6::write_artifact"]
                },
                "idempotencyKey": "hmh-f6-spawn"
            }),
            root_client,
        ))
        .await;
    assert_eq!(spawned.error, None);
    assert_eq!(
        spawned.value.as_ref().unwrap()["child"]["functionId"],
        "worker::spawn"
    );
    assert_eq!(
        spawned.value.as_ref().unwrap()["child"]["error"],
        Value::Null
    );

    let agent_parent = spawned.invocation_id.clone();
    let agent_context = |scope: &str, key: &str| {
        CausalContext::new(
            actor("agent"),
            ActorKind::Agent,
            grant("grant"),
            trace(trace_id),
        )
        .with_parent_invocation(agent_parent.clone())
        .with_session_id(session_id)
        .with_workspace_id(workspace_id)
        .with_scope(scope)
        .with_idempotency_key(key)
    };

    let artifact = handle
        .invoke(host_invocation(
            "artifact::create",
            json!({
                "resourceId": "hmh-f6-artifact",
                "scope": "session",
                "sessionId": session_id,
                "payload": {
                    "title": "HMH-F6 artifact",
                    "body": {"status": "created through trace proof"}
                }
            }),
            agent_context("resource.write", "hmh-f6-artifact-create"),
        ))
        .await;
    assert_eq!(artifact.error, None);

    let approval = handle
        .invoke(host_invocation(
            "approval::request",
            json!({
                "functionId": "hmh_f6::write_artifact",
                "payload": {"message": "needs review"}
            }),
            agent_context("approval.request", "hmh-f6-approval"),
        ))
        .await;
    assert_eq!(approval.error, None);

    let queued = handle
        .invoke(host_invocation(
            "queue::enqueue",
            json!({
                "queue": "default",
                "functionId": "hmh_f6::write_artifact",
                "payload": {"message": "queued"}
            }),
            agent_context("queue.write", "hmh-f6-queue"),
        ))
        .await;
    assert_eq!(queued.error, None);
    let receipt_id = queued.value.as_ref().unwrap()["item"]["receiptId"]
        .as_str()
        .unwrap()
        .to_owned();

    let surface = handle
        .invoke(host_invocation(
            "ui::create_surface",
            json!({
                "resourceId": "hmh-f6-ui",
                "surface": valid_ui_surface("hmh_f6::write_artifact", 1)
            }),
            agent_context("ui.write", "hmh-f6-ui-create"),
        ))
        .await;
    assert_eq!(surface.error, None);
    let surface_version = surface.value.as_ref().unwrap()["resourceRefs"][0]["versionId"]
        .as_str()
        .unwrap()
        .to_owned();

    let submitted = handle
        .invoke(host_invocation(
            "ui::submit_action",
            json!({
                "surfaceResourceId": "hmh-f6-ui",
                "surfaceVersionId": surface_version,
                "actionId": "submit-test",
                "userInput": {"message": "from generated ui"},
                "idempotencyKey": "hmh-f6-ui-submit-child"
            }),
            agent_context("ui.write", "hmh-f6-ui-submit"),
        ))
        .await;
    assert_eq!(submitted.error, None);

    let trace = handle
        .invoke(host_invocation(
            "observability::trace_get",
            json!({"traceId": trace_id, "includeFullPayloads": true}),
            causal().with_scope("observability.read"),
        ))
        .await;
    assert_eq!(trace.error, None);
    let value = trace.value.as_ref().unwrap();

    let functions = trace_function_ids(value);
    for expected in [
        "engine::invoke",
        "worker::spawn",
        "artifact::create",
        "approval::request",
        "queue::enqueue",
        "ui::create_surface",
        "ui::submit_action",
        "hmh_f6::write_artifact",
    ] {
        assert!(
            functions.contains(expected),
            "trace_get must include invocation function {expected}, got {functions:?}"
        );
    }
    assert_trace_invocation_parent(value, "worker::spawn", spawned.invocation_id.as_str());
    assert_trace_invocation_parent(
        value,
        "hmh_f6::write_artifact",
        submitted.invocation_id.as_str(),
    );

    let catalog_changes = value["catalogChanges"].as_array().unwrap();
    assert!(
        catalog_changes.iter().any(|change| {
            change["kind"] == "worker_registered" && change["subjectId"] == "hmh-f6-worker"
        }),
        "trace_get must correlate spawned worker catalog registration by durable worker id"
    );
    assert!(
        catalog_changes.iter().any(|change| {
            change["kind"] == "function_registered"
                && change["subjectId"] == "hmh_f6::write_artifact"
        }),
        "trace_get must correlate spawned function catalog registration by durable function id"
    );

    assert!(
        value["approvals"].as_array().unwrap().iter().any(|record| {
            record["functionId"] == "hmh_f6::write_artifact" && record["status"] == "pending"
        }),
        "trace_get must include approval records for the trace"
    );
    assert!(
        value["queueItems"].as_array().unwrap().iter().any(|item| {
            item["receiptId"] == receipt_id && item["functionId"] == "hmh_f6::write_artifact"
        }),
        "trace_get must include queue receipts for the trace"
    );
    assert!(
        value["resourceEvents"]
            .as_array()
            .unwrap()
            .iter()
            .any(|event| {
                event["resourceId"] == "hmh-f6-artifact" && event["eventType"] == "resource.created"
            }),
        "trace_get must include resource events for the trace"
    );
    assert!(
        value["streams"].as_array().unwrap().iter().any(|event| {
            event["topic"] == "queue.lifecycle" && event["payload"]["receiptId"] == receipt_id
        }),
        "trace_get must include queue lifecycle stream events for the trace"
    );
    assert!(
        value["leases"]
            .as_array()
            .unwrap()
            .iter()
            .any(|lease| lease["functionId"] == "ui::submit_action"),
        "trace_get must include generated UI action leases"
    );
    assert!(
        value["compensation"]
            .as_array()
            .unwrap()
            .iter()
            .any(|record| {
                record["functionId"] == "ui::submit_action" && record["succeeded"] == true
            }),
        "trace_get must include generated UI action compensation records"
    );
}

#[derive(Clone)]
struct TraceSpawnHandler {
    handle: EngineHostHandle,
}

#[async_trait]
impl InProcessFunctionHandler for TraceSpawnHandler {
    async fn invoke(&self, invocation: Invocation) -> Result<Value> {
        let worker_id = invocation.payload["workerId"]
            .as_str()
            .ok_or_else(|| EngineError::PolicyViolation("workerId required".to_owned()))?;
        let expected = invocation.payload["expectedFunctionIds"]
            .as_array()
            .ok_or_else(|| EngineError::PolicyViolation("expectedFunctionIds required".to_owned()))?
            .iter()
            .map(|value| {
                value.as_str().map(ToOwned::to_owned).ok_or_else(|| {
                    EngineError::PolicyViolation("expectedFunctionIds must be strings".to_owned())
                })
            })
            .collect::<Result<Vec<_>>>()?;
        let namespace = expected
            .first()
            .and_then(|function_id| function_id.split_once("::").map(|(namespace, _)| namespace))
            .ok_or_else(|| {
                EngineError::PolicyViolation(
                    "expectedFunctionIds must contain namespaced ids".to_owned(),
                )
            })?;
        let mut worker_definition = worker(worker_id, namespace);
        worker_definition.visibility = VisibilityScope::Session;
        worker_definition.provenance =
            Provenance::new(invocation.causal_context.actor_id.clone(), "worker::spawn")
                .with_session_id(
                    invocation
                        .causal_context
                        .session_id
                        .clone()
                        .unwrap_or_else(|| "hmh-f6-session".to_owned()),
                )
                .with_workspace_id(
                    invocation
                        .causal_context
                        .workspace_id
                        .clone()
                        .unwrap_or_else(|| "hmh-f6-workspace".to_owned()),
                );
        self.handle.register_worker(worker_definition, true).await?;
        for function_id in &expected {
            let mut function = write_function(function_id, worker_id)
                .with_required_authority(AuthorityRequirement::scope(format!("{namespace}.write")))
                .with_request_schema(json!({
                    "type": "object",
                    "additionalProperties": false,
                    "required": ["message"],
                    "properties": {
                        "message": {"type": "string"},
                        "sourceSurface": {"type": "string"}
                    }
                }))
                .with_output_contract(DurableOutputContract::resource_backed(["artifact"]));
            function.visibility = VisibilityScope::Session;
            function.provenance =
                Provenance::new(invocation.causal_context.actor_id.clone(), "worker::spawn")
                    .with_session_id(
                        invocation
                            .causal_context
                            .session_id
                            .clone()
                            .unwrap_or_else(|| "hmh-f6-session".to_owned()),
                    )
                    .with_workspace_id(
                        invocation
                            .causal_context
                            .workspace_id
                            .clone()
                            .unwrap_or_else(|| "hmh-f6-workspace".to_owned()),
                    );
            self.handle
                .register_function(function, Some(Arc::new(TraceWriteArtifactHandler)), true)
                .await?;
        }
        Ok(json!({
            "workerId": worker_id,
            "registeredFunctionIds": expected,
        }))
    }
}

#[derive(Clone)]
struct TraceWriteArtifactHandler;

#[async_trait]
impl InProcessFunctionHandler for TraceWriteArtifactHandler {
    async fn invoke(&self, invocation: Invocation) -> Result<Value> {
        Ok(json!({
            "message": invocation.payload["message"],
            "resourceRefs": [{
                "resourceId": "hmh-f6-artifact",
                "kind": "artifact",
                "versionId": "hmh-f6-version",
                "role": "updated",
                "contentHash": "sha256:hmh-f6-artifact"
            }]
        }))
    }
}

fn register_trace_spawn_handler(handle: &EngineHostHandle) {
    let mut spawn_function = write_function("worker::spawn", "worker")
        .with_required_authority(AuthorityRequirement::scope("worker.write"));
    spawn_function.visibility = VisibilityScope::System;
    handle
        .register_function_for_setup(
            spawn_function,
            Some(Arc::new(TraceSpawnHandler {
                handle: handle.clone(),
            })),
            false,
        )
        .unwrap();
}

fn client_trace_context(trace_id: &str) -> CausalContext {
    CausalContext::new(
        actor("engine-client"),
        ActorKind::Client,
        grant("engine-transport"),
        trace(trace_id),
    )
}

fn trace_function_ids(value: &Value) -> BTreeSet<String> {
    value["invocations"]
        .as_array()
        .unwrap()
        .iter()
        .filter_map(|record| record["functionId"].as_str().map(ToOwned::to_owned))
        .collect()
}

fn assert_trace_invocation_parent(value: &Value, function_id: &str, parent_id: &str) {
    assert!(
        value["invocations"]
            .as_array()
            .unwrap()
            .iter()
            .any(|record| {
                record["functionId"] == function_id && record["parentInvocationId"] == parent_id
            }),
        "trace_get must expose {function_id} as a child of {parent_id}"
    );
}
