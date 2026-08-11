//! End-to-end reusable-agent role-review workflow tests.

use super::*;

fn role_review_invocation(operation: &str, key: &str, payload: Value) -> Invocation {
    Invocation::new_sync(
        FunctionId::new(format!("worker_kernel::{operation}")).unwrap(),
        payload,
        CausalContext::new(
            ActorId::new("client:role-review-test").unwrap(),
            ActorKind::Client,
            TraceId::new(format!("trace-{key}")).unwrap(),
        )
        .with_idempotency_key(key),
    )
}

fn reviewer_bundle(worker_id: &str) -> WorkerBundle {
    let output = json!({
        "agentRole":{"status":"disabled"},
        "rationale":"This runner should remain available only through direct typed invocation."
    });
    let mut bundle = command_bundle(vec![
        "sh".to_owned(),
        "-c".to_owned(),
        format!("printf '%s' '{}'", serde_json::to_string(&output).unwrap()),
    ]);
    bundle.worker_id = Some(worker_id.to_owned());
    bundle.name = "Dynamic role declaration reviewer".to_owned();
    bundle.description = "Proposes bounded reusable-agent role declarations".to_owned();
    bundle.tool_name = Some(format!("worker_{worker_id}"));
    bundle.input_schema = json!({
        "type":"object","additionalProperties":false,
        "required":["action","target","agentRoleSchema","delegableTools"],
        "properties":{
            "action":{"const":"agent_role_review"},
            "target":{"type":"object"},
            "agentRoleSchema":{"type":"object"},
            "delegableTools":{"type":"array","maxItems":256,"items":{"type":"object"}}
        }
    });
    bundle.output_schema = json!({
        "type":"object","additionalProperties":false,
        "required":["agentRole","rationale"],
        "properties":{
            "agentRole":super::super::super::contract::agent_role_authoring_schema(),
            "rationale":{"type":"string","minLength":1,"maxLength":2000}
        }
    });
    bundle.engine_hooks = vec![WorkerEngineHook::AgentRoleReview];
    bundle
}

fn legacy_agent_bundle(worker_id: &str) -> WorkerBundle {
    let mut bundle = command_bundle(Vec::new());
    bundle.worker_id = Some(worker_id.to_owned());
    bundle.name = format!("Legacy agent {worker_id}");
    bundle.description = "Completes one bounded delegated task".to_owned();
    bundle.tool_name = Some(format!("worker_{worker_id}"));
    bundle.runner = WorkerRunner::Agent {
        instructions: "Complete the delegated task and return bounded evidence.".to_owned(),
        model: None,
        reasoning_level: None,
    };
    bundle
}

#[tokio::test]
async fn dynamic_reviewer_proposal_is_durable_and_apply_changes_only_agent_role() {
    let (runtime, _home) = test_runtime(None);
    let reviewer = runtime
        .upsert(reviewer_bundle("arbitrary-healthy-reviewer"), None)
        .await
        .unwrap();
    let target = runtime
        .upsert(legacy_agent_bundle("legacy-role-target"), None)
        .await
        .unwrap();
    let original = runtime
        .store()
        .load_version(&target.worker.worker_id, &target.version)
        .unwrap()
        .bundle;

    let proposal_response = runtime
        .host
        .invoke(role_review_invocation(
            "role_review_start",
            "role-review-start",
            json!({"workerId":target.worker.worker_id}),
        ))
        .await;
    assert_eq!(proposal_response.error, None);
    let proposal = proposal_response.value.unwrap();
    assert_eq!(proposal["status"], "proposed");
    assert_eq!(proposal["reviewerWorkerId"], reviewer.worker.worker_id);
    assert_eq!(proposal["reviewerWorkerVersion"], reviewer.version);
    let reviewer_invocation_id = proposal["reviewerInvocationId"].as_str().unwrap();
    let reviewer_run = runtime
        .store()
        .invocation(reviewer_invocation_id)
        .unwrap()
        .unwrap();
    assert_eq!(reviewer_run.worker_id, reviewer.worker.worker_id);
    assert_eq!(reviewer_run.worker_version, reviewer.version);
    assert_eq!(reviewer_run.trigger_kind, "engine_hook:agent_role_review");
    assert_eq!(reviewer_run.status, "completed");

    let proposal_id = proposal["proposalId"].as_str().unwrap();
    let inspected = runtime
        .host
        .invoke(role_review_invocation(
            "role_review_inspect",
            "role-review-inspect",
            json!({"proposalId":proposal_id}),
        ))
        .await
        .value
        .unwrap();
    assert_eq!(inspected["proposalHash"], proposal["proposalHash"]);
    let unconfirmed = runtime
        .host
        .invoke(role_review_invocation(
            "role_review_apply",
            "role-review-unconfirmed",
            json!({"proposalId":proposal_id,"confirmed":false}),
        ))
        .await;
    assert!(unconfirmed.value.is_none());
    assert!(unconfirmed.error.is_some());
    let applied_response = runtime
        .host
        .invoke(role_review_invocation(
            "role_review_apply",
            "role-review-apply",
            json!({"proposalId":proposal_id,"confirmed":true}),
        ))
        .await;
    assert_eq!(applied_response.error, None);
    let applied = applied_response.value.unwrap();
    assert_eq!(applied["proposal"]["status"], "applied");
    assert_ne!(applied["proposal"]["publishedVersion"], target.version);
    let replayed_apply = runtime
        .host
        .invoke(role_review_invocation(
            "role_review_apply",
            "role-review-apply-observe",
            json!({"proposalId":proposal_id,"confirmed":true}),
        ))
        .await;
    assert_eq!(replayed_apply.error, None);
    assert_eq!(
        replayed_apply.value.unwrap()["proposal"]["publishedVersion"],
        applied["proposal"]["publishedVersion"]
    );

    let mut published = runtime
        .store()
        .load_active(&target.worker.worker_id)
        .unwrap()
        .bundle;
    assert_eq!(published.agent_role, Some(WorkerAgentRole::Disabled));
    published.agent_role = None;
    assert_eq!(
        serde_json::to_value(published).unwrap(),
        serde_json::to_value(original).unwrap(),
        "canonical publication must clone the exact target bundle and change only agentRole"
    );

    let rejected_target = runtime
        .upsert(legacy_agent_bundle("legacy-role-rejected"), None)
        .await
        .unwrap();
    let rejected_proposal = runtime
        .host
        .invoke(role_review_invocation(
            "role_review_start",
            "role-review-start-rejected",
            json!({"workerId":rejected_target.worker.worker_id}),
        ))
        .await
        .value
        .unwrap();
    let rejected = runtime
        .host
        .invoke(role_review_invocation(
            "role_review_reject",
            "role-review-reject",
            json!({
                "proposalId":rejected_proposal["proposalId"],
                "reason":"Keep this runner direct-only without publishing a declaration yet."
            }),
        ))
        .await;
    assert_eq!(rejected.error, None);
    assert_eq!(rejected.value.unwrap()["status"], "rejected");
}

#[tokio::test]
async fn missing_reviewer_is_truthful_and_candidate_queue_pages_past_one_hundred() {
    let (runtime, _home) = test_runtime(None);
    for index in 0..102 {
        runtime
            .upsert(
                legacy_agent_bundle(&format!("legacy-page-{index:03}")),
                None,
            )
            .await
            .unwrap();
    }

    let first_response = runtime
        .host
        .invoke(role_review_invocation(
            "role_reviews",
            "role-review-list-first",
            json!({"limit":1,"offset":0,"queueLimit":2,"queueOffset":0}),
        ))
        .await;
    assert_eq!(first_response.error, None);
    let first = first_response.value.unwrap();
    assert_eq!(first["reviewer"]["available"], false);
    assert!(
        first["reviewer"]["repairRequirement"]
            .as_str()
            .unwrap()
            .contains("healthy active worker")
    );
    assert_eq!(first["queueTotal"], 102);
    assert_eq!(first["queueReturned"], 2);
    assert_eq!(first["queueNextOffset"], 2);

    let tail_response = runtime
        .host
        .invoke(role_review_invocation(
            "role_reviews",
            "role-review-list-tail",
            json!({"limit":1,"offset":0,"queueLimit":2,"queueOffset":100}),
        ))
        .await;
    assert_eq!(tail_response.error, None);
    let tail = tail_response.value.unwrap();
    assert_eq!(tail["items"].as_array().unwrap().len(), 2);
    assert_eq!(tail["items"][0]["workerId"], "legacy-page-100");
    assert_eq!(tail["items"][1]["workerId"], "legacy-page-101");
    assert_eq!(tail["queueNextOffset"], Value::Null);

    let response = runtime
        .host
        .invoke(role_review_invocation(
            "role_review_start",
            "missing-reviewer",
            json!({"workerId":"legacy-page-101"}),
        ))
        .await;
    let error = response.error.expect("missing reviewer must be truthful");
    assert!(
        error.to_string().contains("No healthy active worker"),
        "{error:?}"
    );
}
