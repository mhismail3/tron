use super::*;

mod tprod_i_flagship_closeout;

#[cfg(unix)]
struct TprodIFlagshipProvider {
    scenario: Mutex<Option<TprodIFlagshipScenario>>,
    call_count: AtomicU64,
    final_answer: Mutex<Option<String>>,
}

#[cfg(unix)]
#[derive(Clone, Debug)]
struct TprodIFlagshipScenario {
    session_id: String,
    workspace_id: String,
    workspace_path: String,
    autonomy_grant_id: String,
    script_path: String,
    working_directory: String,
    namespace: String,
    worker_id: String,
    function_id: String,
}

#[cfg(unix)]
impl TprodIFlagshipProvider {
    fn new() -> Self {
        Self {
            scenario: Mutex::new(None),
            call_count: AtomicU64::new(0),
            final_answer: Mutex::new(None),
        }
    }

    fn set_scenario(&self, scenario: TprodIFlagshipScenario) {
        *self.scenario.lock().unwrap() = Some(scenario);
    }

    fn final_answer(&self) -> Option<String> {
        self.final_answer.lock().unwrap().clone()
    }
}

#[cfg(unix)]
fn is_tprod_i_review_subagent_turn(context: &ModelContext) -> bool {
    const REVIEW_TASK: &str =
        "Review TPROD-I helper capability evidence and summarize review readiness.";
    tprod_i_user_context_contains(context, REVIEW_TASK)
}

#[cfg(unix)]
fn is_tprod_i_title_hook_turn(context: &ModelContext) -> bool {
    tprod_i_user_context_contains(context, "Generate a 3-5 word title")
}

#[cfg(unix)]
fn is_tprod_i_suggestion_hook_turn(context: &ModelContext) -> bool {
    tprod_i_user_context_contains(context, "generate 3-5 short follow-up prompts")
}

#[cfg(unix)]
fn tprod_i_user_context_contains(context: &ModelContext, expected: &str) -> bool {
    context.messages.iter().any(|message| match message {
        ModelMessage::User { content, .. } => format!("{content:?}").contains(expected),
        _ => false,
    })
}

#[cfg(unix)]
#[async_trait]
impl Provider for TprodIFlagshipProvider {
    fn provider_type(&self) -> ProviderKind {
        ProviderKind::Anthropic
    }

    fn model(&self) -> &'static str {
        "mock"
    }

    async fn stream(
        &self,
        context: &ModelContext,
        _options: &ProviderStreamOptions,
    ) -> Result<StreamEventStream, ProviderError> {
        let scenario = self
            .scenario
            .lock()
            .unwrap()
            .clone()
            .expect("TPROD-I scenario configured before prompting");
        if is_tprod_i_title_hook_turn(context) {
            return Ok(text_stream("Maintaining Tron helper"));
        }
        if is_tprod_i_suggestion_hook_turn(context) {
            return Ok(text_stream(
                "Review helper evidence\nInspect generated UI\nCheck scorecard status",
            ));
        }
        if is_tprod_i_review_subagent_turn(context) {
            return Ok(text_stream(
                "TPROD-I review subagent: helper evidence is review-ready. Task profile Review used Local when possible routing and should disclose hosted route when local execution is unavailable.",
            ));
        }
        let call = self.call_count.fetch_add(1, Ordering::SeqCst);
        match call {
            0 => Ok(execute_call_stream(
                "tprod-i-guide",
                execute_payload(
                    &scenario,
                    "worker::protocol_guide",
                    json!({
                        "language": "python",
                        "workerId": scenario.worker_id,
                        "functionId": scenario.function_id,
                    }),
                    "tprod-i-guide",
                    "Use self-extend live worker protocol guide before authoring the Tron helper.",
                ),
            )),
            1 => {
                assert!(
                    flagship_outputs(context).iter().any(|output| {
                        output["functionDefinitionShape"]["readOnlyEchoMinimum"]["id"]
                            == scenario.function_id
                            && output["pythonTemplate"].is_string()
                    }),
                    "guide output missing before draft write: {}",
                    hmh_context_text(context)
                );
                Ok(execute_call_stream(
                    "tprod-i-draft-source",
                    execute_payload(
                        &scenario,
                        "materialized_file::update",
                        json!({
                            "path": scenario.script_path,
                            "content": "def intentionally_broken_tprod_i_helper(:\n    pass\n",
                            "scope": "workspace",
                            "sessionId": scenario.session_id,
                            "workspaceId": scenario.workspace_id,
                        }),
                        "tprod-i-draft-source",
                        "Write the intentionally broken first draft so repair history is durable.",
                    ),
                ))
            }
            2 => {
                let repaired = repaired_worker_source(context, &scenario);
                Ok(execute_call_stream(
                    "tprod-i-repair-source",
                    execute_payload(
                        &scenario,
                        "materialized_file::update",
                        json!({
                            "path": scenario.script_path,
                            "content": repaired,
                            "scope": "workspace",
                            "sessionId": scenario.session_id,
                            "workspaceId": scenario.workspace_id,
                        }),
                        "tprod-i-repair-source",
                        "Repair the helper source from the live protocol guide.",
                    ),
                ))
            }
            3 => {
                let resource_id = latest_materialized_resource_id(context);
                Ok(execute_call_stream(
                    "tprod-i-inspect-source-history",
                    execute_payload(
                        &scenario,
                        "materialized_file::inspect",
                        json!({
                            "resourceId": resource_id,
                        }),
                        "tprod-i-inspect-source-history",
                        "Inspect the helper source repair version history before spawning.",
                    ),
                ))
            }
            4 => Ok(execute_call_stream(
                "tprod-i-spawn-helper",
                execute_payload(
                    &scenario,
                    "worker::spawn",
                    json!({
                        "workerId": scenario.worker_id,
                        "command": "python3",
                        "args": [scenario.script_path],
                        "workingDirectory": scenario.working_directory,
                        "expectedFunctionIds": [scenario.function_id],
                        "allowedAuthorityScopes": [format!("{}.read", scenario.namespace)],
                        "allowedResourceKinds": ["evidence"],
                        "fileRoots": [scenario.working_directory],
                        "workspaceAutonomyGrantId": scenario.autonomy_grant_id,
                        "networkPolicy": "loopback",
                        "maxRisk": "low",
                        "approvalRequired": false,
                        "visibility": "workspace",
                        "sessionId": scenario.session_id,
                        "workspaceId": scenario.workspace_id,
                        "timeoutMs": 10000,
                    }),
                    "tprod-i-spawn-helper",
                    "Create the workspace-visible Tron maintainer helper capability.",
                ),
            )),
            5 => {
                let spawn = spawn_output(context, &scenario);
                let after_revision = spawn["catalogRevision"]
                    .as_u64()
                    .expect("spawn returns catalog revision")
                    .saturating_sub(1);
                Ok(execute_call_stream(
                    "tprod-i-watch-helper",
                    execute_payload(
                        &scenario,
                        "catalog::watch_snapshot",
                        json!({
                            "afterRevision": after_revision,
                            "limit": 10,
                            "classes": ["availability"],
                            "kinds": ["function_registered"],
                            "ownerWorker": scenario.worker_id,
                        }),
                        "tprod-i-watch-helper",
                        "Wait for the helper function to appear as a healthy workspace-visible capability.",
                    ),
                ))
            }
            6 => Ok(execute_call_stream(
                "tprod-i-invoke-helper",
                execute_payload(
                    &scenario,
                    &scenario.function_id,
                    json!({
                        "message": "scorecard health summary",
                        "scorecard": "packages/agent/docs/tron-productization-scorecard.md",
                        "nonce": 9,
                    }),
                    "tprod-i-invoke-helper",
                    "Invoke the new helper through the normal execute portal.",
                ),
            )),
            7 => Ok(execute_call_stream(
                "tprod-i-inspect-helper",
                execute_payload(
                    &scenario,
                    "capability::inspect",
                    json!({"functionId": scenario.function_id}),
                    "tprod-i-inspect-helper",
                    "Inspect the live helper binding and implementation evidence.",
                ),
            )),
            8 => {
                let metadata = registered_function_metadata(context, &scenario);
                Ok(execute_call_stream(
                    "tprod-i-conformance",
                    execute_payload(
                        &scenario,
                        "capability::conformance_run",
                        json!({
                            "pluginId": metadata["pluginId"].as_str().expect("registered function metadata has plugin id"),
                            "implementationId": metadata["implementationId"].as_str().expect("registered function metadata has implementation id"),
                            "reason": "TPROD-I flagship Tron-maintains-Tron helper proof",
                        }),
                        "tprod-i-conformance",
                        "Run conformance before marking the helper review-ready.",
                    ),
                ))
            }
            9 => Ok(execute_call_stream(
                "tprod-i-generated-ui",
                execute_payload(
                    &scenario,
                    "ui::surface_for_target",
                    json!({
                        "targetType": "capability",
                        "targetId": scenario.function_id,
                        "purpose": "Review TPROD-I helper capability",
                        "layoutProfile": "compact",
                        "maxPreviewBytes": 512,
                        "scope": "workspace",
                        "sessionId": scenario.session_id,
                        "workspaceId": scenario.workspace_id,
                        "expiresAt": "2100-01-01T00:00:00Z",
                    }),
                    "tprod-i-generated-ui",
                    "Create generated UI evidence for the helper capability.",
                ),
            )),
            10 => Ok(execute_call_stream(
                "tprod-i-review-subagent",
                execute_payload(
                    &scenario,
                    "agent::spawn_subagent",
                    json!({
                        "task": "Review TPROD-I helper capability evidence and summarize review readiness.",
                        "workingDirectory": scenario.workspace_path,
                        "blockingTimeoutMs": 300000,
                        "modelPreset": "localWhenPossible",
                        "taskProfile": "review",
                        "maxTurns": 1,
                    }),
                    "tprod-i-review-subagent",
                    "Spawn a review subagent with explicit task/model routing evidence.",
                ),
            )),
            11 => {
                let answer = flagship_final_answer(context, &scenario);
                *self.final_answer.lock().unwrap() = Some(answer.clone());
                Ok(text_stream(&answer))
            }
            other => panic!("TPROD-I flagship provider called too many times: {other}"),
        }
    }
}

#[cfg(unix)]
#[test]
fn tprod_i_flagship_chat_loop_reaches_review_ready() {
    const STACK_BYTES: usize = 32 * 1024 * 1024;
    let handle = std::thread::Builder::new()
        .name("tprod-i-flagship-proof".to_owned())
        .stack_size(STACK_BYTES)
        .spawn(|| {
            let runtime = tokio::runtime::Builder::new_multi_thread()
                .worker_threads(2)
                .thread_stack_size(STACK_BYTES)
                .enable_all()
                .build()
                .expect("TPROD-I test runtime builds");
            runtime.block_on(tprod_i_flagship_chat_loop_reaches_review_ready_impl());
        })
        .expect("TPROD-I test thread starts");
    if let Err(payload) = handle.join() {
        std::panic::resume_unwind(payload);
    }
}

#[cfg(unix)]
async fn tprod_i_flagship_chat_loop_reaches_review_ready_impl() {
    let port = reserve_loopback_port();
    let provider = Arc::new(TprodIFlagshipProvider::new());
    let config = ServerConfig {
        host: "127.0.0.1".to_owned(),
        port,
        ..ServerConfig::default()
    };
    let (url, server, _handles) = boot_server_with_provider_config_and_handles(
        provider.clone(),
        config,
        format!("127.0.0.1:{port}"),
    )
    .await;
    let mut ws = connect(&url).await;
    let workspace = tempfile::tempdir().unwrap();
    let workspace_path = workspace.path().canonicalize().unwrap();
    let workspace_path_string = workspace_path.to_string_lossy().into_owned();
    let session = rpc_call(
        &mut ws,
        5101,
        "session::create",
        Some(json!({
            "model": "m",
            "title": "TPROD-I flagship local work loop",
            "workingDirectory": workspace_path_string.clone(),
        })),
    )
    .await;
    assert_eq!(session["success"], true, "session create failed: {session}");
    let session_id = session["result"]["sessionId"]
        .as_str()
        .expect("session id")
        .to_owned();
    let workspace_id = server
        .runtime_context()
        .event_store
        .get_workspace_by_path(&workspace_path_string)
        .expect("workspace lookup succeeds")
        .expect("session create stores workspace")
        .id;

    let autonomy = grant_workspace_autonomy_for_session_agent(
        &server,
        &session_id,
        &workspace_id,
        &workspace_path_string,
    )
    .await;
    assert_eq!(autonomy["status"], "approved");
    assert_eq!(autonomy["summary"], "Safe in this workspace");
    let autonomy_grant_id = autonomy["grantId"]
        .as_str()
        .expect("autonomy grant id")
        .to_owned();

    let namespace = "tprod_i_flagship".to_owned();
    let function_id = format!("{namespace}::review_ready");
    let worker_id = format!("tprod-i-flagship-worker-{port}");
    let script_path = workspace_path.join("tprod_i_flagship_helper.py");
    provider.set_scenario(TprodIFlagshipScenario {
        session_id: session_id.clone(),
        workspace_id: workspace_id.clone(),
        workspace_path: workspace_path_string.clone(),
        autonomy_grant_id: autonomy_grant_id.clone(),
        script_path: script_path.to_string_lossy().into_owned(),
        working_directory: workspace_path_string,
        namespace: namespace.clone(),
        worker_id: worker_id.clone(),
        function_id: function_id.clone(),
    });

    let (prompt, mut events) = rpc_call_with_interleaved_events(
        &mut ws,
        5103,
        "agent::prompt",
        Some(json!({
            "sessionId": session_id,
            "workspaceId": workspace_id,
            "prompt": "Use self-extend to create or update a local Tron maintainer helper, repair one intentional draft failure, test it, create generated UI, use a review subagent with model routing evidence, and stop at review-ready state without push, merge, release, or deploy."
        })),
    )
    .await;
    assert_eq!(prompt["success"], true, "agent prompt failed: {prompt}");
    events.extend(collect_events_until_type(&mut ws, "agent.ready", PROMPT_EVENT_TIMEOUT).await);
    tprod_i_flagship_closeout::assert_agent_ready(&provider, &events, &server, &session_id).await;
    wait_until_run_cleared(&server, &session_id).await;
    tprod_i_flagship_closeout::assert_no_waiting_approvals(&server, &session_id).await;
    tprod_i_flagship_closeout::assert_no_manual_approval_resolve_invocation(&server, &session_id)
        .await;

    let final_answer = provider
        .final_answer()
        .expect("provider produced final review-ready answer");
    for required in [
        "TPROD-I review-ready",
        autonomy_grant_id.as_str(),
        function_id.as_str(),
        worker_id.as_str(),
        "materialized_file",
        "ui_surface",
        "evidence:",
        "agent_result:subagent:",
        "Local when possible",
        "Review",
        "no push/merge/release/deploy",
    ] {
        assert!(
            final_answer.contains(required),
            "final answer missing `{required}`: {final_answer}"
        );
    }

    let event_text = serde_json::to_string(&events).expect("events serialize");
    for required in [
        "agent.subagent_spawned",
        "agent.subagent_completed",
        "taskProfile",
        "modelRouting",
        function_id.as_str(),
    ] {
        assert!(
            event_text.contains(required),
            "streamed event evidence missing `{required}`: {event_text}"
        );
    }

    let history = rpc_call(
        &mut ws,
        5105,
        "session::get_history",
        Some(json!({"sessionId": session_id})),
    )
    .await;
    assert_eq!(history["success"], true, "history failed: {history}");
    let history_text = history["result"]["messages"].to_string();
    for required in [
        "TPROD-I review-ready",
        function_id.as_str(),
        "ui_surface",
        "agent_result:subagent:",
        "no push/merge/release/deploy",
    ] {
        assert!(
            history_text.contains(required),
            "session history missing `{required}`: {history_text}"
        );
    }

    let work_snapshot = direct_engine_invoke_with_session(
        &server,
        "agent::work_snapshot",
        json!({"sessionId": session_id, "workspaceId": workspace_id, "limit": 50}),
        "jarvis-11-work-snapshot-before-cleanup",
        &["agent.read"],
        &session_id,
    )
    .await;
    assert_eq!(work_snapshot["autonomy"]["approvalPromptMode"], "disabled");
    assert_eq!(work_snapshot["activeWork"].as_array().unwrap().len(), 0);
    assert_eq!(work_snapshot["guardrails"].as_array().unwrap().len(), 0);
    assert!(
        work_snapshot["workers"]
            .as_array()
            .expect("work snapshot workers")
            .iter()
            .any(|worker| worker["workerId"] == worker_id),
        "Work snapshot must project the generated helper worker before cleanup: {work_snapshot}"
    );
    assert!(
        work_snapshot["recentMilestones"]
            .as_array()
            .expect("work snapshot milestones")
            .iter()
            .any(|milestone| milestone["functionId"] == function_id
                && milestone["status"] == "completed"),
        "Work snapshot must include the successful helper invocation milestone: {work_snapshot}"
    );
    let audit_refs = work_snapshot["auditRefs"]
        .as_array()
        .expect("work snapshot audit refs");
    assert!(
        audit_refs
            .iter()
            .any(|reference| reference["kind"] == "approval")
            && audit_refs
                .iter()
                .any(|reference| reference["kind"] == "invocation"),
        "Work snapshot must include approval and invocation audit refs: {work_snapshot}"
    );

    let stopped = direct_engine_invoke_with_session(
        &server,
        "sandbox::stop_spawned_worker",
        json!({
            "workerId": worker_id,
            "reason": "TPROD-I flagship proof cleanup",
            "sessionId": session_id,
            "workspaceId": workspace_id,
        }),
        "tprod-i-stop-helper",
        &["sandbox.write"],
        &session_id,
    )
    .await;
    assert_eq!(stopped["stopped"], true);
    tprod_i_flagship_closeout::assert_clean_state(&server, &session_id, &workspace_id, &worker_id)
        .await;

    server.shutdown().shutdown();
}

#[cfg(unix)]
async fn grant_workspace_autonomy_for_session_agent(
    server: &Arc<TronServer>,
    session_id: &str,
    workspace_id: &str,
    workspace_path: &str,
) -> Value {
    let mut context = CausalContext::new(
        ActorId::new(format!("agent:{session_id}")).expect("valid session agent actor"),
        ActorKind::Agent,
        AuthorityGrantId::new("engine-system").expect("valid engine grant"),
        TraceId::generate(),
    )
    .with_idempotency_key("tprod-i-workspace-autonomy".to_owned())
    .with_session_id(session_id.to_owned())
    .with_workspace_id(workspace_id.to_owned())
    .with_scope("self_extension.write");
    context.authority_scopes.push("grant.write".to_owned());
    let result = server
        .runtime_context()
        .engine_host
        .invoke(Invocation::new_sync(
            FunctionId::new("self_extension::grant_workspace_autonomy")
                .expect("valid self-extension grant function"),
            json!({
                "workspacePath": workspace_path,
                "sessionId": session_id,
                "reason": "TPROD-I flagship local helper creation proof"
            }),
            context,
        ))
        .await;
    if let Some(error) = result.error {
        panic!("self_extension::grant_workspace_autonomy failed: {error}");
    }
    result.value.unwrap_or(Value::Null)
}

#[cfg(unix)]
fn execute_payload(
    scenario: &TprodIFlagshipScenario,
    target: &str,
    arguments: Value,
    idempotency_key: &str,
    reason: &str,
) -> Value {
    json!({
        "sessionId": scenario.session_id,
        "workspaceId": scenario.workspace_id,
        "target": target,
        "arguments": arguments,
        "idempotencyKey": idempotency_key,
        "reason": reason,
    })
}

#[cfg(unix)]
fn execute_call_stream(invocation_id: &str, arguments: Value) -> StreamEventStream {
    let arguments = arguments
        .as_object()
        .cloned()
        .expect("execute tool arguments must be an object");
    let invocation = CapabilityInvocationDraft::new(invocation_id, "execute", arguments.clone());
    let events = vec![
        Ok(StreamEvent::Start),
        Ok(StreamEvent::CapabilityInvocationDraftStart {
            invocation_id: invocation.id.clone(),
            name: invocation.name.clone(),
        }),
        Ok(StreamEvent::CapabilityInvocationDraftEnd {
            capability_invocation: invocation.clone(),
        }),
        Ok(StreamEvent::Done {
            message: AssistantMessage {
                content: vec![AssistantContent::CapabilityInvocation {
                    id: invocation.id,
                    name: invocation.name,
                    arguments,
                    thought_signature: None,
                }],
                token_usage: Some(TokenUsage {
                    input_tokens: 30,
                    output_tokens: 12,
                    ..Default::default()
                }),
            },
            stop_reason: "capability_invocation".into(),
        }),
    ];
    Box::pin(stream::iter(events))
}

#[cfg(unix)]
fn text_stream(text: &str) -> StreamEventStream {
    let text = text.to_owned();
    let events = vec![
        Ok(StreamEvent::Start),
        Ok(StreamEvent::TextDelta {
            delta: text.clone(),
        }),
        Ok(StreamEvent::Done {
            message: AssistantMessage {
                content: vec![AssistantContent::text(&text)],
                token_usage: Some(TokenUsage {
                    input_tokens: 20,
                    output_tokens: 20,
                    ..Default::default()
                }),
            },
            stop_reason: "end_turn".into(),
        }),
    ];
    Box::pin(stream::iter(events))
}

#[cfg(unix)]
fn repaired_worker_source(context: &ModelContext, scenario: &TprodIFlagshipScenario) -> String {
    let guide = flagship_outputs(context)
        .into_iter()
        .find(|output| output["pythonTemplate"].is_string())
        .unwrap_or_else(|| panic!("missing guide output: {}", hmh_context_text(context)));
    let template = guide["pythonTemplate"]
        .as_str()
        .expect("guide has python template");
    format!(
        "{template}\n# TPROD-I repair: replaced the intentionally broken first draft for {function_id}.\n",
        function_id = scenario.function_id
    )
}

#[cfg(unix)]
fn latest_materialized_resource_id(context: &ModelContext) -> String {
    flagship_outputs(context)
        .into_iter()
        .rev()
        .find_map(|output| {
            output["resourceRefs"]
                .as_array()
                .and_then(|refs| {
                    refs.iter().find(|reference| {
                        reference["kind"] == "materialized_file"
                            && reference["role"].as_str().is_some()
                    })
                })
                .and_then(|reference| reference["resourceId"].as_str())
                .map(str::to_owned)
        })
        .unwrap_or_else(|| {
            panic!(
                "missing materialized file resource ref: {}",
                hmh_context_text(context)
            )
        })
}

#[cfg(unix)]
fn flagship_final_answer(context: &ModelContext, scenario: &TprodIFlagshipScenario) -> String {
    let outputs = flagship_outputs(context);
    let source_history = outputs
        .iter()
        .find(|output| output["inspection"]["resource"]["kind"] == "materialized_file")
        .unwrap_or_else(|| panic!("missing source history: {}", hmh_context_text(context)));
    let versions = source_history["inspection"]["versions"]
        .as_array()
        .expect("materialized file inspect returns versions");
    assert!(
        versions.len() >= 2,
        "source history must include broken draft and repaired version: {source_history}"
    );
    let spawn = spawn_output_from_outputs(&outputs, context, scenario);
    let invoked = outputs
        .iter()
        .find(|output| output["echo"]["nonce"] == json!(9))
        .unwrap_or_else(|| {
            panic!(
                "missing helper invocation output: {}",
                hmh_context_text(context)
            )
        });
    assert_eq!(
        invoked["echo"]["scorecard"],
        "packages/agent/docs/tron-productization-scorecard.md"
    );
    let metadata = registered_function_metadata_from_outputs(&outputs, context, scenario);
    assert!(
        inspect_guidance_text(context, scenario).contains("implemented by"),
        "capability inspect output must provide product guidance: {}",
        flagship_output_summary(context)
    );
    let conformance = outputs
        .iter()
        .find(|output| {
            output["state"] == "healthy"
                && output["resourceRefs"].as_array().is_some_and(|refs| {
                    refs.iter()
                        .any(|reference| reference["kind"].as_str() == Some("evidence"))
                })
        })
        .unwrap_or_else(|| panic!("missing conformance output: {}", hmh_context_text(context)));
    let evidence_ref = conformance["resourceRefs"]
        .as_array()
        .unwrap()
        .iter()
        .find(|reference| reference["kind"].as_str() == Some("evidence"))
        .expect("conformance evidence ref");
    let ui = outputs
        .iter()
        .find(|output| {
            output["surface"]["authoring"]["targetId"].as_str()
                == Some(scenario.function_id.as_str())
        })
        .unwrap_or_else(|| panic!("missing generated UI output: {}", hmh_context_text(context)));
    let ui_ref = ui["resourceRefs"]
        .as_array()
        .and_then(|refs| {
            refs.iter()
                .find(|reference| reference["kind"].as_str() == Some("ui_surface"))
        })
        .expect("ui surface ref");
    let subagent = outputs
        .iter()
        .find(|output| {
            output["modelRouting"].is_object() || output["handle"]["modelRouting"].is_object()
        })
        .unwrap_or_else(|| {
            panic!(
                "missing subagent routing output: {}",
                hmh_context_text(context)
            )
        });
    let routing = subagent
        .get("modelRouting")
        .or_else(|| subagent.pointer("/handle/modelRouting"))
        .expect("subagent routing present");
    let task_profile = subagent
        .get("taskProfile")
        .or_else(|| subagent.pointer("/handle/taskProfile"))
        .expect("subagent task profile present");
    let subagent_session_id = subagent
        .pointer("/handle/sessionId")
        .or_else(|| subagent.get("sessionId"))
        .and_then(Value::as_str)
        .expect("subagent session id");

    format!(
        "TPROD-I review-ready: workspace autonomy {grant_id} says Safe in this workspace; helper {function_id} on worker {worker_id} registered at catalog revision {catalog_revision}; source history materialized_file {source_resource}@{source_version} has {version_count} versions including the broken draft repair; invocation echoed scorecard nonce 9; conformance evidence:{evidence_resource}@{evidence_version} is healthy for plugin {plugin_id} implementation {implementation_id}; generated UI ui_surface {ui_resource}@{ui_version} targets the helper; review subagent agent_result:subagent:{subagent_session_id} used task profile {task_label} and model preset {preset_label} ({selected_model}, hostedRoute={hosted_route_used}); docs/evidence are ready for local review and there was no push/merge/release/deploy.",
        grant_id = scenario.autonomy_grant_id,
        function_id = scenario.function_id,
        worker_id = scenario.worker_id,
        catalog_revision = spawn["catalogRevision"],
        source_resource = source_history["inspection"]["resource"]["resourceId"],
        source_version = source_history["inspection"]["resource"]["currentVersionId"],
        version_count = versions.len(),
        evidence_resource = evidence_ref["resourceId"].as_str().unwrap_or("unknown"),
        evidence_version = evidence_ref["versionId"].as_str().unwrap_or("unknown"),
        plugin_id = metadata["pluginId"].as_str().unwrap_or("unknown"),
        implementation_id = metadata["implementationId"].as_str().unwrap_or("unknown"),
        ui_resource = ui_ref["resourceId"].as_str().unwrap_or("unknown"),
        ui_version = ui_ref["versionId"].as_str().unwrap_or("unknown"),
        subagent_session_id = subagent_session_id,
        task_label = task_profile["label"].as_str().unwrap_or("Review"),
        preset_label = routing["presetLabel"]
            .as_str()
            .unwrap_or("Local when possible"),
        selected_model = routing["selectedModel"].as_str().unwrap_or("pending"),
        hosted_route_used = routing["hostedRouteUsed"].as_bool().unwrap_or(false),
    )
}

#[cfg(unix)]
fn inspected_function_id(output: &Value) -> Option<&str> {
    output
        .pointer("/implementation/functionId")
        .or_else(|| output.pointer("/details/implementation/functionId"))
        .and_then(Value::as_str)
}

#[cfg(unix)]
fn spawn_output(context: &ModelContext, scenario: &TprodIFlagshipScenario) -> Value {
    let outputs = flagship_outputs(context);
    spawn_output_from_outputs(&outputs, context, scenario).clone()
}

#[cfg(unix)]
fn spawn_output_from_outputs<'a>(
    outputs: &'a [Value],
    context: &ModelContext,
    scenario: &TprodIFlagshipScenario,
) -> &'a Value {
    outputs
        .iter()
        .find(|output| output["workerId"].as_str() == Some(scenario.worker_id.as_str()))
        .unwrap_or_else(|| {
            panic!(
                "missing worker spawn output: {}",
                flagship_output_summary(context)
            )
        })
}

#[cfg(unix)]
fn registered_function_metadata(
    context: &ModelContext,
    scenario: &TprodIFlagshipScenario,
) -> Value {
    let outputs = flagship_outputs(context);
    registered_function_metadata_from_outputs(&outputs, context, scenario).clone()
}

#[cfg(unix)]
fn registered_function_metadata_from_outputs<'a>(
    outputs: &'a [Value],
    context: &ModelContext,
    scenario: &TprodIFlagshipScenario,
) -> &'a Value {
    outputs
        .iter()
        .filter_map(|output| {
            output
                .pointer("/snapshot/functions")
                .and_then(Value::as_array)
        })
        .flatten()
        .find(|function| function["id"].as_str() == Some(scenario.function_id.as_str()))
        .and_then(|function| function.get("metadata"))
        .unwrap_or_else(|| {
            panic!(
                "catalog snapshot missing registered metadata for {}: {}",
                scenario.function_id,
                flagship_output_summary(context)
            )
        })
}

#[cfg(unix)]
fn inspect_guidance_text(context: &ModelContext, scenario: &TprodIFlagshipScenario) -> String {
    context
        .messages
        .iter()
        .filter_map(|message| match message {
            ModelMessage::CapabilityResult { content, .. } => {
                Some(hmh_capability_result_text(content))
            }
            _ => None,
        })
        .find(|text| {
            text.contains("[execute result - exact target output or status text]")
                && text.contains(&scenario.function_id)
                && text.contains("implemented by")
        })
        .unwrap_or_else(|| {
            panic!(
                "missing capability inspect guidance for {}: {}",
                scenario.function_id,
                flagship_output_summary(context)
            )
        })
}

#[cfg(unix)]
fn flagship_output_summary(context: &ModelContext) -> String {
    let raw_results = context
        .messages
        .iter()
        .filter_map(|message| match message {
            ModelMessage::CapabilityResult { content, .. } => {
                let text = hmh_capability_result_text(content);
                Some(if text.chars().count() > 800 {
                    format!("{}...", text.chars().take(800).collect::<String>())
                } else {
                    text
                })
            }
            _ => None,
        })
        .collect::<Vec<_>>();
    let summaries = flagship_outputs(context)
        .into_iter()
        .map(|output| {
            let keys = output
                .as_object()
                .map(|object| object.keys().cloned().collect::<Vec<_>>())
                .unwrap_or_default();
            json!({
                "keys": keys,
                "inspectedFunctionId": inspected_function_id(&output),
                "directFunctionId": output.pointer("/implementation/functionId").and_then(Value::as_str),
                "wrappedFunctionId": output.pointer("/details/implementation/functionId").and_then(Value::as_str),
                "selectedTarget": output.pointer("/orchestration/phaseDetails/selectedTarget/functionId").and_then(Value::as_str),
                "wrappedSelectedTarget": output.pointer("/details/orchestration/phaseDetails/selectedTarget/functionId").and_then(Value::as_str),
                "workerId": output.get("workerId").and_then(Value::as_str),
                "status": output.get("status"),
                "state": output.get("state"),
                "isError": output.get("isError"),
                "error": output.get("error").or_else(|| output.get("message")),
            })
        })
        .collect::<Vec<_>>();
    serde_json::to_string_pretty(&json!({
        "jsonOutputs": summaries,
        "rawCapabilityResults": raw_results,
    }))
    .unwrap_or_else(|_| "<unserializable outputs>".to_owned())
}

#[cfg(unix)]
fn flagship_outputs(context: &ModelContext) -> Vec<Value> {
    hmh_execute_outputs(context)
}
