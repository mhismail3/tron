use super::*;

#[tokio::test]
async fn compact_invocation_projection_omits_only_the_echoed_input() {
    let (runtime, _home) = test_runtime(None);
    let outcome = runtime
        .upsert(
            command_bundle(vec!["sh".to_owned(), "-c".to_owned(), "cat".to_owned()]),
            None,
        )
        .await
        .unwrap();
    let record = runtime
        .invoke(request(
            &outcome.worker.worker_id,
            json!({"largePayload":"x".repeat(32_768)}),
            "compact-invocation-projection",
        ))
        .await
        .unwrap();

    let full = runtime
        .provider_invocation_record(record.clone(), false)
        .unwrap();
    let compact = runtime.provider_invocation_record(record, true).unwrap();

    assert_eq!(
        full["input"]["largePayload"].as_str().unwrap().len(),
        32_768
    );
    assert!(compact.get("input").is_none());
    assert_eq!(compact["status"], "completed");
    assert_eq!(compact["output"]["kind"], "worker_result_reference");
}

#[tokio::test]
async fn large_results_stay_exact_and_cross_provider_turns_by_reference() {
    let home = tempfile::tempdir().unwrap();
    let workspace = tempfile::tempdir().unwrap();
    let runtime = test_runtime_at(home.path(), None);
    let mut bundle = command_bundle(vec![
        "python3".to_owned(),
        "-c".to_owned(),
        "import json; print(json.dumps({'summary':'large durable result','items':['x'*10000]}))"
            .to_owned(),
    ]);
    bundle.worker_id = Some("large-result".to_owned());
    bundle.output_schema = json!({
        "type":"object",
        "additionalProperties":false,
        "required":["summary","items"],
        "properties":{
            "summary":{"type":"string"},
            "items":{"type":"array","items":{"type":"string"}}
        }
    });
    runtime.upsert(bundle, None).await.unwrap();

    let direct = runtime
        .host
        .invoke(Invocation::new_sync(
            FunctionId::new("worker_kernel::dynamic_large-result").unwrap(),
            json!({}),
            CausalContext::new(
                ActorId::new("agent:large-result").unwrap(),
                ActorKind::Agent,
                TraceId::new("trace-large-result").unwrap(),
            )
            .with_session_id("session-large-result")
            .with_idempotency_key("large-result-direct"),
        ))
        .await;
    assert!(direct.error.is_none(), "direct error: {:?}", direct.error);
    let reference = direct.value.unwrap();
    assert_eq!(reference["kind"], "worker_result_reference");
    assert_eq!(reference["workerId"], "large-result");
    assert!(reference["sizeBytes"].as_u64().unwrap() > 8_192);
    let invocation_id = reference["invocationId"].as_str().unwrap();
    let durable = runtime.store().invocation(invocation_id).unwrap().unwrap();
    assert_eq!(
        durable.output.as_ref().unwrap()["items"][0],
        "x".repeat(10_000)
    );

    let read = runtime
        .host
        .invoke(Invocation::new_sync(
            FunctionId::new("worker_kernel::result_read").unwrap(),
            json!({"invocationId":invocation_id,"pointer":"/items","limit":1}),
            CausalContext::new(
                ActorId::new("agent:large-result-reader").unwrap(),
                ActorKind::Agent,
                TraceId::new("trace-large-result-reader").unwrap(),
            )
            .with_session_id("session-large-result"),
        ))
        .await;
    assert!(read.error.is_none(), "result read error: {:?}", read.error);
    let chunk = read.value.unwrap();
    assert_eq!(chunk["kind"], "worker_result_chunk");
    assert_eq!(chunk["value"][0], "x".repeat(10_000));
    assert_eq!(chunk["truncated"], false);

    let denied = runtime
        .host
        .invoke(Invocation::new_sync(
            FunctionId::new("worker_kernel::result_read").unwrap(),
            json!({"invocationId":invocation_id}),
            CausalContext::new(
                ActorId::new("agent:unrelated-result-reader").unwrap(),
                ActorKind::Agent,
                TraceId::new("trace-unrelated-result-reader").unwrap(),
            )
            .with_session_id("session-unrelated"),
        ))
        .await;
    assert!(denied.error.is_some());

    for (actor_id, actor_kind) in [
        ("client:paired-operator", ActorKind::Client),
        ("system:result-recovery", ActorKind::System),
    ] {
        let inspection = runtime
            .host
            .invoke(Invocation::new_sync(
                FunctionId::new("worker_kernel::result_read").unwrap(),
                json!({"invocationId":invocation_id,"pointer":"/summary"}),
                CausalContext::new(
                    ActorId::new(actor_id).unwrap(),
                    actor_kind,
                    TraceId::generate(),
                ),
            ))
            .await;
        assert!(
            inspection.error.is_none(),
            "{actor_id} inspection error: {:?}",
            inspection.error
        );
        assert_eq!(
            inspection.value.unwrap()["value"],
            "large durable result",
            "{actor_id} must read the exact bounded result"
        );
    }

    let handoff = runtime
        .host
        .invoke(Invocation::new_sync(
            FunctionId::new("worker_kernel::result_handoff").unwrap(),
            json!({
                "invocationId":invocation_id,
                "workingDirectory":workspace.path(),
                "model":"gpt-5.6-sol",
                "title":"Investigate large result"
            }),
            CausalContext::new(
                ActorId::new("client:result-handoff").unwrap(),
                ActorKind::Client,
                TraceId::new("trace-result-handoff").unwrap(),
            )
            .with_idempotency_key("result-handoff-one"),
        ))
        .await;
    assert!(
        handoff.error.is_none(),
        "handoff error: {:?}",
        handoff.error
    );
    let handoff = handoff.value.unwrap();
    let handoff_session_id = handoff["sessionId"].as_str().unwrap();
    assert_eq!(
        handoff["workingDirectory"],
        workspace
            .path()
            .canonicalize()
            .unwrap()
            .display()
            .to_string()
    );
    assert!(
        runtime
            .event_store
            .session_has_agent_result_grant(handoff_session_id, invocation_id)
            .unwrap()
    );

    let granted = runtime
        .host
        .invoke(Invocation::new_sync(
            FunctionId::new("worker_kernel::result_read").unwrap(),
            json!({"invocationId":invocation_id,"pointer":"/summary"}),
            CausalContext::new(
                ActorId::new("agent:result-handoff-reader").unwrap(),
                ActorKind::Agent,
                TraceId::new("trace-result-handoff-reader").unwrap(),
            )
            .with_session_id(handoff_session_id),
        ))
        .await;
    assert!(
        granted.error.is_none(),
        "granted read error: {:?}",
        granted.error
    );
    assert_eq!(granted.value.unwrap()["value"], "large durable result");

    let denied_handoff = runtime
        .host
        .invoke(Invocation::new_sync(
            FunctionId::new("worker_kernel::result_handoff").unwrap(),
            json!({
                "invocationId":invocation_id,
                "workingDirectory":workspace.path(),
                "model":"gpt-5.6-sol",
                "title":"Unauthorized handoff"
            }),
            CausalContext::new(
                ActorId::new("agent:result-handoff").unwrap(),
                ActorKind::Agent,
                TraceId::new("trace-result-handoff-denied").unwrap(),
            )
            .with_idempotency_key("result-handoff-denied"),
        ))
        .await;
    assert!(denied_handoff.error.is_some());

    let fixed = runtime
        .host
        .invoke(Invocation::new_sync(
            FunctionId::new("worker_kernel::invoke").unwrap(),
            json!({
                "workerId":"large-result",
                "input":{},
                "mode":"wait",
                "idempotencyKey":"large-result-fixed"
            }),
            CausalContext::new(
                ActorId::new("agent:large-result-fixed").unwrap(),
                ActorKind::Agent,
                TraceId::new("trace-large-result-fixed").unwrap(),
            )
            .with_session_id("session-large-result")
            .with_idempotency_key("large-result-fixed-outer"),
        ))
        .await;
    assert!(
        fixed.error.is_none(),
        "fixed invoke error: {:?}",
        fixed.error
    );
    assert_eq!(
        fixed.value.as_ref().unwrap()["output"]["kind"],
        "worker_result_reference"
    );

    drop(runtime);
    let restarted = test_runtime_at(home.path(), None);
    restarted.register_active_tools().await.unwrap();
    let after_restart = restarted
        .host
        .invoke(Invocation::new_sync(
            FunctionId::new("worker_kernel::result_read").unwrap(),
            json!({"invocationId":invocation_id,"pointer":"/summary"}),
            CausalContext::new(
                ActorId::new("agent:large-result-restart").unwrap(),
                ActorKind::Agent,
                TraceId::new("trace-large-result-restart").unwrap(),
            )
            .with_session_id("session-large-result"),
        ))
        .await;
    assert!(
        after_restart.error.is_none(),
        "restart result read error: {:?}",
        after_restart.error
    );
    assert_eq!(
        after_restart.value.unwrap()["value"],
        "large durable result"
    );
}

#[tokio::test]
async fn downstream_workers_accept_causal_references_with_explicit_paths_only() {
    let (runtime, _home) = test_runtime(None);
    let mut evidence = command_bundle(vec![
        "python3".to_owned(),
        "-c".to_owned(),
        "import json; print(json.dumps({'sources':[{'id':'S1','evidence':[{'id':'S1-E1','text':'bounded'}]}],'privateBulk':'x'*10000}))"
            .to_owned(),
    ]);
    evidence.worker_id = Some("evidence-owner".to_owned());
    evidence.name = "Evidence Owner".to_owned();
    evidence.description = "Produces a durable evidence corpus with unrelated bulk data".to_owned();
    evidence.tool_name = Some("worker_evidence_owner".to_owned());
    evidence.output_schema = json!({
        "type":"object",
        "additionalProperties":false,
        "required":["sources","privateBulk"],
        "properties":{
            "sources":{"type":"array"},
            "privateBulk":{"type":"string"}
        }
    });
    runtime.upsert(evidence, None).await.unwrap();

    let mut selector = command_bundle(vec![
        "python3".to_owned(),
        "-c".to_owned(),
        "import json,sys; value=json.load(sys.stdin); print(json.dumps({'accepted':len(value['selection']['sources']),'padding':'y'*10000}))"
            .to_owned(),
    ]);
    selector.worker_id = Some("evidence-selector".to_owned());
    selector.name = "Evidence Selector".to_owned();
    selector.description =
        "Accepts only an integrity reference and explicit bounded evidence pointers".to_owned();
    selector.tool_name = Some("worker_evidence_selector".to_owned());
    selector.input_schema = json!({
        "type":"object",
        "additionalProperties":false,
        "required":["selection"],
        "properties":{
            "selection":{
                "type":"object",
                "additionalProperties":false,
                "required":["reference","sources"],
                "properties":{
                    "reference":{
                        "type":"object",
                        "additionalProperties":true,
                        "required":["kind","invocationId","contentSha256"],
                        "properties":{
                            "kind":{"const":"worker_result_reference"},
                            "invocationId":{"type":"string"},
                            "contentSha256":{"type":"string"}
                        }
                    },
                    "sources":{
                        "type":"array",
                        "minItems":1,
                        "maxItems":10,
                        "uniqueItems":true,
                        "items":{
                            "type":"object",
                            "additionalProperties":false,
                            "required":["sourceId","pointer"],
                            "properties":{
                                "sourceId":{"type":"string"},
                                "pointer":{"type":"string","pattern":"^/sources/(0|[1-9][0-9]*)$"}
                            }
                        }
                    }
                }
            }
        }
    });
    selector.output_schema = json!({
        "type":"object",
        "additionalProperties":false,
        "required":["accepted","padding"],
        "properties":{
            "accepted":{"type":"integer"},
            "padding":{"type":"string"}
        }
    });
    runtime.upsert(selector, None).await.unwrap();

    let causal_context = CausalContext::new(
        ActorId::new("agent:reference-composition").unwrap(),
        ActorKind::Agent,
        TraceId::new("trace-reference-composition").unwrap(),
    )
    .with_session_id("session-reference-composition");
    let upstream = runtime
        .host
        .invoke(Invocation::new_sync(
            FunctionId::new("worker_kernel::dynamic_evidence-owner").unwrap(),
            json!({}),
            causal_context
                .clone()
                .with_idempotency_key("reference-composition-upstream"),
        ))
        .await;
    assert!(upstream.error.is_none(), "{:?}", upstream.error);
    let reference = upstream.value.unwrap();
    assert_eq!(reference["kind"], "worker_result_reference");
    assert!(reference["sizeBytes"].as_u64().unwrap() > 8_192);
    let invocation_id = reference["invocationId"].as_str().unwrap();

    let selected = runtime
        .host
        .invoke(Invocation::new_sync(
            FunctionId::new("worker_kernel::result_read").unwrap(),
            json!({"invocationId":invocation_id,"pointer":"/sources/0"}),
            causal_context
                .clone()
                .with_idempotency_key("reference-composition-read"),
        ))
        .await;
    assert!(selected.error.is_none(), "{:?}", selected.error);
    let selected = selected.value.unwrap();
    assert_eq!(selected["value"]["id"], "S1");
    assert_eq!(selected["truncated"], false);
    assert!(
        !selected.to_string().contains("privateBulk"),
        "a selected path must not hydrate an unrelated result field"
    );

    let selector_input = json!({
        "selection":{
            "reference":reference,
            "sources":[{"sourceId":"S1","pointer":"/sources/0"}]
        }
    });
    let downstream = runtime
        .host
        .invoke(Invocation::new_sync(
            FunctionId::new("worker_kernel::dynamic_evidence-selector").unwrap(),
            selector_input,
            causal_context
                .clone()
                .with_idempotency_key("reference-composition-downstream"),
        ))
        .await;
    assert!(downstream.error.is_none(), "{:?}", downstream.error);
    let downstream_reference = downstream.value.unwrap();
    assert_eq!(
        downstream_reference["kind"], "worker_result_reference",
        "large downstream output should expose its durable invocation identity"
    );
    let downstream_record = runtime
        .store()
        .invocation(
            downstream_reference["invocationId"]
                .as_str()
                .expect("downstream invocation id"),
        )
        .unwrap()
        .unwrap();
    assert_eq!(downstream_record.output.as_ref().unwrap()["accepted"], 1);
    assert_eq!(
        downstream_record.input["selection"]["reference"]["kind"],
        "worker_result_reference"
    );
    assert!(
        !downstream_record.input.to_string().contains("privateBulk"),
        "downstream durable input must contain the reference and pointers, not upstream bytes"
    );

    let root_pointer = runtime
        .host
        .invoke(Invocation::new_sync(
            FunctionId::new("worker_kernel::dynamic_evidence-selector").unwrap(),
            json!({
                "selection":{
                    "reference":downstream_record.input["selection"]["reference"],
                    "sources":[{"sourceId":"S1","pointer":""}]
                }
            }),
            causal_context
                .clone()
                .with_idempotency_key("reference-composition-root-rejected"),
        ))
        .await;
    assert!(root_pointer.error.is_some());
    let root_pointer_error = root_pointer.error.unwrap().to_string();
    assert!(
        root_pointer_error.contains("pattern")
            || root_pointer_error.contains("does not match")
            || root_pointer_error.contains("invalid"),
        "{root_pointer_error}"
    );

    let missing = runtime
        .host
        .invoke(Invocation::new_sync(
            FunctionId::new("worker_kernel::result_read").unwrap(),
            json!({"invocationId":invocation_id,"pointer":"/sources/99"}),
            causal_context.with_idempotency_key("reference-composition-missing"),
        ))
        .await;
    assert!(missing.error.is_some());
    assert!(
        missing
            .error
            .unwrap()
            .to_string()
            .contains("does not exist")
    );
}

#[tokio::test]
async fn selected_worker_input_contract_classifies_schema_violations() {
    let (runtime, _home) = test_runtime(None);
    let mut bundle = command_bundle(vec![
        "python3".to_owned(),
        "-c".to_owned(),
        "import json,sys; print(json.dumps(json.load(sys.stdin)))".to_owned(),
    ]);
    bundle.worker_id = Some("typed-admission".to_owned());
    bundle.input_schema = json!({
        "type":"object",
        "additionalProperties":false,
        "required":["task"],
        "properties":{"task":{"type":"string","minLength":1}}
    });
    runtime.upsert(bundle, None).await.unwrap();

    runtime
        .validate_active_input_contract("typed-admission", &json!({"task":"inspect"}))
        .unwrap();
    let error = runtime
        .validate_active_input_contract("typed-admission", &json!({}))
        .expect_err("missing typed worker field must fail before dispatch");
    assert!(matches!(&error, WorkerInputContractError::Invalid(_)));
    assert!(
        error
            .to_string()
            .contains("$.task: required field is missing")
    );
}

#[tokio::test]
async fn worker_owned_state_survives_update_rollback_disable_and_retirement() {
    let (runtime, home) = test_runtime(None);
    let state_script = r#"import json,os,pathlib
root=pathlib.Path(os.environ['TRON_WORKER_STATE_DIR'])
root.mkdir(parents=True,exist_ok=True)
counter=root/'counter.txt'
value=int(counter.read_text())+1 if counter.exists() else 1
counter.write_text(str(value))
print(json.dumps({'count':value,'stateDir':str(root)}))
"#;
    let mut bundle = command_bundle(vec![
        "python3".to_owned(),
        "-c".to_owned(),
        state_script.to_owned(),
    ]);
    bundle.worker_id = Some("stateful-counter".to_owned());
    bundle.name = "Stateful Counter".to_owned();
    bundle.output_schema = json!({
        "type":"object","additionalProperties":false,"required":["count","stateDir"],
        "properties":{"count":{"type":"integer"},"stateDir":{"type":"string"}}
    });
    bundle.smoke_tests = vec![WorkerCommand {
        command: vec![
            "python3".to_owned(),
            "-c".to_owned(),
            "import json,os,pathlib; pathlib.Path(os.environ['TRON_WORKER_STATE_DIR'],'smoke.txt').write_text('isolated'); print(json.dumps({'ok':True}))".to_owned(),
        ],
        timeout_seconds: 5,
    }];

    let first = runtime.upsert(bundle.clone(), None).await.unwrap();
    let durable = home.path().join("workspace/worker-state/stateful-counter");
    assert!(!durable.join("smoke.txt").exists());
    let first_run = runtime
        .invoke(request("stateful-counter", json!({}), "state-1"))
        .await
        .unwrap();
    assert_eq!(first_run.output.as_ref().unwrap()["count"], 1);
    assert_eq!(
        first_run.output.as_ref().unwrap()["stateDir"],
        durable.display().to_string()
    );

    bundle.description = "Updated stateful counter contract".to_owned();
    bundle.provenance[0].revision = Some("2".to_owned());
    let second = runtime
        .upsert(bundle, Some("stateful-counter"))
        .await
        .unwrap();
    assert_ne!(first.version, second.version);
    let second_run = runtime
        .invoke(request("stateful-counter", json!({}), "state-2"))
        .await
        .unwrap();
    assert_eq!(second_run.output.as_ref().unwrap()["count"], 2);

    runtime
        .rollback("stateful-counter", &first.version)
        .await
        .unwrap();
    let third_run = runtime
        .invoke(request("stateful-counter", json!({}), "state-3"))
        .await
        .unwrap();
    assert_eq!(third_run.output.as_ref().unwrap()["count"], 3);
    runtime
        .set_enabled("stateful-counter", false)
        .await
        .unwrap();
    assert_eq!(
        std::fs::read_to_string(durable.join("counter.txt")).unwrap(),
        "3"
    );
    runtime.set_enabled("stateful-counter", true).await.unwrap();
    runtime.retire("stateful-counter").await.unwrap();
    assert_eq!(
        std::fs::read_to_string(durable.join("counter.txt")).unwrap(),
        "3"
    );
}

#[tokio::test]
async fn provider_api_keys_resolve_through_declared_runtime_bindings() {
    let (runtime, home) = test_runtime(None);
    let auth_path = crate::shared::foundation::paths::auth_path_for_home(home.path());
    let secret = "brave-provider-secret";
    crate::domains::auth::credentials::save_named_api_key(&auth_path, "brave", "Default", secret)
        .unwrap();

    let mut bundle = command_bundle(vec![
        "sh".to_owned(),
        "-c".to_owned(),
        "printf '{\"value\":\"%s\"}' \"$TRON_SECRET_PROVIDER_BRAVE\"".to_owned(),
    ]);
    bundle.secret_bindings = vec![
        super::super::super::types::WorkerSecretBinding::Configured {
            name: "provider-brave".to_owned(),
            required: true,
        },
    ];

    let outcome = runtime.upsert(bundle, None).await.unwrap();
    let result = runtime
        .invoke(request(
            &outcome.worker.worker_id,
            json!({}),
            "provider-secret",
        ))
        .await
        .unwrap();
    assert_eq!(result.output, Some(json!({"value":"[REDACTED]"})));
    assert!(
        !serde_json::to_string(&runtime.store().runs_filtered(None, None, 10).unwrap())
            .unwrap()
            .contains(secret)
    );
}

#[tokio::test]
async fn secret_values_are_injected_then_redacted_from_durable_results() {
    let (captured_logs, _log_guard) = crate::shared::observability::capture_logs();
    let (runtime, home) = test_runtime(None);
    let vault = home.path().join("workspace/vault");
    std::fs::create_dir_all(&vault).unwrap();
    let secret = "top-secret-test-value";
    let undeclared_secret = "another-vault-only-secret";
    std::fs::write(vault.join("api-key"), secret).unwrap();
    std::fs::write(vault.join("other-key"), undeclared_secret).unwrap();
    let mut bundle = command_bundle(vec![
        "sh".to_owned(),
        "-c".to_owned(),
        "printf '{\"value\":\"%s\"}' \"$TRON_SECRET_API_KEY\"".to_owned(),
    ]);
    bundle.secret_bindings = vec![super::super::super::types::WorkerSecretBinding::Optional(
        "api-key".to_owned(),
    )];
    let outcome = runtime.upsert(bundle.clone(), None).await.unwrap();
    let result = runtime
        .invoke(request(&outcome.worker.worker_id, json!({}), "secret"))
        .await
        .unwrap();
    assert_eq!(
        result.output,
        Some(json!({"value":"[REDACTED]"})),
        "secret worker result: {result:?}"
    );
    let diagnostics = format!(
        "{}{}",
        serde_json::to_string(&runtime.store().runs_filtered(None, None, 10).unwrap()).unwrap(),
        serde_json::to_string(
            &runtime
                .store()
                .inbox_filtered(None, None, None, 10)
                .unwrap(),
        )
        .unwrap()
    );
    assert!(!diagnostics.contains(secret));
    assert!(
        runtime
            .invoke(request(
                &outcome.worker.worker_id,
                json!({"copiedSecret":secret}),
                "secret-in-input",
            ))
            .await
            .unwrap_err()
            .contains("only through declared logical bindings")
    );
    assert_eq!(
        runtime.store().runs_filtered(None, None, 10).unwrap().len(),
        1
    );

    let mut failing = bundle.clone();
    failing
        .description
        .push_str(" with failure redaction evidence");
    failing.runner = WorkerRunner::Command {
        command: vec![
            "sh".to_owned(),
            "-c".to_owned(),
            "printf '%s' \"$TRON_SECRET_API_KEY\" >&2; exit 17".to_owned(),
        ],
    };
    let failed_version = runtime
        .upsert(failing, Some(&outcome.worker.worker_id))
        .await
        .unwrap();
    let failed = runtime
        .invoke(request(
            &outcome.worker.worker_id,
            json!({}),
            "secret-error",
        ))
        .await
        .unwrap();
    assert_eq!(failed.status, "failed");
    assert!(
        failed
            .error
            .as_deref()
            .is_some_and(|error| error.contains("[REDACTED]") && !error.contains(secret))
    );
    let events = runtime
        .host
        .poll_stream_topic(
            "worker.invocations",
            StreamCursor(0),
            100,
            &StreamActorScope::all(),
        )
        .await
        .unwrap();
    let operational_evidence = format!(
        "{}{}{}{}{:?}",
        serde_json::to_string(&runtime.store().inspect(&outcome.worker.worker_id).unwrap())
            .unwrap(),
        serde_json::to_string(&runtime.store().runs_filtered(None, None, 100).unwrap()).unwrap(),
        serde_json::to_string(
            &runtime
                .store()
                .inbox_filtered(None, None, None, 100)
                .unwrap(),
        )
        .unwrap(),
        serde_json::to_string(&events).unwrap(),
        captured_logs.events(),
    );
    assert!(!operational_evidence.contains(secret));
    for entry in walkdir::WalkDir::new(
        home.path()
            .join("workspace/workers")
            .join(&outcome.worker.worker_id),
    )
    .follow_links(false)
    {
        let entry = entry.unwrap();
        if entry.file_type().is_file() {
            let bytes = std::fs::read(entry.path()).unwrap();
            assert!(
                !bytes
                    .windows(secret.len())
                    .any(|window| window == secret.as_bytes()),
                "secret leaked into {}",
                entry.path().display()
            );
        }
    }
    assert_eq!(
        failed_version.worker.active_version, failed.worker_version,
        "redaction failure must still be pinned to the activated version"
    );

    bundle
        .files
        .insert("leak.txt".to_owned(), secret.to_owned());
    assert!(
        runtime
            .upsert(bundle, None)
            .await
            .unwrap_err()
            .contains("contains the value")
    );

    let mut undeclared_leak =
        command_bundle(vec!["sh".to_owned(), "-c".to_owned(), "cat".to_owned()]);
    undeclared_leak
        .files
        .insert("undeclared.txt".to_owned(), undeclared_secret.to_owned());
    assert!(
        runtime
            .upsert(undeclared_leak, None)
            .await
            .unwrap_err()
            .contains("other-key")
    );
}

#[tokio::test]
async fn command_timeout_is_bounded_and_kills_the_child() {
    let temporary = tempfile::tempdir().unwrap();
    let started = std::time::Instant::now();
    let error = run_worker_command(
        &WorkerCommand {
            command: vec!["sh".to_owned(), "-c".to_owned(), "sleep 5".to_owned()],
            timeout_seconds: 1,
        },
        temporary.path(),
        None,
        None,
        &HashMap::new(),
        None,
    )
    .await
    .unwrap_err();
    assert!(error.contains("timed out"));
    assert!(started.elapsed() < Duration::from_secs(3));
}

#[tokio::test]
async fn successful_command_may_ignore_typed_input_without_a_broken_pipe_failure() {
    let temporary = tempfile::tempdir().unwrap();
    let output = run_worker_command(
        &WorkerCommand {
            command: vec![
                "sh".to_owned(),
                "-c".to_owned(),
                "printf '{\"accepted\":true}'".to_owned(),
            ],
            timeout_seconds: 5,
        },
        temporary.path(),
        None,
        Some(&json!({"payload":"x".repeat(2_000_000)})),
        &HashMap::new(),
        None,
    )
    .await
    .unwrap();

    assert_eq!(output, json!({"accepted":true}));
}

#[tokio::test]
async fn worker_command_rejects_oversized_stdout_after_draining_the_child() {
    let temporary = tempfile::tempdir().unwrap();
    let started = std::time::Instant::now();
    let error = run_worker_command(
        &WorkerCommand {
            command: vec![
                "python3".to_owned(),
                "-c".to_owned(),
                format!(
                    "import sys; sys.stdout.write('x'*{})",
                    MAX_PROCESS_CAPTURE_BYTES + 1
                ),
            ],
            timeout_seconds: 5,
        },
        temporary.path(),
        None,
        None,
        &HashMap::new(),
        None,
    )
    .await
    .unwrap_err();

    assert!(error.contains("capture ceiling"), "{error}");
    assert!(started.elapsed() < Duration::from_secs(3));
}
