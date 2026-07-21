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
        !runtime
            .store()
            .summary(&outcome.worker.worker_id)
            .unwrap()
            .unwrap()
            .enabled
    );
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
            Ok(StreamEvent::CapabilityInvocationDraftStart {
                invocation_id: "nested-depth-call".to_owned(),
                name: "worker_invoke".to_owned(),
            }),
            Ok(StreamEvent::CapabilityInvocationDraftDelta {
                invocation_id: "nested-depth-call".to_owned(),
                arguments_delta: serde_json::to_string(&arguments).unwrap(),
            }),
            Ok(StreamEvent::CapabilityInvocationDraftEnd {
                capability_invocation:
                    crate::shared::protocol::messages::CapabilityInvocationDraft::new(
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
                stop_reason: "capability_invocation".to_owned(),
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
                    .capabilities
                    .as_ref()
                    .expect("agent worker tools")
                    .iter()
                    .map(|tool| tool.name.as_str())
                    .collect::<Vec<_>>();
                assert!(tools.contains(&"worker_invoke"), "{tools:?}");
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
    };
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
            .runs(Some("nested-depth-target"), 10)
            .unwrap()
            .is_empty(),
        "over-depth nested dispatch must fail before persistence"
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
    assert_eq!(record.status, "failed", "{record:?}");
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
