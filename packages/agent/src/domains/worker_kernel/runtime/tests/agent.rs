use super::*;

struct JsonResponder;

fn worker_test_responder_info() -> ModelResponderInfo {
    ModelResponderInfo {
        provider_type: crate::shared::protocol::messages::Provider::Anthropic,
        provider_name: "worker-test",
        model: "worker-test-model".to_owned(),
        context_window: 20_000,
    }
}

#[async_trait]
impl ModelResponder for JsonResponder {
    fn info(&self) -> ModelResponderInfo {
        worker_test_responder_info()
    }

    async fn respond(
        &self,
        request: ModelResponseRequest,
    ) -> Result<ModelResponse, ModelResponseError> {
        let context = serde_json::to_string(&request.context.messages)
            .expect("serialize agent worker prompt context");
        assert!(context.contains("idempotencyKey"), "{context}");
        assert!(context.contains("trace-agent"), "{context}");
        assert!(context.contains("Output JSON Schema"), "{context}");
        assert!(context.contains("kernel rejects"), "{context}");
        assert!(context.contains("answer"), "{context}");
        assert_eq!(
            request.reasoning_level,
            Some(crate::domains::model::responder::ModelReasoningLevel::Low)
        );
        let text = "{\"answer\":\"agent-runner\"}";
        let events = vec![
            Ok(StreamEvent::Start),
            Ok(StreamEvent::TextDelta {
                delta: text.to_owned(),
            }),
            Ok(StreamEvent::Done {
                message: AssistantMessage {
                    content: vec![AssistantContent::text(text)],
                    token_usage: None,
                },
                stop_reason: "end_turn".to_owned(),
            }),
        ];
        Ok(ModelResponse {
            info: self.info(),
            stream: Box::pin(stream::iter(events)) as ModelResponseStream,
        })
    }
}

struct JsonResponderFactory;

#[async_trait]
impl ModelResponderFactory for JsonResponderFactory {
    async fn create_for_model(
        &self,
        _model: &str,
        _settings: &crate::domains::settings::ApiSettings,
    ) -> Result<Arc<dyn ModelResponder>, ModelResponseError> {
        Ok(Arc::new(JsonResponder))
    }
}

struct FailingResponderFactory;

#[async_trait]
impl ModelResponderFactory for FailingResponderFactory {
    async fn create_for_model(
        &self,
        _model: &str,
        _settings: &crate::domains::settings::ApiSettings,
    ) -> Result<Arc<dyn ModelResponder>, ModelResponseError> {
        Err(ModelResponseError::auth(
            "agent runner fixture has no configured provider authentication",
        ))
    }
}

struct NonRecoverableFailingResponderFactory;

#[async_trait]
impl ModelResponderFactory for NonRecoverableFailingResponderFactory {
    async fn create_for_model(
        &self,
        _model: &str,
        _settings: &crate::domains::settings::ApiSettings,
    ) -> Result<Arc<dyn ModelResponder>, ModelResponseError> {
        Err(ModelResponseError::other(
            "synthetic non-recoverable model responder failure",
        ))
    }
}

struct HangingResponder;

#[async_trait]
impl ModelResponder for HangingResponder {
    fn info(&self) -> ModelResponderInfo {
        worker_test_responder_info()
    }

    async fn respond(
        &self,
        _request: ModelResponseRequest,
    ) -> Result<ModelResponse, ModelResponseError> {
        std::future::pending().await
    }
}

struct HangingResponderFactory;

#[async_trait]
impl ModelResponderFactory for HangingResponderFactory {
    async fn create_for_model(
        &self,
        _model: &str,
        _settings: &crate::domains::settings::ApiSettings,
    ) -> Result<Arc<dyn ModelResponder>, ModelResponseError> {
        Ok(Arc::new(HangingResponder))
    }
}

#[tokio::test]
async fn agent_runner_returns_typed_json() {
    let (runtime, _home) = test_runtime(Some(Arc::new(JsonResponderFactory)));
    let mut bundle = command_bundle(Vec::new());
    bundle.name = "Agent Worker".to_owned();
    bundle.description = "Executes a durable agent instruction contract".to_owned();
    bundle.tool_name = Some("worker_agent_test".to_owned());
    bundle.output_schema = json!({
        "type":"object",
        "required":["answer"],
        "properties":{"answer":{"type":"string"}}
    });
    bundle.runner = WorkerRunner::Agent {
        instructions: "Return the requested typed JSON answer.".to_owned(),
        model: None,
        reasoning_level: Some("low".to_owned()),
    };
    let outcome = runtime.upsert(bundle, None).await.unwrap();
    let result = runtime
        .invoke(request(&outcome.worker.worker_id, json!({}), "agent"))
        .await
        .unwrap();
    assert_eq!(
        result.output,
        Some(json!({"answer":"agent-runner"})),
        "agent worker result: {result:?}"
    );
    let agent_session_id = result
        .agent_session_id
        .as_deref()
        .expect("agent invocation should expose its child session");
    assert!(agent_session_id.starts_with("sess_"), "{agent_session_id}");
    assert_eq!(
        runtime
            .store()
            .invocation(&result.invocation_id)
            .unwrap()
            .unwrap()
            .agent_session_id
            .as_deref(),
        Some(agent_session_id)
    );
}

#[tokio::test]
async fn invocation_override_precedes_worker_defaults_and_is_durable() {
    let (runtime, _home) = test_runtime(None);
    let mut bundle = command_bundle(Vec::new());
    bundle.name = "Override Agent Worker".to_owned();
    bundle.description = "Records explicit invocation model policy".to_owned();
    bundle.tool_name = Some("worker_override_agent_test".to_owned());
    bundle.runner = WorkerRunner::Agent {
        instructions: "Return an object.".to_owned(),
        model: Some("claude-sonnet-4-5".to_owned()),
        reasoning_level: Some("low".to_owned()),
    };
    let outcome = runtime.upsert(bundle, None).await.unwrap();
    let mut invocation = request(&outcome.worker.worker_id, json!({}), "agent-model-override");
    invocation.model = Some("claude-sonnet-4-6".to_owned());
    invocation.reasoning_level = Some("high".to_owned());

    let queued = runtime.enqueue(invocation).unwrap();

    assert_eq!(queued.requested_model.as_deref(), Some("claude-sonnet-4-6"));
    assert_eq!(queued.requested_reasoning_level.as_deref(), Some("high"));
    assert_eq!(queued.effective_model.as_deref(), Some("claude-sonnet-4-6"));
    assert_eq!(queued.effective_reasoning_level.as_deref(), Some("high"));
    let stored = runtime
        .store()
        .invocation(&queued.invocation_id)
        .unwrap()
        .unwrap();
    assert_eq!(stored.requested_model, queued.requested_model);
    assert_eq!(stored.effective_model, queued.effective_model);
    assert_eq!(
        stored.requested_reasoning_level,
        queued.requested_reasoning_level
    );
    assert_eq!(
        stored.effective_reasoning_level,
        queued.effective_reasoning_level
    );
}

#[tokio::test]
async fn bundle_model_defaults_are_validated_before_durable_admission() {
    let (runtime, _home) = test_runtime(None);
    let mut bundle = command_bundle(Vec::new());
    bundle.name = "Invalid Default Agent Worker".to_owned();
    bundle.description = "Proves immutable defaults share invocation admission".to_owned();
    bundle.tool_name = Some("worker_invalid_default_agent_test".to_owned());
    bundle.runner = WorkerRunner::Agent {
        instructions: "Return an object.".to_owned(),
        model: Some("model-that-does-not-exist".to_owned()),
        reasoning_level: Some("medium".to_owned()),
    };
    let outcome = runtime.upsert(bundle, None).await.unwrap();

    let error = runtime
        .enqueue(request(
            &outcome.worker.worker_id,
            json!({}),
            "invalid-agent-default",
        ))
        .unwrap_err();

    assert!(error.contains("unknown model"), "{error}");
}

#[tokio::test]
async fn openai_x_high_bundle_default_uses_provider_neutral_spelling() {
    let (runtime, _home) = test_runtime(None);
    let mut bundle = command_bundle(Vec::new());
    bundle.name = "OpenAI Reasoning Agent Worker".to_owned();
    bundle.description = "Proves provider-neutral reasoning admission".to_owned();
    bundle.tool_name = Some("worker_openai_reasoning_agent_test".to_owned());
    bundle.runner = WorkerRunner::Agent {
        instructions: "Return an object.".to_owned(),
        model: Some("openai/gpt-5.6-sol".to_owned()),
        reasoning_level: Some("x_high".to_owned()),
    };
    let outcome = runtime.upsert(bundle, None).await.unwrap();

    let queued = runtime
        .enqueue(request(
            &outcome.worker.worker_id,
            json!({}),
            "openai-x-high-default",
        ))
        .unwrap();

    assert_eq!(
        queued.effective_model.as_deref(),
        Some("openai/gpt-5.6-sol")
    );
    assert_eq!(queued.effective_reasoning_level.as_deref(), Some("x_high"));
}

#[tokio::test]
async fn command_runner_rejects_model_overrides() {
    let (runtime, _home) = test_runtime(None);
    let outcome = runtime
        .upsert(
            command_bundle(vec!["python3".to_owned(), "worker.py".to_owned()]),
            None,
        )
        .await
        .unwrap();
    let mut invocation = request(
        &outcome.worker.worker_id,
        json!({}),
        "command-model-override",
    );
    invocation.model = Some("claude-sonnet-4-6".to_owned());

    let error = runtime.enqueue(invocation).unwrap_err();

    assert!(error.contains("does not use an agent runner"), "{error}");
}

#[tokio::test]
async fn agent_runner_captures_a_fast_terminal_provider_failure() {
    let (runtime, _home) = test_runtime(Some(Arc::new(FailingResponderFactory)));
    let mut bundle = command_bundle(Vec::new());
    bundle.name = "Failing Agent Worker".to_owned();
    bundle.description = "Surfaces a provider failure that races prompt acknowledgement".to_owned();
    bundle.tool_name = Some("worker_failing_agent_test".to_owned());
    bundle.runner = WorkerRunner::Agent {
        instructions: "Return an object.".to_owned(),
        model: None,
        reasoning_level: None,
    };
    let outcome = runtime.upsert(bundle, None).await.unwrap();
    let result = runtime
        .invoke(request(
            &outcome.worker.worker_id,
            json!({}),
            "agent-failure",
        ))
        .await
        .unwrap();

    assert_eq!(result.status, "failed");
    assert!(
        result.error.as_deref().is_some_and(|error| error
            .contains("agent runner fixture has no configured provider authentication")),
        "fast provider failure was replaced by a generic result error: {result:?}"
    );
    assert!(
        runtime
            .store()
            .summary(&outcome.worker.worker_id)
            .unwrap()
            .unwrap()
            .enabled,
        "a recoverable provider failure must fail only this invocation"
    );
}

#[tokio::test]
async fn nonrecoverable_agent_runtime_failure_does_not_quarantine_worker() {
    let (runtime, _home) = test_runtime(Some(Arc::new(NonRecoverableFailingResponderFactory)));
    let mut bundle = command_bundle(Vec::new());
    bundle.name = "Non-Recoverable Agent Failure Worker".to_owned();
    bundle.description =
        "Proves one agent runtime failure cannot quarantine an immutable worker".to_owned();
    bundle.tool_name = Some("worker_nonrecoverable_agent_failure_test".to_owned());
    bundle.runner = WorkerRunner::Agent {
        instructions: "Return an object.".to_owned(),
        model: None,
        reasoning_level: None,
    };
    let outcome = runtime.upsert(bundle, None).await.unwrap();

    let result = runtime
        .invoke(request(
            &outcome.worker.worker_id,
            json!({}),
            "nonrecoverable-agent-failure",
        ))
        .await
        .unwrap();

    assert_eq!(result.status, "failed");
    assert!(
        result.error.as_deref().is_some_and(
            |error| error.contains("synthetic non-recoverable model responder failure")
        ),
        "agent runtime failure was replaced by a generic result error: {result:?}"
    );
    let summary = runtime
        .store()
        .summary(&outcome.worker.worker_id)
        .unwrap()
        .unwrap();
    assert!(summary.enabled, "agent runtime failure disabled the worker");
    assert_eq!(summary.health, "healthy");
}

#[tokio::test]
async fn agent_execution_timeout_does_not_quarantine_worker() {
    let (runtime, _home) = test_runtime(Some(Arc::new(HangingResponderFactory)));
    let mut bundle = command_bundle(Vec::new());
    bundle.name = "Timed Agent Worker".to_owned();
    bundle.description = "Proves one timeout cannot quarantine an immutable worker".to_owned();
    bundle.tool_name = Some("worker_timed_agent_test".to_owned());
    bundle.execution_limits.max_invocation_seconds = Some(1);
    bundle.runner = WorkerRunner::Agent {
        instructions: "Return an object.".to_owned(),
        model: None,
        reasoning_level: None,
    };
    let outcome = runtime.upsert(bundle, None).await.unwrap();

    let result = runtime
        .invoke(request(
            &outcome.worker.worker_id,
            json!({}),
            "timed-agent-failure",
        ))
        .await
        .unwrap();

    assert_eq!(result.status, "failed");
    assert!(
        result
            .error
            .as_deref()
            .is_some_and(|error| error.contains("worker invocation exceeded 1 seconds")),
        "agent timeout was replaced by a generic result error: {result:?}"
    );
    let summary = runtime
        .store()
        .summary(&outcome.worker.worker_id)
        .unwrap()
        .unwrap();
    assert!(summary.enabled, "agent timeout disabled the worker");
    assert_eq!(summary.health, "healthy");
}

struct NestedDepthResponder {
    calls: Arc<AtomicUsize>,
}

impl NestedDepthResponder {
    fn response(events: Vec<Result<StreamEvent, ModelResponseError>>) -> ModelResponse {
        ModelResponse {
            info: worker_test_responder_info(),
            stream: Box::pin(stream::iter(events)) as ModelResponseStream,
        }
    }

    fn tool_call() -> ModelResponse {
        let arguments = serde_json::Map::from_iter([
            ("workerId".to_owned(), json!("nested-depth-target")),
            ("input".to_owned(), json!({})),
            ("idempotencyKey".to_owned(), json!("nested-depth-delivery")),
        ]);
        Self::response(vec![
            Ok(StreamEvent::Start),
            Ok(StreamEvent::ToolInvocationDraftStart {
                invocation_id: "nested-depth-call".to_owned(),
                name: "worker_invoke".to_owned(),
            }),
            Ok(StreamEvent::ToolInvocationDraftDelta {
                invocation_id: "nested-depth-call".to_owned(),
                arguments_delta: serde_json::to_string(&arguments).unwrap(),
            }),
            Ok(StreamEvent::ToolInvocationDraftEnd {
                tool_invocation: crate::shared::protocol::messages::ToolInvocationDraft::new(
                    "nested-depth-call",
                    "worker_invoke",
                    arguments,
                ),
            }),
            Ok(StreamEvent::Done {
                message: AssistantMessage {
                    content: Vec::new(),
                    token_usage: None,
                },
                stop_reason: "tool_invocation".to_owned(),
            }),
        ])
    }
}

#[async_trait]
impl ModelResponder for NestedDepthResponder {
    fn info(&self) -> ModelResponderInfo {
        worker_test_responder_info()
    }

    async fn respond(
        &self,
        request: ModelResponseRequest,
    ) -> Result<ModelResponse, ModelResponseError> {
        match self.calls.fetch_add(1, Ordering::SeqCst) {
            0 => {
                let tools = request
                    .context
                    .tools
                    .as_ref()
                    .expect("agent worker tools")
                    .iter()
                    .map(|tool| tool.name.as_str())
                    .collect::<Vec<_>>();
                assert_eq!(tools, vec!["worker_invoke"]);
                Ok(Self::tool_call())
            }
            1 => {
                let messages = serde_json::to_string(&request.context.messages).unwrap();
                assert!(
                    messages.contains("causal depth 17") && messages.contains("limit 16"),
                    "nested worker call escaped the causal ceiling: {messages}"
                );
                let result = "{\"answer\":\"depth-blocked\"}";
                Ok(Self::response(vec![
                    Ok(StreamEvent::Start),
                    Ok(StreamEvent::TextDelta {
                        delta: result.to_owned(),
                    }),
                    Ok(StreamEvent::Done {
                        message: AssistantMessage {
                            content: vec![AssistantContent::text(result)],
                            token_usage: None,
                        },
                        stop_reason: "end_turn".to_owned(),
                    }),
                ]))
            }
            call => panic!("unexpected nested-depth responder call {call}"),
        }
    }
}

struct NestedDepthResponderFactory {
    calls: Arc<AtomicUsize>,
}

#[async_trait]
impl ModelResponderFactory for NestedDepthResponderFactory {
    async fn create_for_model(
        &self,
        _model: &str,
        _settings: &crate::domains::settings::ApiSettings,
    ) -> Result<Arc<dyn ModelResponder>, ModelResponseError> {
        Ok(Arc::new(NestedDepthResponder {
            calls: Arc::clone(&self.calls),
        }))
    }
}

#[tokio::test]
async fn agent_runner_preserves_causal_depth_for_nested_worker_calls() {
    let calls = Arc::new(AtomicUsize::new(0));
    let (runtime, _home) = test_runtime(Some(Arc::new(NestedDepthResponderFactory {
        calls: Arc::clone(&calls),
    })));

    let mut target = command_bundle(vec!["sh".to_owned(), "-c".to_owned(), "cat".to_owned()]);
    target.worker_id = Some("nested-depth-target".to_owned());
    target.name = "Nested Depth Target".to_owned();
    target.description = "Target used only to detect an escaped causal-depth ceiling".to_owned();
    target.tool_name = Some("worker_nested_depth_target".to_owned());
    runtime.upsert(target, None).await.unwrap();

    let mut agent = command_bundle(Vec::new());
    agent.worker_id = Some("nested-depth-agent".to_owned());
    agent.name = "Nested Depth Agent".to_owned();
    agent.description = "Agent runner that attempts one nested worker dispatch".to_owned();
    agent.tool_name = Some("worker_nested_depth_agent".to_owned());
    agent.output_schema = json!({
        "type":"object",
        "required":["answer"],
        "properties":{"answer":{"type":"string"}}
    });
    agent.runner = WorkerRunner::Agent {
        instructions: "Attempt the nested worker call, then return typed JSON.".to_owned(),
        model: None,
        reasoning_level: None,
    };
    agent.agent_tools = Some(vec!["worker_invoke".to_owned()]);
    let outcome = runtime.upsert(agent, None).await.unwrap();
    let mut invocation = request(&outcome.worker.worker_id, json!({}), "nested-depth-agent");
    invocation.causal_depth = MAX_CAUSAL_DEPTH;

    let completed = runtime.invoke(invocation).await.unwrap();

    assert_eq!(completed.status, "completed", "{completed:?}");
    assert_eq!(completed.output, Some(json!({"answer":"depth-blocked"})));
    assert_eq!(calls.load(Ordering::SeqCst), 2);
    assert!(
        runtime
            .store()
            .runs_filtered(Some("nested-depth-target"), None, 10)
            .unwrap()
            .is_empty(),
        "over-depth nested dispatch must fail before persistence"
    );
}

struct InternalWorkerToolResponder {
    calls: Arc<AtomicUsize>,
}

#[async_trait]
impl ModelResponder for InternalWorkerToolResponder {
    fn info(&self) -> ModelResponderInfo {
        worker_test_responder_info()
    }

    async fn respond(
        &self,
        request: ModelResponseRequest,
    ) -> Result<ModelResponse, ModelResponseError> {
        match self.calls.fetch_add(1, Ordering::SeqCst) {
            0 => {
                let tools = request
                    .context
                    .tools
                    .as_ref()
                    .expect("internal worker tool surface")
                    .iter()
                    .map(|tool| tool.name.as_str())
                    .collect::<Vec<_>>();
                assert_eq!(tools, vec!["worker_internal_specialist"]);
                let arguments = serde_json::Map::new();
                Ok(NestedDepthResponder::response(vec![
                    Ok(StreamEvent::Start),
                    Ok(StreamEvent::ToolInvocationDraftStart {
                        invocation_id: "internal-specialist-call".to_owned(),
                        name: "worker_internal_specialist".to_owned(),
                    }),
                    Ok(StreamEvent::ToolInvocationDraftDelta {
                        invocation_id: "internal-specialist-call".to_owned(),
                        arguments_delta: "{}".to_owned(),
                    }),
                    Ok(StreamEvent::ToolInvocationDraftEnd {
                        tool_invocation:
                            crate::shared::protocol::messages::ToolInvocationDraft::new(
                                "internal-specialist-call",
                                "worker_internal_specialist",
                                arguments,
                            ),
                    }),
                    Ok(StreamEvent::Done {
                        message: AssistantMessage {
                            content: Vec::new(),
                            token_usage: None,
                        },
                        stop_reason: "tool_invocation".to_owned(),
                    }),
                ]))
            }
            1 => {
                let messages = serde_json::to_string(&request.context.messages).unwrap();
                assert!(messages.contains("specialist"), "{messages}");
                let result = "{\"answer\":\"internal-specialist-composed\"}";
                Ok(NestedDepthResponder::response(vec![
                    Ok(StreamEvent::Start),
                    Ok(StreamEvent::TextDelta {
                        delta: result.to_owned(),
                    }),
                    Ok(StreamEvent::Done {
                        message: AssistantMessage {
                            content: vec![AssistantContent::text(result)],
                            token_usage: None,
                        },
                        stop_reason: "end_turn".to_owned(),
                    }),
                ]))
            }
            call => panic!("unexpected internal worker responder call {call}"),
        }
    }
}

struct InternalWorkerToolResponderFactory {
    calls: Arc<AtomicUsize>,
}

#[async_trait]
impl ModelResponderFactory for InternalWorkerToolResponderFactory {
    async fn create_for_model(
        &self,
        _model: &str,
        _settings: &crate::domains::settings::ApiSettings,
    ) -> Result<Arc<dyn ModelResponder>, ModelResponseError> {
        Ok(Arc::new(InternalWorkerToolResponder {
            calls: Arc::clone(&self.calls),
        }))
    }
}

#[tokio::test]
async fn allowlisted_agent_runner_calls_internal_worker_tool_without_generic_invoke() {
    let calls = Arc::new(AtomicUsize::new(0));
    let (runtime, _home) = test_runtime(Some(Arc::new(InternalWorkerToolResponderFactory {
        calls: Arc::clone(&calls),
    })));

    let mut specialist = command_bundle(vec![
        "printf".to_owned(),
        "{\"specialist\":\"ready\"}".to_owned(),
    ]);
    specialist.worker_id = Some("internal-specialist".to_owned());
    specialist.name = "Internal Specialist".to_owned();
    specialist.description = "Deterministic internal specialist".to_owned();
    specialist.tool_name = Some("worker_internal_specialist".to_owned());
    specialist.model_exposure = crate::domains::worker_kernel::types::WorkerModelExposure::Internal;
    specialist.tool_input_schema = None;
    specialist.output_schema = json!({
        "type":"object",
        "additionalProperties":false,
        "required":["specialist"],
        "properties":{"specialist":{"const":"ready"}}
    });
    runtime.upsert(specialist, None).await.unwrap();

    let mut coordinator = command_bundle(Vec::new());
    coordinator.worker_id = Some("internal-specialist-coordinator".to_owned());
    coordinator.name = "Internal Specialist Coordinator".to_owned();
    coordinator.description = "Calls one exact internal specialist tool".to_owned();
    coordinator.tool_name = Some("worker_internal_specialist_coordinator".to_owned());
    coordinator.agent_tools = Some(vec!["worker_internal_specialist".to_owned()]);
    coordinator.output_schema = json!({
        "type":"object",
        "additionalProperties":false,
        "required":["answer"],
        "properties":{"answer":{"type":"string"}}
    });
    coordinator.runner = WorkerRunner::Agent {
        instructions: "Call the internal specialist and return the composed answer.".to_owned(),
        model: None,
        reasoning_level: None,
    };
    let coordinator = runtime.upsert(coordinator, None).await.unwrap();

    let completed = runtime
        .invoke(request(
            &coordinator.worker.worker_id,
            json!({}),
            "internal-specialist-coordination",
        ))
        .await
        .unwrap();
    assert_eq!(completed.status, "completed", "{completed:?}");
    assert_eq!(
        completed.output,
        Some(json!({"answer":"internal-specialist-composed"}))
    );
    assert_eq!(calls.load(Ordering::SeqCst), 2);
    assert_eq!(
        runtime
            .store()
            .runs_filtered(Some("internal-specialist"), None, 10)
            .unwrap()
            .len(),
        1
    );
}

struct PendingResponder;

#[async_trait]
impl ModelResponder for PendingResponder {
    fn info(&self) -> ModelResponderInfo {
        worker_test_responder_info()
    }

    async fn respond(
        &self,
        _request: ModelResponseRequest,
    ) -> Result<ModelResponse, ModelResponseError> {
        Ok(ModelResponse {
            info: self.info(),
            stream: Box::pin(stream::pending::<Result<StreamEvent, ModelResponseError>>())
                as ModelResponseStream,
        })
    }
}

struct PendingResponderFactory;

#[async_trait]
impl ModelResponderFactory for PendingResponderFactory {
    async fn create_for_model(
        &self,
        _model: &str,
        _settings: &crate::domains::settings::ApiSettings,
    ) -> Result<Arc<dyn ModelResponder>, ModelResponseError> {
        Ok(Arc::new(PendingResponder))
    }
}

#[tokio::test]
async fn top_level_agent_worker_returns_a_tagged_background_receipt_immediately() {
    let (runtime, _home) = test_runtime(Some(Arc::new(PendingResponderFactory)));
    let mut bundle = command_bundle(Vec::new());
    bundle.worker_id = Some("background-agent".to_owned());
    bundle.name = "Background Agent".to_owned();
    bundle.description = "Pending agent runner used to prove immediate durable delivery".to_owned();
    bundle.tool_name = Some("worker_background_agent".to_owned());
    bundle.runner = WorkerRunner::Agent {
        instructions: "Wait for explicit cancellation.".to_owned(),
        model: None,
        reasoning_level: None,
    };
    let outcome = runtime.upsert(bundle, None).await.unwrap();
    runtime
        .orchestrator
        .init_sequence_counter("session-background-agent", 0);
    let result = runtime
        .host
        .invoke(Invocation::new_sync(
            FunctionId::new(format!(
                "worker_kernel::dynamic_{}",
                outcome.worker.worker_id
            ))
            .unwrap(),
            json!({}),
            CausalContext::new(
                ActorId::new("agent:session-background-agent").unwrap(),
                ActorKind::Agent,
                TraceId::new("trace-background-agent").unwrap(),
            )
            .with_session_id("session-background-agent")
            .with_model_tool_invocation_id("provider-background-agent")
            .with_idempotency_key("background-agent-provider-call"),
        ))
        .await;
    assert_eq!(result.error, None, "{:?}", result.error);
    let receipt = result.value.unwrap();
    assert_eq!(receipt["kind"], "worker_invocation_receipt");
    assert_eq!(receipt["mode"], "background");
    assert_eq!(receipt["workerId"], outcome.worker.worker_id);
    assert_eq!(receipt["originSessionId"], "session-background-agent");
    assert!(matches!(
        receipt["status"].as_str(),
        Some("queued" | "running")
    ));
    let invocation_id = receipt["invocationId"].as_str().unwrap();
    let message = receipt["message"].as_str().unwrap();
    assert!(message.contains("agent_wait_for_workers"));
    assert!(message.contains(invocation_id));
    assert!(message.contains("Do not poll"));
    let durable = runtime.store().invocation(invocation_id).unwrap().unwrap();
    assert_eq!(durable.interaction_mode, WorkerInteractionMode::Background);
    assert_eq!(
        durable.model_tool_invocation_id.as_deref(),
        Some("provider-background-agent")
    );
    runtime.cancel_invocation(invocation_id).await.unwrap();
}

#[tokio::test]
async fn disabling_agent_worker_aborts_its_spawned_child_session() {
    let (runtime, _home) = test_runtime(Some(Arc::new(PendingResponderFactory)));
    let mut bundle = command_bundle(Vec::new());
    bundle.worker_id = Some("cancellable-agent".to_owned());
    bundle.name = "Cancellable Agent".to_owned();
    bundle.description = "Pending agent runner used to prove lifecycle cancellation".to_owned();
    bundle.tool_name = Some("worker_cancellable_agent".to_owned());
    bundle.runner = WorkerRunner::Agent {
        instructions: "Wait until the invocation is stopped.".to_owned(),
        model: None,
        reasoning_level: None,
    };
    let outcome = runtime.upsert(bundle, None).await.unwrap();
    let worker_id = outcome.worker.worker_id.clone();
    let invoke_runtime = Arc::clone(&runtime);
    let invoke_worker_id = worker_id.clone();
    let invocation = tokio::spawn(async move {
        invoke_runtime
            .invoke(request(&invoke_worker_id, json!({}), "cancellable-agent"))
            .await
            .unwrap()
    });

    tokio::time::timeout(Duration::from_secs(5), async {
        while runtime.orchestrator.active_run_count() == 0 {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    })
    .await
    .expect("agent worker child session did not start");

    runtime.set_enabled(&worker_id, false).await.unwrap();
    let record = tokio::time::timeout(Duration::from_secs(5), invocation)
        .await
        .expect("disabled agent worker invocation did not terminate")
        .unwrap();
    assert_eq!(record.status, "cancelled", "{record:?}");
    assert!(
        record
            .error
            .as_deref()
            .is_some_and(|error| error.contains("disabled")),
        "{record:?}"
    );
    tokio::time::timeout(Duration::from_secs(5), async {
        while runtime.orchestrator.active_run_count() != 0 {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    })
    .await
    .expect("agent worker child session outlived its disabled invocation");
}

#[tokio::test]
async fn cancelling_one_agent_invocation_aborts_only_its_child_session() {
    let (runtime, _home) = test_runtime(Some(Arc::new(PendingResponderFactory)));
    let mut bundle = command_bundle(Vec::new());
    bundle.worker_id = Some("precise-agent-cancel".to_owned());
    bundle.name = "Precise Agent Cancel".to_owned();
    bundle.description = "Pending agent runner used to prove invocation cancellation".to_owned();
    bundle.tool_name = Some("worker_precise_agent_cancel".to_owned());
    bundle.runner = WorkerRunner::Agent {
        instructions: "Wait until this invocation is cancelled.".to_owned(),
        model: None,
        reasoning_level: None,
    };
    let outcome = runtime.upsert(bundle, None).await.unwrap();
    let worker_id = outcome.worker.worker_id.clone();
    let invoke_runtime = Arc::clone(&runtime);
    let invoke_worker_id = worker_id.clone();
    let invocation = tokio::spawn(async move {
        invoke_runtime
            .invoke(request(
                &invoke_worker_id,
                json!({}),
                "precise-agent-cancel",
            ))
            .await
            .unwrap()
    });

    let run = tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            if let Some(run) = runtime
                .store()
                .runs_filtered(Some(&worker_id), Some("running"), 1)
                .unwrap()
                .into_iter()
                .next()
                && run.agent_session_id.is_some()
            {
                break run;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    })
    .await
    .expect("agent invocation never linked its running child session");

    let child_session_id = run.agent_session_id.as_deref().unwrap();
    let child_session = runtime
        .event_store
        .get_session(child_session_id)
        .unwrap()
        .unwrap();
    assert!(child_session.is_worker_session());
    assert!(
        runtime
            .event_store
            .list_sessions(&Default::default())
            .unwrap()
            .iter()
            .all(|session| session.id != child_session_id),
        "ordinary conversation listings must hide worker-owned child sessions"
    );

    let cancelled = runtime.cancel_invocation(&run.invocation_id).await.unwrap();
    assert_eq!(cancelled.status, "cancelled");
    assert_eq!(cancelled.agent_session_id, run.agent_session_id);
    let joined = tokio::time::timeout(Duration::from_secs(5), invocation)
        .await
        .expect("cancelled agent invocation did not terminate")
        .unwrap();
    assert_eq!(joined.status, "cancelled", "{joined:?}");
    assert!(
        runtime
            .event_store
            .get_session(child_session_id)
            .unwrap()
            .unwrap()
            .ended_at
            .is_none(),
        "worker child sessions remain reconstructable audit evidence"
    );
    tokio::time::timeout(Duration::from_secs(5), async {
        while runtime.orchestrator.active_run_count() != 0 {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    })
    .await
    .expect("agent child session outlived precise invocation cancellation");
    assert!(
        runtime
            .store()
            .summary(&worker_id)
            .unwrap()
            .unwrap()
            .enabled,
        "precise cancellation must not disable the worker"
    );
}
