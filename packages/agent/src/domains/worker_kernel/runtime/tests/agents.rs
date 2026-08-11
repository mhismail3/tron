use super::*;
use crate::domains::session::event_store::{
    AppendOptions, CoordinationTargetKind, CoordinationTerminalEvidence,
    CoordinationWaitDependency, CoordinationWaitMode, CoordinationWaitTarget, EventType,
    NewCoordinationWait,
};
use crate::domains::worker_kernel::types::{WorkerAgentResultMode, WorkerAgentRoleLimits};

struct CoordinationResultResponder;

#[async_trait]
impl ModelResponder for CoordinationResultResponder {
    fn info(&self) -> ModelResponderInfo {
        ModelResponderInfo {
            provider_type: crate::shared::protocol::messages::Provider::Anthropic,
            provider_name: "coordination-test",
            model: "coordination-test-model".to_owned(),
            context_window: 20_000,
        }
    }

    async fn respond(
        &self,
        _request: ModelResponseRequest,
    ) -> Result<ModelResponse, ModelResponseError> {
        let text = "The resumed assignment consumed its aggregate result.";
        Ok(ModelResponse {
            info: self.info(),
            stream: Box::pin(stream::iter(vec![
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
            ])) as ModelResponseStream,
        })
    }
}

struct CoordinationResultResponderFactory;

#[async_trait]
impl ModelResponderFactory for CoordinationResultResponderFactory {
    async fn create_for_model(
        &self,
        _model: &str,
        _settings: &crate::domains::settings::ApiSettings,
    ) -> Result<Arc<dyn ModelResponder>, ModelResponseError> {
        Ok(Arc::new(CoordinationResultResponder))
    }
}

struct AuxiliaryAuthorityResponder {
    root_session_id: Arc<std::sync::Mutex<Option<String>>>,
    expected_agent_id: Arc<std::sync::Mutex<Option<String>>>,
    child_calls: Arc<AtomicUsize>,
    failure: Arc<std::sync::Mutex<Option<String>>>,
}

impl AuxiliaryAuthorityResponder {
    fn text_response(&self, text: &str) -> ModelResponse {
        ModelResponse {
            info: self.info(),
            stream: Box::pin(stream::iter(vec![
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
            ])) as ModelResponseStream,
        }
    }

    fn denied_write_attempt(&self) -> ModelResponse {
        let arguments = serde_json::Map::from_iter([
            ("path".to_owned(), json!("Sources/auxiliary-write.txt")),
            ("content".to_owned(), json!("must not be written")),
        ]);
        ModelResponse {
            info: self.info(),
            stream: Box::pin(stream::iter(vec![
                Ok(StreamEvent::Start),
                Ok(StreamEvent::ToolInvocationDraftStart {
                    invocation_id: "auxiliary-forbidden-write".to_owned(),
                    name: "filesystem_write".to_owned(),
                }),
                Ok(StreamEvent::ToolInvocationDraftDelta {
                    invocation_id: "auxiliary-forbidden-write".to_owned(),
                    arguments_delta: serde_json::to_string(&arguments).unwrap(),
                }),
                Ok(StreamEvent::ToolInvocationDraftEnd {
                    tool_invocation: crate::shared::protocol::messages::ToolInvocationDraft::new(
                        "auxiliary-forbidden-write",
                        "filesystem_write",
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
            ])) as ModelResponseStream,
        }
    }

    fn validate_auxiliary_context(&self, request: &ModelResponseRequest) -> Result<(), String> {
        let expected_agent_id = self
            .expected_agent_id
            .lock()
            .unwrap()
            .clone()
            .ok_or_else(|| "expected nested agent identity was not installed".to_owned())?;
        let tools = request
            .context
            .tools
            .as_ref()
            .ok_or_else(|| "bounded auxiliary tool surface was absent".to_owned())?
            .iter()
            .map(|tool| tool.name.as_str())
            .collect::<BTreeSet<_>>();
        if !tools.contains("agent_send")
            || !tools.contains("agent_manage")
            || !tools.contains("filesystem_read")
            || tools.contains("filesystem_write")
            || tools.contains("process_run")
        {
            return Err(format!(
                "session={} received an invalid auxiliary surface: {tools:?}",
                request.session_id
            ));
        }
        let team = request
            .context
            .request_context
            .iter()
            .find(|block| {
                block.kind == crate::shared::protocol::messages::RequestContextKind::AgentTeam
            })
            .ok_or_else(|| "trusted Team Context was absent".to_owned())?;
        let team: Value = serde_json::from_str(&team.content).map_err(|error| error.to_string())?;
        if team["self"]["agentId"] != expected_agent_id {
            return Err(format!(
                "Team Context agentId did not preserve stable identity: {team}"
            ));
        }
        Ok(())
    }

    fn record_failure(&self, error: String) -> ModelResponseError {
        *self.failure.lock().unwrap() = Some(error.clone());
        ModelResponseError::other(error)
    }
}

#[async_trait]
impl ModelResponder for AuxiliaryAuthorityResponder {
    fn info(&self) -> ModelResponderInfo {
        ModelResponderInfo {
            provider_type: crate::shared::protocol::messages::Provider::Anthropic,
            provider_name: "auxiliary-authority-test",
            model: "auxiliary-authority-test-model".to_owned(),
            context_window: 20_000,
        }
    }

    async fn respond(
        &self,
        request: ModelResponseRequest,
    ) -> Result<ModelResponse, ModelResponseError> {
        if self.root_session_id.lock().unwrap().as_deref() == Some(request.session_id.as_str()) {
            return Ok(self.text_response("Root observed the automatic child result."));
        }
        match self.child_calls.fetch_add(1, Ordering::SeqCst) {
            0 => Ok(self.text_response("Initial reusable assignment complete.")),
            1 => {
                self.validate_auxiliary_context(&request)
                    .map_err(|error| self.record_failure(error))?;
                Ok(self.denied_write_attempt())
            }
            2 => {
                self.validate_auxiliary_context(&request)
                    .map_err(|error| self.record_failure(error))?;
                let messages = serde_json::to_string(&request.context.messages).unwrap();
                if !(messages.contains("filesystem_write")
                    && (messages.contains("not available")
                        || messages.contains("not found")
                        || messages.contains("unknown")))
                {
                    return Err(self.record_failure(format!(
                        "ungranted tool call was not rejected: {messages}"
                    )));
                }
                Ok(self.text_response("Question answered without mutation."))
            }
            3 => {
                self.validate_auxiliary_context(&request)
                    .map_err(|error| self.record_failure(error))?;
                Ok(self.text_response("Offer remains pending explicit acceptance."))
            }
            call => panic!("unexpected nested auxiliary responder call {call}"),
        }
    }
}

struct AuxiliaryAuthorityResponderFactory {
    root_session_id: Arc<std::sync::Mutex<Option<String>>>,
    expected_agent_id: Arc<std::sync::Mutex<Option<String>>>,
    child_calls: Arc<AtomicUsize>,
    failure: Arc<std::sync::Mutex<Option<String>>>,
}

#[async_trait]
impl ModelResponderFactory for AuxiliaryAuthorityResponderFactory {
    async fn create_for_model(
        &self,
        _model: &str,
        _settings: &crate::domains::settings::ApiSettings,
    ) -> Result<Arc<dyn ModelResponder>, ModelResponseError> {
        Ok(Arc::new(AuxiliaryAuthorityResponder {
            root_session_id: Arc::clone(&self.root_session_id),
            expected_agent_id: Arc::clone(&self.expected_agent_id),
            child_calls: Arc::clone(&self.child_calls),
            failure: Arc::clone(&self.failure),
        }))
    }
}

fn coordination_invocation(
    function: &str,
    payload: Value,
    session_id: &str,
    workspace_id: &str,
    suffix: &str,
) -> Invocation {
    coordination_invocation_as(
        ActorKind::Agent,
        function,
        payload,
        session_id,
        workspace_id,
        suffix,
    )
}

fn coordination_invocation_as(
    actor_kind: ActorKind,
    function: &str,
    payload: Value,
    session_id: &str,
    workspace_id: &str,
    suffix: &str,
) -> Invocation {
    let causal = CausalContext::new(
        ActorId::new(format!("agent:test-{suffix}")).unwrap(),
        actor_kind,
        TraceId::new(format!("trace-agent-coordination-{suffix}")).unwrap(),
    )
    .with_session_id(session_id)
    .with_workspace_id(workspace_id)
    .with_working_directory("/tmp/project");
    let causal = payload
        .get("clientMutationId")
        .and_then(Value::as_str)
        .map_or(causal.clone(), |key| causal.with_idempotency_key(key));
    Invocation::new_sync(FunctionId::new(function).unwrap(), payload, causal)
}

fn with_assignment(
    mut invocation: Invocation,
    agent_id: &str,
    assignment_id: &str,
    execution_id: &str,
) -> Invocation {
    invocation.causal_context = invocation.causal_context.with_agent_execution(
        agent_id.to_owned(),
        assignment_id.to_owned(),
        execution_id.to_owned(),
    );
    invocation
}

async fn invoke_client_agent_operation(
    runtime: &WorkerRuntime,
    function: &str,
    payload: Value,
    session_id: &str,
    workspace_id: &str,
    suffix: &str,
) -> Value {
    let outcome = runtime
        .host
        .invoke(coordination_invocation_as(
            ActorKind::Client,
            function,
            payload,
            session_id,
            workspace_id,
            suffix,
        ))
        .await;
    assert!(
        outcome.error.is_none(),
        "{function} failed request/handler/response validation: {:?}",
        outcome.error
    );
    outcome.value.expect("native agent operation result")
}

fn transition_assignment_to_running(
    runtime: &WorkerRuntime,
    assignment_id: &str,
) -> crate::domains::worker_kernel::persistence::AgentAssignmentRecord {
    let mut assignment = runtime
        .store
        .agent_assignment(assignment_id)
        .unwrap()
        .unwrap();
    if assignment.status
        == crate::domains::worker_kernel::persistence::AgentAssignmentStatus::Accepted
    {
        assignment = runtime
            .store
            .transition_agent_assignment(
                &crate::domains::worker_kernel::persistence::AgentAssignmentTransition {
                    assignment_id: assignment.assignment_id,
                    expected_status: assignment.status,
                    target_status:
                        crate::domains::worker_kernel::persistence::AgentAssignmentStatus::Queued,
                    result: None,
                    error: None,
                },
            )
            .unwrap();
    }
    if assignment.status
        == crate::domains::worker_kernel::persistence::AgentAssignmentStatus::Queued
    {
        assignment = runtime
            .store
            .transition_agent_assignment(
                &crate::domains::worker_kernel::persistence::AgentAssignmentTransition {
                    assignment_id: assignment.assignment_id,
                    expected_status: assignment.status,
                    target_status:
                        crate::domains::worker_kernel::persistence::AgentAssignmentStatus::Running,
                    result: None,
                    error: None,
                },
            )
            .unwrap();
    }
    assert_eq!(
        assignment.status,
        crate::domains::worker_kernel::persistence::AgentAssignmentStatus::Running
    );
    assignment
}

fn assert_disabled_actions_have_reasons(document: &Value) {
    for action in document["allowedActions"].as_array().unwrap() {
        if action["enabled"] == false {
            assert!(
                action["disabledReason"]
                    .as_str()
                    .is_some_and(|reason| !reason.trim().is_empty()),
                "disabled action must explain itself: {action}"
            );
        }
    }
}

async fn spawn_test_child(runtime: &WorkerRuntime, session_id: &str, workspace_id: &str) -> Value {
    runtime
        .agent_spawn(&coordination_invocation(
            "worker_kernel::agent_spawn",
            json!({
                "task":"Inspect the durable coordination protocol.",
                "name":"Protocol reviewer",
                "tools":["agent_send","agent_wait"],
                "writeScopes":["Sources"]
            }),
            session_id,
            workspace_id,
            "spawn",
        ))
        .await
        .unwrap()
}

#[tokio::test]
async fn queued_instruction_is_passive_until_fifo_supervisor_opens_its_attempt() {
    let (runtime, _home) = test_runtime(Some(Arc::new(CoordinationResultResponderFactory)));
    let root = runtime
        .event_store
        .create_session(
            "gpt-5.6-sol",
            "/tmp/project",
            Some("FIFO assignment owner"),
            None,
        )
        .unwrap()
        .session;
    let spawned = spawn_test_child(&runtime, &root.id, &root.workspace_id).await;
    let child = runtime
        .store
        .agent_instance(spawned["agentId"].as_str().unwrap())
        .unwrap()
        .unwrap();
    let first =
        transition_assignment_to_running(&runtime, spawned["assignmentId"].as_str().unwrap());
    runtime
        .store
        .transition_agent_assignment(
            &crate::domains::worker_kernel::persistence::AgentAssignmentTransition {
                assignment_id: first.assignment_id.clone(),
                expected_status:
                    crate::domains::worker_kernel::persistence::AgentAssignmentStatus::Running,
                target_status:
                    crate::domains::worker_kernel::persistence::AgentAssignmentStatus::Waiting,
                result: None,
                error: None,
            },
        )
        .unwrap();

    let second = runtime
        .agent_send(&coordination_invocation(
            "worker_kernel::agent_send",
            json!({
                "to":child.agent_id,
                "kind":"instruction",
                "content":"Run only after the waiting assignment terminalizes."
            }),
            &root.id,
            &root.workspace_id,
            "fifo-passive-second",
        ))
        .await
        .unwrap();
    let second_id = second["assignmentId"].as_str().unwrap().to_owned();
    let message_id = second["messageId"].as_str().unwrap();
    assert!(
        runtime
            .event_store
            .agent_message_metadata(message_id)
            .unwrap()
            .is_some(),
        "queued work must persist its semantic message immediately"
    );
    let admission_delivery = runtime
        .event_store
        .list_agent_deliveries_for_session(&child.session_id, 100)
        .unwrap()
        .into_iter()
        .find(|delivery| delivery.content.contains(message_id))
        .expect("queued assignment admission delivery");
    assert_eq!(
        admission_delivery.wake_policy,
        crate::domains::session::event_store::AgentDeliveryWakePolicy::Passive,
        "assignment admission may never become a generic delivery wake"
    );
    assert!(
        runtime
            .event_store
            .pending_agent_wakes_for_session(&child.session_id, 100)
            .unwrap()
            .iter()
            .all(|delivery_id| delivery_id != &admission_delivery.delivery_id)
    );

    runtime
        .agent_send(&coordination_invocation(
            "worker_kernel::agent_send",
            json!({
                "to":child.agent_id,
                "kind":"question",
                "content":"Answer this without consuming the queued instruction."
            }),
            &root.id,
            &root.workspace_id,
            "fifo-unrelated-question",
        ))
        .await
        .unwrap();
    tokio::time::timeout(Duration::from_secs(5), async {
        while runtime.orchestrator.has_active_run(&child.session_id) {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    })
    .await
    .expect("unrelated auxiliary question did not reach a safe boundary");
    let pre_admission_rows = runtime
        .event_store
        .get_events_since(&child.session_id, 0)
        .unwrap();
    let pre_admission_payloads = runtime
        .event_store
        .resolve_event_payloads(&pre_admission_rows)
        .unwrap();
    assert!(
        pre_admission_rows
            .iter()
            .zip(pre_admission_payloads)
            .all(|(row, payload)| {
                row.event_type != EventType::MessageAgent.as_str()
                    || payload
                        .get("content")
                        .and_then(|content| content.get("messageId"))
                        .and_then(Value::as_str)
                        != Some(message_id)
            }),
        "an unrelated auxiliary turn must not lease or materialize held queued work"
    );

    let queued = runtime.store.agent_assignment(&second_id).unwrap().unwrap();
    runtime.drive_agent_assignment(queued).await.unwrap();
    assert!(
        runtime
            .store
            .list_agent_assignment_attempts(&second_id, 10)
            .unwrap()
            .is_empty(),
        "a waiting FIFO predecessor must prevent the queued assignment from opening an attempt"
    );

    runtime
        .store
        .transition_agent_assignment(
            &crate::domains::worker_kernel::persistence::AgentAssignmentTransition {
                assignment_id: first.assignment_id.clone(),
                expected_status:
                    crate::domains::worker_kernel::persistence::AgentAssignmentStatus::Waiting,
                target_status:
                    crate::domains::worker_kernel::persistence::AgentAssignmentStatus::Running,
                result: None,
                error: None,
            },
        )
        .unwrap();
    runtime
        .store
        .transition_agent_assignment(
            &crate::domains::worker_kernel::persistence::AgentAssignmentTransition {
                assignment_id: first.assignment_id,
                expected_status:
                    crate::domains::worker_kernel::persistence::AgentAssignmentStatus::Running,
                target_status:
                    crate::domains::worker_kernel::persistence::AgentAssignmentStatus::Completed,
                result: Some(json!({"done":true})),
                error: None,
            },
        )
        .unwrap();
    let queued = runtime.store.agent_assignment(&second_id).unwrap().unwrap();
    runtime.drive_agent_assignment(queued).await.unwrap();
    let completed = runtime.store.agent_assignment(&second_id).unwrap().unwrap();
    assert_eq!(
        completed.status,
        crate::domains::worker_kernel::persistence::AgentAssignmentStatus::Completed
    );
    let attempts = runtime
        .store
        .list_agent_assignment_attempts(&second_id, 10)
        .unwrap();
    assert_eq!(attempts.len(), 1);
    let rows = runtime
        .event_store
        .get_events_since(&child.session_id, 0)
        .unwrap();
    let payloads = runtime.event_store.resolve_event_payloads(&rows).unwrap();
    let message_sequences = rows
        .iter()
        .zip(payloads)
        .filter_map(|(row, payload)| {
            (row.event_type == EventType::MessageAgent.as_str()
                && payload
                    .get("content")
                    .and_then(|content| content.get("messageId"))
                    .and_then(Value::as_str)
                    == Some(message_id))
            .then_some(row.sequence)
        })
        .collect::<Vec<_>>();
    assert_eq!(
        message_sequences.len(),
        1,
        "the supervisor wake must materialize the queued instruction exactly once"
    );
    assert!(
        message_sequences[0] > attempts[0].baseline_event_sequence,
        "the supervisor must durably open the attempt baseline before materializing the assignment message"
    );
}

#[tokio::test]
async fn target_queue_limit_controls_model_native_retry_and_team_budget() {
    let (runtime, _home) = test_runtime(None);
    let root = runtime
        .event_store
        .create_session(
            "gpt-5.6-sol",
            "/tmp/project",
            Some("Queue ceiling owner"),
            None,
        )
        .unwrap()
        .session;
    let spawned = runtime
        .agent_spawn(&coordination_invocation(
            "worker_kernel::agent_spawn",
            json!({
                "task":"Establish one terminal assignment.",
                "name":"Single-slot agent",
                "limits":{"maxQueuedAssignments":1}
            }),
            &root.id,
            &root.workspace_id,
            "queue-ceiling-spawn",
        ))
        .await
        .unwrap();
    let child = runtime
        .store
        .agent_instance(spawned["agentId"].as_str().unwrap())
        .unwrap()
        .unwrap();
    let first =
        transition_assignment_to_running(&runtime, spawned["assignmentId"].as_str().unwrap());
    runtime
        .store
        .transition_agent_assignment(
            &crate::domains::worker_kernel::persistence::AgentAssignmentTransition {
                assignment_id: first.assignment_id.clone(),
                expected_status:
                    crate::domains::worker_kernel::persistence::AgentAssignmentStatus::Running,
                target_status:
                    crate::domains::worker_kernel::persistence::AgentAssignmentStatus::Failed,
                result: None,
                error: Some("retry fixture".to_owned()),
            },
        )
        .unwrap();
    runtime
        .agent_send(&coordination_invocation(
            "worker_kernel::agent_send",
            json!({
                "to":child.agent_id,
                "kind":"instruction",
                "content":"Occupy the one configured queue slot."
            }),
            &root.id,
            &root.workspace_id,
            "queue-ceiling-first",
        ))
        .await
        .unwrap();

    let model_error = runtime
        .agent_send(&coordination_invocation(
            "worker_kernel::agent_send",
            json!({
                "to":child.agent_id,
                "kind":"instruction",
                "content":"This must exceed the target's effective queue limit."
            }),
            &root.id,
            &root.workspace_id,
            "queue-ceiling-model-overflow",
        ))
        .await
        .unwrap_err();
    assert!(model_error.contains("queue ceiling (1) reached"));

    let team = runtime
        .agent_team_context(&coordination_invocation(
            "worker_kernel::agent_team_context",
            json!({"sessionId":child.session_id}),
            &child.session_id,
            &child.workspace_id,
            "queue-ceiling-team-context",
        ))
        .await
        .unwrap();
    assert_eq!(team["budgets"]["queuedAssignments"], 1);
    assert_eq!(team["budgets"]["remainingQueuedAssignments"], 0);

    let native_error = runtime
        .client_agent_retry(&coordination_invocation_as(
            ActorKind::Client,
            "agent::retry",
            json!({
                "ownerSessionId":root.id,
                "agentId":child.agent_id,
                "assignmentId":first.assignment_id,
                "clientMutationId":"queue-ceiling-native-retry"
            }),
            &root.id,
            &root.workspace_id,
            "queue-ceiling-native-overflow",
        ))
        .await
        .unwrap_err();
    assert!(native_error.contains("queue ceiling (1) reached"));
}

#[tokio::test]
async fn root_spawn_inherits_the_current_session_model_after_identity_creation() {
    let (runtime, _home) = test_runtime(None);
    let root = runtime
        .event_store
        .create_session(
            "gpt-5.6-sol",
            "/tmp/project",
            Some("Current-model owner"),
            None,
        )
        .unwrap()
        .session;
    let (root_agent, _) = runtime
        .ensure_agent_identity_for_session(&root.id)
        .await
        .unwrap();
    assert_eq!(root_agent.default_model.as_deref(), Some("gpt-5.6-sol"));
    runtime
        .event_store
        .update_latest_model(&root.id, "gpt-5.6-terra")
        .unwrap();

    let spawned = runtime
        .agent_spawn(&coordination_invocation(
            "worker_kernel::agent_spawn",
            json!({"task":"Inherit the model of this root turn."}),
            &root.id,
            &root.workspace_id,
            "current-model-spawn",
        ))
        .await
        .unwrap();
    let child = runtime
        .store
        .agent_instance(spawned["agentId"].as_str().unwrap())
        .unwrap()
        .unwrap();
    let assignment = runtime
        .store
        .agent_assignment(spawned["assignmentId"].as_str().unwrap())
        .unwrap()
        .unwrap();
    assert_eq!(child.default_model.as_deref(), Some("gpt-5.6-terra"));
    assert_eq!(assignment.model.as_deref(), Some("gpt-5.6-terra"));
}

#[tokio::test]
async fn reusable_agent_spawn_is_idempotent_and_provisions_one_hidden_transcript() {
    let (runtime, _home) = test_runtime(None);
    let session = runtime
        .event_store
        .create_session(
            "gpt-5.6-sol",
            "/tmp/project",
            Some("Coordination owner"),
            None,
        )
        .unwrap()
        .session;

    let spawn = coordination_invocation(
        "worker_kernel::agent_spawn",
        json!({
            "task":"Inspect the durable coordination protocol.",
            "name":"Protocol reviewer",
            "tools":["agent_send","agent_wait"],
            "writeScopes":["Sources"]
        }),
        &session.id,
        &session.workspace_id,
        "idempotent-spawn",
    );
    let first = runtime.agent_spawn(&spawn).await.unwrap();
    let replay = runtime.agent_spawn(&spawn).await.unwrap();
    assert_eq!(first["agentId"], replay["agentId"]);
    assert_eq!(first["assignmentId"], replay["assignmentId"]);
    assert_eq!(first["executionId"], replay["executionId"]);

    let child = runtime
        .store
        .agent_instance(first["agentId"].as_str().unwrap())
        .unwrap()
        .unwrap();
    let transcript = runtime
        .event_store
        .get_session(&child.session_id)
        .unwrap()
        .unwrap();
    assert!(transcript.is_agent_session());
    assert_eq!(child.root_session_id, session.id);
    assert_eq!(child.write_scopes, json!(["Sources"]));
    assert_eq!(
        runtime
            .store
            .agent_instance_directory_page(false, &[], "", 0, 20)
            .unwrap()
            .total,
        2
    );
}

#[tokio::test]
async fn general_agent_defaults_to_inheritable_tools_but_accepts_explicit_delegable_tools() {
    let (runtime, _home) = test_runtime(None);
    let session = runtime
        .event_store
        .create_session(
            "gpt-5.6-sol",
            "/tmp/project",
            Some("Coordination owner"),
            None,
        )
        .unwrap()
        .session;

    let inherited = runtime
        .agent_spawn(&coordination_invocation(
            "worker_kernel::agent_spawn",
            json!({"task":"Use the ordinary coordination surface."}),
            &session.id,
            &session.workspace_id,
            "inherited-tools",
        ))
        .await
        .unwrap();
    let inherited_tools = inherited["effectiveGrant"]["tools"].as_array().unwrap();
    assert!(inherited_tools.iter().any(|tool| tool == "agent_send"));
    assert!(
        !inherited_tools.iter().any(|tool| tool == "worker_upsert"),
        "specialist-only functions must not silently enter a general child grant"
    );

    let explicit = runtime
        .agent_spawn(&coordination_invocation(
            "worker_kernel::agent_spawn",
            json!({
                "task":"Author one reviewed worker bundle.",
                "tools":["worker_upsert"]
            }),
            &session.id,
            &session.workspace_id,
            "explicit-tools",
        ))
        .await
        .unwrap();
    assert_eq!(
        explicit["effectiveGrant"]["tools"],
        json!(["worker_upsert"])
    );
}

#[tokio::test]
async fn idle_nested_coordination_wakes_keep_identity_and_a_read_only_exact_grant() {
    let root_session_id = Arc::new(std::sync::Mutex::new(None));
    let expected_agent_id = Arc::new(std::sync::Mutex::new(None));
    let child_calls = Arc::new(AtomicUsize::new(0));
    let responder_failure = Arc::new(std::sync::Mutex::new(None));
    let (runtime, _home) = test_runtime(Some(Arc::new(AuxiliaryAuthorityResponderFactory {
        root_session_id: Arc::clone(&root_session_id),
        expected_agent_id: Arc::clone(&expected_agent_id),
        child_calls: Arc::clone(&child_calls),
        failure: Arc::clone(&responder_failure),
    })));
    let root = runtime
        .event_store
        .create_session(
            "gpt-5.6-sol",
            "/tmp/project",
            Some("Auxiliary authority owner"),
            None,
        )
        .unwrap()
        .session;
    *root_session_id.lock().unwrap() = Some(root.id.clone());

    let spawned = runtime
        .agent_spawn(&coordination_invocation(
            "worker_kernel::agent_spawn",
            json!({
                "task":"Complete one initial assignment, then remain reusable.",
                "name":"Bounded auxiliary agent",
                "tools":[
                    "agent_send",
                    "agent_manage",
                    "filesystem_read",
                    "filesystem_write",
                    "process_run"
                ],
                "writeScopes":["Sources"]
            }),
            &root.id,
            &root.workspace_id,
            "auxiliary-authority-spawn",
        ))
        .await
        .unwrap();
    let agent_id = spawned["agentId"].as_str().unwrap().to_owned();
    let assignment_id = spawned["assignmentId"].as_str().unwrap().to_owned();
    *expected_agent_id.lock().unwrap() = Some(agent_id.clone());
    let initial = runtime
        .store
        .agent_assignment(&assignment_id)
        .unwrap()
        .unwrap();
    runtime.drive_agent_assignment(initial).await.unwrap();
    assert_eq!(
        runtime
            .store
            .agent_assignment(&assignment_id)
            .unwrap()
            .unwrap()
            .status,
        crate::domains::worker_kernel::persistence::AgentAssignmentStatus::Completed
    );
    let child = runtime.store.agent_instance(&agent_id).unwrap().unwrap();
    assert_eq!(
        child.state,
        crate::domains::worker_kernel::persistence::AgentInstanceState::Idle
    );

    runtime
        .agent_send(&coordination_invocation(
            "worker_kernel::agent_send",
            json!({
                "to":agent_id,
                "kind":"question",
                "content":"Can you answer without using mutation authority?"
            }),
            &root.id,
            &root.workspace_id,
            "auxiliary-authority-question",
        ))
        .await
        .unwrap();
    tokio::time::timeout(Duration::from_secs(5), async {
        while child_calls.load(Ordering::SeqCst) < 3 {
            tokio::time::sleep(Duration::from_millis(25)).await;
        }
    })
    .await
    .expect("idle question should run under the auxiliary grant");
    tokio::time::timeout(Duration::from_secs(5), async {
        while runtime.orchestrator.has_active_run(&child.session_id) {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    })
    .await
    .expect("question run should release the transcript before the offer");

    let offer = runtime
        .agent_send(&coordination_invocation(
            "worker_kernel::agent_send",
            json!({
                "to":agent_id,
                "kind":"request",
                "content":"Review this only after explicit acceptance."
            }),
            &root.id,
            &root.workspace_id,
            "auxiliary-authority-offer",
        ))
        .await
        .unwrap();
    tokio::time::timeout(Duration::from_secs(5), async {
        while child_calls.load(Ordering::SeqCst) < 4 {
            tokio::time::sleep(Duration::from_millis(25)).await;
        }
    })
    .await
    .expect("idle offer should wake one bounded auxiliary turn");
    tokio::time::sleep(Duration::from_millis(100)).await;
    let offered = runtime
        .store
        .agent_assignment(offer["assignmentId"].as_str().unwrap())
        .unwrap()
        .unwrap();
    assert_eq!(
        offered.status,
        crate::domains::worker_kernel::persistence::AgentAssignmentStatus::Offered,
        "an auxiliary offer wake must never accept or execute work implicitly"
    );
    assert_eq!(
        responder_failure.lock().unwrap().as_deref(),
        None,
        "auxiliary authority responder observed an invariant failure"
    );
}

#[tokio::test]
async fn questions_answers_and_offer_acceptance_use_durable_handles() {
    let (runtime, _home) = test_runtime(None);
    let root_session = runtime
        .event_store
        .create_session(
            "gpt-5.6-sol",
            "/tmp/project",
            Some("Coordination owner"),
            None,
        )
        .unwrap()
        .session;
    let spawned = spawn_test_child(&runtime, &root_session.id, &root_session.workspace_id).await;
    let child = runtime
        .store
        .agent_instance(spawned["agentId"].as_str().unwrap())
        .unwrap()
        .unwrap();

    let question = runtime
        .agent_send(&coordination_invocation(
            "worker_kernel::agent_send",
            json!({
                "to":child.agent_id,
                "kind":"question",
                "content":"Which invariant is most important?"
            }),
            &root_session.id,
            &root_session.workspace_id,
            "question",
        ))
        .await
        .unwrap();
    let question_id = question["messageId"].as_str().unwrap();
    assert!(
        runtime
            .event_store
            .agent_message_metadata(question_id)
            .unwrap()
            .is_some()
    );

    let answer = runtime
        .agent_send(&coordination_invocation(
            "worker_kernel::agent_send",
            json!({
                "to":"parent",
                "kind":"answer",
                "content":"Stable identity survives every restart.",
                "replyTo":question_id
            }),
            &child.session_id,
            &child.workspace_id,
            "answer",
        ))
        .await
        .unwrap();
    assert_eq!(answer["disposition"], "delivered");
    let wait_invocation = coordination_invocation(
        "worker_kernel::agent_wait",
        json!({"targets":[{"kind":"reply","id":question_id}],"mode":"all"}),
        &root_session.id,
        &root_session.workspace_id,
        "wait-after-answer",
    );
    let wait = runtime.agent_wait(&wait_invocation).await.unwrap();
    assert_eq!(wait["status"], "satisfied");
    assert_eq!(wait["completedTargets"].as_array().unwrap().len(), 1);
    let wait_replay = runtime.agent_wait(&wait_invocation).await.unwrap();
    assert_eq!(wait_replay["waitId"], wait["waitId"]);
    assert_eq!(wait_replay["status"], "satisfied");
    assert_eq!(wait_replay["completedTargets"].as_array().unwrap().len(), 1);
    assert!(
        runtime
            .event_store
            .reconcile_coordination_waits(&[])
            .unwrap()
            .is_empty(),
        "the reply returned by agent_wait must not be rediscovered as an aggregate wake"
    );

    let initial_assignment_id = spawned["assignmentId"].as_str().unwrap();
    let initial_execution_id = spawned["executionId"].as_str().unwrap();
    let initial = runtime
        .store
        .agent_assignment(initial_assignment_id)
        .unwrap()
        .unwrap();
    let running = if initial.status
        == crate::domains::worker_kernel::persistence::AgentAssignmentStatus::Running
    {
        initial
    } else {
        runtime
            .store
            .transition_agent_assignment(
                &crate::domains::worker_kernel::persistence::AgentAssignmentTransition {
                    assignment_id: initial.assignment_id,
                    expected_status: initial.status,
                    target_status:
                        crate::domains::worker_kernel::persistence::AgentAssignmentStatus::Running,
                    result: None,
                    error: None,
                },
            )
            .unwrap()
    };
    let child_question = runtime
        .agent_send(&with_assignment(
            coordination_invocation(
                "worker_kernel::agent_send",
                json!({
                    "to":"parent",
                    "kind":"question",
                    "content":"May I preserve the running assignment while waiting?",
                    "assignmentId":initial_assignment_id
                }),
                &child.session_id,
                &child.workspace_id,
                "child-question",
            ),
            &child.agent_id,
            initial_assignment_id,
            initial_execution_id,
        ))
        .await
        .unwrap();
    runtime
        .agent_send(&coordination_invocation(
            "worker_kernel::agent_send",
            json!({
                "to":child.agent_id,
                "kind":"answer",
                "content":"Yes; completion won the registration race.",
                "replyTo":child_question["messageId"]
            }),
            &root_session.id,
            &root_session.workspace_id,
            "parent-answer",
        ))
        .await
        .unwrap();
    let child_wait_invocation = with_assignment(
        coordination_invocation(
            "worker_kernel::agent_wait",
            json!({
                "targets":[{"kind":"reply","id":child_question["messageId"]}],
                "mode":"all"
            }),
            &child.session_id,
            &child.workspace_id,
            "child-wait-after-answer",
        ),
        &child.agent_id,
        initial_assignment_id,
        initial_execution_id,
    );
    let child_wait = runtime.agent_wait(&child_wait_invocation).await.unwrap();
    let child_wait_replay = runtime.agent_wait(&child_wait_invocation).await.unwrap();
    assert_eq!(child_wait["status"], "satisfied");
    assert_eq!(child_wait_replay["status"], "satisfied");
    assert_eq!(
        runtime
            .store
            .agent_assignment(initial_assignment_id)
            .unwrap()
            .unwrap()
            .status,
        running.status,
        "a satisfied wait replay must never re-park its assignment"
    );

    let offer_invocation = coordination_invocation(
        "worker_kernel::agent_send",
        json!({
            "to":child.agent_id,
            "kind":"request",
            "content":"Review one more invariant."
        }),
        &root_session.id,
        &root_session.workspace_id,
        "offer",
    );
    let offer = runtime.agent_send(&offer_invocation).await.unwrap();
    let offer_replay = runtime.agent_send(&offer_invocation).await.unwrap();
    assert_eq!(offer["disposition"], "offered");
    assert_eq!(offer_replay["messageId"], offer["messageId"]);
    assert_eq!(offer_replay["assignmentId"], offer["assignmentId"]);
    let child_team = runtime
        .agent_team_context(&coordination_invocation(
            "worker_kernel::agent_team_context",
            json!({"sessionId":child.session_id.clone()}),
            &child.session_id,
            &child.workspace_id,
            "running-objective-before-offer",
        ))
        .await
        .unwrap();
    assert_eq!(
        child_team["activeAssignment"]["assignmentId"], initial_assignment_id,
        "a peer offer must not replace the running owner objective in trusted Team Context"
    );
    let child_inspect = invoke_client_agent_operation(
        &runtime,
        "agent::inspect",
        json!({"ownerSessionId":root_session.id,"agentId":child.agent_id}),
        &root_session.id,
        &root_session.workspace_id,
        "running-objective-client-inspect",
    )
    .await;
    assert_eq!(
        child_inspect["currentAssignment"]["assignmentId"],
        initial_assignment_id
    );
    let accepted = runtime
        .agent_manage(&coordination_invocation(
            "worker_kernel::agent_manage",
            json!({
                "action":"respond_to_offer",
                "assignmentId":offer["assignmentId"],
                "response":"accept"
            }),
            &child.session_id,
            &child.workspace_id,
            "accept-offer",
        ))
        .await
        .unwrap();
    assert_eq!(accepted["status"], "queued");
}

#[tokio::test]
async fn runtime_wait_topology_rejects_self_and_ancestor_but_allows_parent_descendant() {
    let (runtime, _home) = test_runtime(None);
    let root = runtime
        .event_store
        .create_session("gpt-5.6-sol", "/tmp/project", Some("Wait topology"), None)
        .unwrap()
        .session;
    let child_spawn = spawn_test_child(&runtime, &root.id, &root.workspace_id).await;
    let child = runtime
        .store
        .agent_instance(child_spawn["agentId"].as_str().unwrap())
        .unwrap()
        .unwrap();
    let child_assignment_id = child_spawn["assignmentId"].as_str().unwrap().to_owned();
    let child_execution_id = child_spawn["executionId"].as_str().unwrap().to_owned();
    transition_assignment_to_running(&runtime, &child_assignment_id);

    let self_cycle = runtime
        .agent_wait(&with_assignment(
            coordination_invocation(
                "worker_kernel::agent_wait",
                json!({
                    "targets":[{"kind":"assignment","id":child_assignment_id}],
                    "mode":"all"
                }),
                &child.session_id,
                &child.workspace_id,
                "wait-topology-self",
            ),
            &child.agent_id,
            &child_assignment_id,
            &child_execution_id,
        ))
        .await
        .unwrap_err();
    assert!(self_cycle.contains("AGENT_WAIT_CYCLE"));

    let child_execution = runtime
        .store
        .execution_node(&child_execution_id)
        .unwrap()
        .unwrap();
    let mut grandchild_spawn_invocation = with_assignment(
        coordination_invocation(
            "worker_kernel::agent_spawn",
            json!({
                "task":"Exercise one exact descendant wait dependency.",
                "name":"Wait descendant",
                "tools":["agent_wait"]
            }),
            &child.session_id,
            &child.workspace_id,
            "wait-topology-grandchild",
        ),
        &child.agent_id,
        &child_assignment_id,
        &child_execution_id,
    );
    grandchild_spawn_invocation.causal_context.trace_id =
        TraceId::new(child_execution.trace_id.clone()).unwrap();
    grandchild_spawn_invocation.causal_context = grandchild_spawn_invocation
        .causal_context
        .with_trigger_depth(child_execution.causal_depth.saturating_add(1));
    let grandchild_spawn = runtime
        .agent_spawn(&grandchild_spawn_invocation)
        .await
        .unwrap();
    let grandchild = runtime
        .store
        .agent_instance(grandchild_spawn["agentId"].as_str().unwrap())
        .unwrap()
        .unwrap();
    let grandchild_assignment_id = grandchild_spawn["assignmentId"]
        .as_str()
        .unwrap()
        .to_owned();
    let grandchild_execution_id = grandchild_spawn["executionId"].as_str().unwrap().to_owned();

    let legal = runtime
        .agent_wait(&with_assignment(
            coordination_invocation(
                "worker_kernel::agent_wait",
                json!({
                    "targets":[{"kind":"assignment","id":grandchild_assignment_id}],
                    "mode":"all"
                }),
                &child.session_id,
                &child.workspace_id,
                "wait-topology-parent-descendant",
            ),
            &child.agent_id,
            &child_assignment_id,
            &child_execution_id,
        ))
        .await
        .unwrap();
    assert_eq!(legal["status"], "pending");

    runtime
        .agent_manage(&coordination_invocation(
            "worker_kernel::agent_manage",
            json!({
                "action":"grant_management",
                "agentId":child.agent_id,
                "toAgentId":grandchild.agent_id,
                "capabilities":["assign"]
            }),
            &root.id,
            &root.workspace_id,
            "wait-topology-grant",
        ))
        .await
        .unwrap();
    let ancestor_cycle = runtime
        .agent_wait(&with_assignment(
            coordination_invocation(
                "worker_kernel::agent_wait",
                json!({
                    "targets":[{"kind":"assignment","id":child_assignment_id}],
                    "mode":"all"
                }),
                &grandchild.session_id,
                &grandchild.workspace_id,
                "wait-topology-descendant-parent",
            ),
            &grandchild.agent_id,
            &grandchild_assignment_id,
            &grandchild_execution_id,
        ))
        .await
        .unwrap_err();
    assert!(ancestor_cycle.contains("AGENT_WAIT_CYCLE"));
}

#[tokio::test]
async fn runtime_wait_topology_rejects_mutual_reply_dependencies() {
    let (runtime, _home) = test_runtime(None);
    let root = runtime
        .event_store
        .create_session("gpt-5.6-sol", "/tmp/project", Some("Reply cycle"), None)
        .unwrap()
        .session;
    let child_spawn = spawn_test_child(&runtime, &root.id, &root.workspace_id).await;
    let child = runtime
        .store
        .agent_instance(child_spawn["agentId"].as_str().unwrap())
        .unwrap()
        .unwrap();
    let child_assignment_id = child_spawn["assignmentId"].as_str().unwrap().to_owned();
    let child_execution_id = child_spawn["executionId"].as_str().unwrap().to_owned();
    transition_assignment_to_running(&runtime, &child_assignment_id);

    let root_question = runtime
        .agent_send(&coordination_invocation(
            "worker_kernel::agent_send",
            json!({
                "to":child.agent_id,
                "kind":"question",
                "content":"Can the child answer this root question?"
            }),
            &root.id,
            &root.workspace_id,
            "reply-cycle-root-question",
        ))
        .await
        .unwrap();
    let child_question = runtime
        .agent_send(&with_assignment(
            coordination_invocation(
                "worker_kernel::agent_send",
                json!({
                    "to":"parent",
                    "kind":"question",
                    "content":"Can the root answer this child question?"
                }),
                &child.session_id,
                &child.workspace_id,
                "reply-cycle-child-question",
            ),
            &child.agent_id,
            &child_assignment_id,
            &child_execution_id,
        ))
        .await
        .unwrap();
    let root_wait = runtime
        .agent_wait(&coordination_invocation(
            "worker_kernel::agent_wait",
            json!({
                "targets":[{"kind":"reply","id":root_question["messageId"]}],
                "mode":"all"
            }),
            &root.id,
            &root.workspace_id,
            "reply-cycle-root-wait",
        ))
        .await
        .unwrap();
    assert_eq!(root_wait["status"], "pending");

    let cycle = runtime
        .agent_wait(&with_assignment(
            coordination_invocation(
                "worker_kernel::agent_wait",
                json!({
                    "targets":[{"kind":"reply","id":child_question["messageId"]}],
                    "mode":"all"
                }),
                &child.session_id,
                &child.workspace_id,
                "reply-cycle-child-wait",
            ),
            &child.agent_id,
            &child_assignment_id,
            &child_execution_id,
        ))
        .await
        .unwrap_err();
    assert!(cycle.contains("AGENT_WAIT_CYCLE"));
}

#[tokio::test]
async fn runtime_wait_topology_preserves_mixed_parent_wait_and_rejects_descendant_back_edge() {
    let (runtime, _home) = test_runtime(None);
    let root = runtime
        .event_store
        .create_session(
            "gpt-5.6-sol",
            "/tmp/project",
            Some("Mixed wait topology"),
            None,
        )
        .unwrap()
        .session;
    let child_spawn = runtime
        .agent_spawn(&coordination_invocation(
            "worker_kernel::agent_spawn",
            json!({
                "task":"Coordinate a mixed execution descendant.",
                "name":"Mixed parent",
                "tools":["agent_spawn","agent_wait","worker_invoke"]
            }),
            &root.id,
            &root.workspace_id,
            "mixed-wait-parent",
        ))
        .await
        .unwrap();
    let child = runtime
        .store
        .agent_instance(child_spawn["agentId"].as_str().unwrap())
        .unwrap()
        .unwrap();
    let child_assignment_id = child_spawn["assignmentId"].as_str().unwrap().to_owned();
    let child_execution_id = child_spawn["executionId"].as_str().unwrap().to_owned();
    transition_assignment_to_running(&runtime, &child_assignment_id);
    let child_execution = runtime
        .store
        .execution_node(&child_execution_id)
        .unwrap()
        .unwrap();

    let worker = runtime
        .upsert(
            command_bundle(vec!["sh".to_owned(), "-c".to_owned(), "cat".to_owned()]),
            None,
        )
        .await
        .unwrap();
    let worker_invocation = runtime
        .enqueue_from_provider_tool(
            InvokeRequest {
                worker_id: worker.worker.worker_id,
                input: json!({}),
                idempotency_key: "mixed-wait-worker".to_owned(),
                trace_id: child_execution.trace_id.clone(),
                causal_depth: child_execution.causal_depth.saturating_add(1),
                trigger_kind: "manual".to_owned(),
                origin_session_id: Some(child.session_id.clone()),
                model: None,
                reasoning_level: None,
            },
            Some("provider-mixed-wait-worker"),
            None,
            Some(&child_execution_id),
            Some(0),
        )
        .unwrap();

    // Admit one agent execution below the worker so the reverse dependency
    // crosses both target kinds. This uses the exact engine context a nested
    // agent-runner turn would carry; no raw session inference participates.
    let mut descendant_spawn_invocation = coordination_invocation(
        "worker_kernel::agent_spawn",
        json!({
            "task":"Represent the agent-scheduled descendant of mixed worker work.",
            "name":"Mixed descendant",
            "tools":["agent_wait"]
        }),
        &child.session_id,
        &child.workspace_id,
        "mixed-wait-descendant",
    );
    descendant_spawn_invocation.causal_context.trace_id =
        TraceId::new(child_execution.trace_id.clone()).unwrap();
    descendant_spawn_invocation.causal_context = descendant_spawn_invocation
        .causal_context
        .with_agent_identity(child.agent_id.clone())
        .with_origin_worker_invocation_id(worker_invocation.invocation_id.clone())
        .with_trigger_depth(worker_invocation.causal_depth.saturating_add(1));
    let descendant_spawn = runtime
        .agent_spawn(&descendant_spawn_invocation)
        .await
        .unwrap();
    let descendant = runtime
        .store
        .agent_instance(descendant_spawn["agentId"].as_str().unwrap())
        .unwrap()
        .unwrap();
    let descendant_assignment_id = descendant_spawn["assignmentId"]
        .as_str()
        .unwrap()
        .to_owned();
    let descendant_execution_id = descendant_spawn["executionId"].as_str().unwrap().to_owned();

    let legal = runtime
        .agent_wait(&with_assignment(
            coordination_invocation(
                "worker_kernel::agent_wait",
                json!({
                    "targets":[{
                        "kind":"worker_invocation",
                        "id":worker_invocation.invocation_id
                    }],
                    "mode":"all"
                }),
                &child.session_id,
                &child.workspace_id,
                "mixed-wait-parent-worker",
            ),
            &child.agent_id,
            &child_assignment_id,
            &child_execution_id,
        ))
        .await
        .unwrap();
    assert_eq!(legal["status"], "pending");

    runtime
        .agent_manage(&coordination_invocation(
            "worker_kernel::agent_manage",
            json!({
                "action":"grant_management",
                "agentId":child.agent_id,
                "toAgentId":descendant.agent_id,
                "capabilities":["assign"]
            }),
            &root.id,
            &root.workspace_id,
            "mixed-wait-grant",
        ))
        .await
        .unwrap();
    let cycle = runtime
        .agent_wait(&with_assignment(
            coordination_invocation(
                "worker_kernel::agent_wait",
                json!({
                    "targets":[{"kind":"assignment","id":child_assignment_id}],
                    "mode":"all"
                }),
                &descendant.session_id,
                &descendant.workspace_id,
                "mixed-wait-descendant-parent",
            ),
            &descendant.agent_id,
            &descendant_assignment_id,
            &descendant_execution_id,
        ))
        .await
        .unwrap_err();
    assert!(cycle.contains("AGENT_WAIT_CYCLE"));
}

#[tokio::test]
async fn cross_workspace_question_answer_invalidates_both_visible_roots() {
    let (runtime, _home) = test_runtime(None);
    let source_session = runtime
        .event_store
        .create_session(
            "gpt-5.6-sol",
            "/tmp/cross-workspace-source",
            Some("Cross-workspace source"),
            None,
        )
        .unwrap()
        .session;
    let target_session = runtime
        .event_store
        .create_session(
            "gpt-5.6-sol",
            "/tmp/cross-workspace-target",
            Some("Cross-workspace target"),
            None,
        )
        .unwrap()
        .session;
    assert_ne!(source_session.workspace_id, target_session.workspace_id);
    let (source, _) = runtime
        .ensure_agent_identity_for_session(&source_session.id)
        .await
        .unwrap();
    let (target, _) = runtime
        .ensure_agent_identity_for_session(&target_session.id)
        .await
        .unwrap();

    let question = runtime
        .agent_send(&coordination_invocation(
            "worker_kernel::agent_send",
            json!({
                "to":target.agent_id,
                "kind":"question",
                "content":"Can your workspace validate the shared protocol?"
            }),
            &source_session.id,
            &source_session.workspace_id,
            "cross-workspace-question",
        ))
        .await
        .unwrap();
    let answer = runtime
        .agent_send(&coordination_invocation(
            "worker_kernel::agent_send",
            json!({
                "to":source.agent_id,
                "kind":"answer",
                "content":"Yes; no filesystem or tool authority crossed with the message.",
                "replyTo":question["messageId"]
            }),
            &target_session.id,
            &target_session.workspace_id,
            "cross-workspace-answer",
        ))
        .await
        .unwrap();

    let events = runtime
        .host
        .poll_stream_topic(
            "agent.message",
            StreamCursor(0),
            100,
            &StreamActorScope::all(),
        )
        .await
        .unwrap();
    let invalidated_roots = events
        .events
        .iter()
        .filter(|event| event.payload["messageId"] == answer["messageId"])
        .filter_map(|event| event.session_id.clone())
        .collect::<BTreeSet<_>>();
    assert_eq!(
        invalidated_roots,
        BTreeSet::from([source_session.id.clone(), target_session.id.clone()])
    );
    let answer_metadata = runtime
        .event_store
        .agent_message_metadata(answer["messageId"].as_str().unwrap())
        .unwrap()
        .unwrap();
    assert_eq!(answer_metadata.source_agent_id, target.agent_id);
    assert_eq!(answer_metadata.target_agent_id, source.agent_id);
    assert_eq!(
        answer_metadata.content.reply_to.as_deref(),
        question["messageId"].as_str()
    );
}

#[tokio::test]
async fn asynchronously_satisfied_wait_emits_one_aggregate_message_across_replay() {
    let (runtime, _home) = test_runtime(None);
    let root = runtime
        .event_store
        .create_session("gpt-5.6-sol", "/tmp/project", Some("Wait owner"), None)
        .unwrap()
        .session;
    let spawned = spawn_test_child(&runtime, &root.id, &root.workspace_id).await;
    let child = runtime
        .store
        .agent_instance(spawned["agentId"].as_str().unwrap())
        .unwrap()
        .unwrap();

    let first_question = runtime
        .agent_send(&coordination_invocation(
            "worker_kernel::agent_send",
            json!({
                "to":child.agent_id,
                "kind":"question",
                "content":"Which result path owns this continuation?"
            }),
            &root.id,
            &root.workspace_id,
            "async-wait-question",
        ))
        .await
        .unwrap();
    let second_question = runtime
        .agent_send(&coordination_invocation(
            "worker_kernel::agent_send",
            json!({
                "to":child.agent_id,
                "kind":"question",
                "content":"Which causal trace owns the aggregate?"
            }),
            &root.id,
            &root.workspace_id,
            "async-wait-question-second-trace",
        ))
        .await
        .unwrap();
    let mut wait_invocation = coordination_invocation(
        "worker_kernel::agent_wait",
        json!({
            "targets":[
                {"kind":"reply","id":first_question["messageId"]},
                {"kind":"reply","id":second_question["messageId"]}
            ],
            "mode":"all"
        }),
        &root.id,
        &root.workspace_id,
        "async-all-wait-register",
    );
    wait_invocation.causal_context = wait_invocation.causal_context.with_autonomous_wake_hop(6);
    let wait_trace = wait_invocation.causal_context.trace_id.as_str().to_owned();
    let wait = runtime.agent_wait(&wait_invocation).await.unwrap();
    assert_eq!(wait["status"], "pending");

    runtime
        .agent_send(&coordination_invocation(
            "worker_kernel::agent_send",
            json!({
                "to":"parent",
                "kind":"answer",
                "content":"The aggregate continuation owns it after all members resolve.",
                "replyTo":first_question["messageId"]
            }),
            &child.session_id,
            &child.workspace_id,
            "async-wait-answer-first-target-trace",
        ))
        .await
        .unwrap();
    assert!(
        runtime
            .event_store
            .list_agent_messages_for_participant(
                runtime
                    .store
                    .agent_instance_for_session(&root.id)
                    .unwrap()
                    .unwrap()
                    .agent_id
                    .as_str(),
                None,
                50,
            )
            .unwrap()
            .iter()
            .all(|message| {
                message.kind != crate::shared::protocol::messages::AgentMessageKind::Result
                    || !message
                        .content
                        .text
                        .contains(wait["waitId"].as_str().unwrap())
            })
    );
    runtime
        .agent_send(&coordination_invocation(
            "worker_kernel::agent_send",
            json!({
                "to":"parent",
                "kind":"answer",
                "content":"The registering wait trace owns it.",
                "replyTo":second_question["messageId"]
            }),
            &child.session_id,
            &child.workspace_id,
            "async-wait-answer-second-target-trace",
        ))
        .await
        .unwrap();
    runtime.import_agent_coordination_outbox().await.unwrap();
    runtime.import_agent_coordination_outbox().await.unwrap();

    let aggregate_messages = runtime
        .event_store
        .list_agent_messages_for_participant(
            runtime
                .store
                .agent_instance_for_session(&root.id)
                .unwrap()
                .unwrap()
                .agent_id
                .as_str(),
            None,
            50,
        )
        .unwrap()
        .into_iter()
        .filter(|message| {
            message.kind == crate::shared::protocol::messages::AgentMessageKind::Result
                && message
                    .content
                    .text
                    .contains(wait["waitId"].as_str().unwrap())
        })
        .collect::<Vec<_>>();
    assert_eq!(
        aggregate_messages.len(),
        1,
        "replayed result import must retain exactly one aggregate continuation"
    );
    assert_eq!(aggregate_messages[0].trace_id, wait_trace);
    assert_eq!(aggregate_messages[0].autonomous_hop, 7);
    assert!(
        runtime
            .event_store
            .reconcile_coordination_waits(&[])
            .unwrap()
            .is_empty()
    );
}

#[tokio::test]
async fn assignment_wait_resolution_defers_to_auxiliary_run_then_resumes_from_new_baseline() {
    let (runtime, _home) = test_runtime(Some(Arc::new(CoordinationResultResponderFactory)));
    let root = runtime
        .event_store
        .create_session(
            "gpt-5.6-sol",
            "/tmp/project",
            Some("Assignment wait owner"),
            None,
        )
        .unwrap()
        .session;
    let spawned = spawn_test_child(&runtime, &root.id, &root.workspace_id).await;
    let child = runtime
        .store
        .agent_instance(spawned["agentId"].as_str().unwrap())
        .unwrap()
        .unwrap();
    let assignment_id = spawned["assignmentId"].as_str().unwrap().to_owned();
    let execution_id = spawned["executionId"].as_str().unwrap().to_owned();
    transition_assignment_to_running(&runtime, &assignment_id);
    runtime
        .store
        .begin_agent_assignment_attempt(&assignment_id, Some("run-before-wait"), 0)
        .unwrap();

    let question = runtime
        .agent_send(&with_assignment(
            coordination_invocation(
                "worker_kernel::agent_send",
                json!({
                    "to":"parent",
                    "kind":"question",
                    "content":"Resolve this only while an auxiliary run is active.",
                    "assignmentId":assignment_id
                }),
                &child.session_id,
                &child.workspace_id,
                "assignment-wait-question",
            ),
            &child.agent_id,
            &assignment_id,
            &execution_id,
        ))
        .await
        .unwrap();
    let mut wait_invocation = with_assignment(
        coordination_invocation(
            "worker_kernel::agent_wait",
            json!({
                "targets":[{"kind":"reply","id":question["messageId"]}],
                "mode":"all"
            }),
            &child.session_id,
            &child.workspace_id,
            "assignment-wait-register",
        ),
        &child.agent_id,
        &assignment_id,
        &execution_id,
    );
    wait_invocation.causal_context = wait_invocation.causal_context.with_autonomous_wake_hop(4);
    let wait_trace = wait_invocation.causal_context.trace_id.as_str().to_owned();
    let wait = runtime.agent_wait(&wait_invocation).await.unwrap();
    assert_eq!(wait["status"], "pending");
    runtime
        .store
        .finish_agent_assignment_attempt(
            &runtime
                .store
                .list_agent_assignment_attempts(&assignment_id, 1)
                .unwrap()[0]
                .attempt_id,
            "waiting",
            None,
        )
        .unwrap();

    tokio::time::timeout(Duration::from_secs(5), async {
        while runtime.orchestrator.has_active_run(&child.session_id) {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    })
    .await
    .expect("setup delivery run did not reach its safe boundary");
    let auxiliary_run = runtime
        .orchestrator
        .begin_run(&child.session_id, "auxiliary-operator-run")
        .unwrap();
    let resolutions = runtime
        .event_store
        .reconcile_coordination_waits(&[CoordinationTerminalEvidence {
            target: CoordinationWaitTarget {
                kind: CoordinationTargetKind::Reply,
                id: question["messageId"].as_str().unwrap().to_owned(),
            },
            status: "answered".to_owned(),
            evidence_reference: json!({"messageId":"auxiliary-answer"}),
        }])
        .unwrap();
    runtime
        .deliver_coordination_wait_resolutions(resolutions, None)
        .await
        .unwrap();
    let aggregate = runtime
        .event_store
        .list_agent_messages_for_participant(&child.agent_id, None, 50)
        .unwrap()
        .into_iter()
        .find(|message| {
            message.kind == crate::shared::protocol::messages::AgentMessageKind::Result
                && message
                    .content
                    .text
                    .contains(wait["waitId"].as_str().unwrap())
        })
        .expect("assignment wait aggregate message");
    assert_eq!(aggregate.trace_id, wait_trace);
    assert_eq!(aggregate.autonomous_hop, 5);
    let aggregate_delivery = runtime
        .event_store
        .list_agent_deliveries_for_session(&child.session_id, 100)
        .unwrap()
        .into_iter()
        .find(|delivery| delivery.content.contains(&aggregate.message_id))
        .expect("aggregate delivery");
    assert_eq!(
        aggregate_delivery.wake_policy,
        crate::domains::session::event_store::AgentDeliveryWakePolicy::Passive,
        "assignment-owned aggregation must not generic-wake an auxiliary run"
    );

    let waiting = runtime
        .store
        .agent_assignment(&assignment_id)
        .unwrap()
        .unwrap();
    runtime.drive_agent_assignment(waiting).await.unwrap();
    assert_eq!(
        runtime
            .store
            .agent_assignment(&assignment_id)
            .unwrap()
            .unwrap()
            .status,
        crate::domains::worker_kernel::persistence::AgentAssignmentStatus::Waiting
    );
    assert_eq!(
        runtime
            .store
            .list_agent_assignment_attempts(&assignment_id, 10)
            .unwrap()
            .len(),
        1,
        "the auxiliary run must not open the resumed assignment attempt"
    );

    runtime
        .event_store
        .append(&AppendOptions {
            session_id: &child.session_id,
            event_type: EventType::MessageAssistant,
            payload: json!({
                "content":[{"type":"text","text":"Auxiliary operator reply."}],
                "runId":"auxiliary-operator-run"
            }),
            parent_id: None,
            sequence: None,
        })
        .unwrap();
    drop(auxiliary_run);
    let waiting = runtime
        .store
        .agent_assignment(&assignment_id)
        .unwrap()
        .unwrap();
    runtime.drive_agent_assignment(waiting).await.unwrap();
    assert_eq!(
        runtime
            .store
            .agent_assignment(&assignment_id)
            .unwrap()
            .unwrap()
            .status,
        crate::domains::worker_kernel::persistence::AgentAssignmentStatus::Completed
    );
    let attempts = runtime
        .store
        .list_agent_assignment_attempts(&assignment_id, 10)
        .unwrap();
    assert_eq!(attempts.len(), 2);
    assert_eq!(attempts[0].status, "completed");
    assert!(attempts[0].baseline_event_sequence > attempts[1].baseline_event_sequence);
    assert!(
        runtime
            .event_store
            .reconcile_coordination_waits(&[])
            .unwrap()
            .is_empty()
    );
    assert_eq!(
        runtime
            .event_store
            .list_agent_messages_for_participant(&child.agent_id, None, 50)
            .unwrap()
            .into_iter()
            .filter(|message| {
                message.kind == crate::shared::protocol::messages::AgentMessageKind::Result
                    && message
                        .content
                        .text
                        .contains(wait["waitId"].as_str().unwrap())
            })
            .count(),
        1
    );
}

#[tokio::test]
async fn model_and_native_agent_cancellation_cover_owned_agents_mixed_work_and_live_runs() {
    let (runtime, _home) = test_runtime(None);
    let root = runtime
        .event_store
        .create_session(
            "gpt-5.6-sol",
            "/tmp/project",
            Some("Cancellation owner"),
            None,
        )
        .unwrap()
        .session;
    let child_spawn = runtime
        .agent_spawn(&coordination_invocation(
            "worker_kernel::agent_spawn",
            json!({
                "task":"Own a reusable coordination subtree.",
                "name":"Cancellation parent",
                "tools":["agent_spawn","agent_send","agent_wait","worker_invoke"]
            }),
            &root.id,
            &root.workspace_id,
            "cancel-owned-child",
        ))
        .await
        .unwrap();
    let child = runtime
        .store
        .agent_instance(child_spawn["agentId"].as_str().unwrap())
        .unwrap()
        .unwrap();
    let child_assignment_id = child_spawn["assignmentId"].as_str().unwrap().to_owned();
    let child_execution_id = child_spawn["executionId"].as_str().unwrap().to_owned();

    let child_execution = runtime
        .store
        .execution_node(&child_execution_id)
        .unwrap()
        .unwrap();
    let mut grandchild_invocation = with_assignment(
        coordination_invocation(
            "worker_kernel::agent_spawn",
            json!({
                "task":"Establish a durable descendant identity.",
                "name":"Cancellation descendant",
                "tools":["agent_send","agent_wait"]
            }),
            &child.session_id,
            &child.workspace_id,
            "cancel-owned-grandchild",
        ),
        &child.agent_id,
        &child_assignment_id,
        &child_execution_id,
    );
    grandchild_invocation.causal_context.trace_id =
        TraceId::new(child_execution.trace_id.clone()).unwrap();
    grandchild_invocation.causal_context = grandchild_invocation
        .causal_context
        .with_trigger_depth(child_execution.causal_depth.saturating_add(1));
    let grandchild_spawn = runtime.agent_spawn(&grandchild_invocation).await.unwrap();
    let grandchild = runtime
        .store
        .agent_instance(grandchild_spawn["agentId"].as_str().unwrap())
        .unwrap()
        .unwrap();
    let initial_grandchild = transition_assignment_to_running(
        &runtime,
        grandchild_spawn["assignmentId"].as_str().unwrap(),
    );
    runtime
        .store
        .transition_agent_assignment(
            &crate::domains::worker_kernel::persistence::AgentAssignmentTransition {
                assignment_id: initial_grandchild.assignment_id,
                expected_status: initial_grandchild.status,
                target_status:
                    crate::domains::worker_kernel::persistence::AgentAssignmentStatus::Completed,
                result: Some(json!({"identityEstablished":true})),
                error: None,
            },
        )
        .unwrap();

    // This later assignment has no causal parent in the child's original
    // execution tree. Only the management-owned subtree query can find it.
    let independent_descendant_work = runtime
        .agent_send(&coordination_invocation(
            "worker_kernel::agent_send",
            json!({
                "to":grandchild.agent_id,
                "kind":"instruction",
                "content":"Run work on an independent coordination trace."
            }),
            &root.id,
            &root.workspace_id,
            "cancel-independent-descendant-work",
        ))
        .await
        .unwrap();
    let descendant_assignment_id = independent_descendant_work["assignmentId"]
        .as_str()
        .unwrap()
        .to_owned();
    transition_assignment_to_running(&runtime, &descendant_assignment_id);
    transition_assignment_to_running(&runtime, &child_assignment_id);
    runtime
        .store
        .begin_agent_assignment_attempt(&child_assignment_id, Some("run-child-cancel"), 0)
        .unwrap();
    runtime
        .store
        .begin_agent_assignment_attempt(&descendant_assignment_id, Some("run-descendant-cancel"), 0)
        .unwrap();

    // Register exact active transcript runs without opening a provider. The
    // cancellation tokens prove that management cancellation reaches the live
    // orchestrator sessions as well as the durable ledgers.
    let child_run = runtime
        .orchestrator
        .begin_run(&child.session_id, "run-child-cancel")
        .unwrap();
    let child_cancel = child_run.cancel_token();
    let descendant_run = runtime
        .orchestrator
        .begin_run(&grandchild.session_id, "run-descendant-cancel")
        .unwrap();
    let descendant_cancel = descendant_run.cancel_token();

    let worker = runtime
        .upsert(
            command_bundle(vec![
                "sh".to_owned(),
                "-c".to_owned(),
                "sleep 30".to_owned(),
            ]),
            None,
        )
        .await
        .unwrap();
    let mixed_worker = runtime
        .enqueue_from_provider_tool(
            InvokeRequest {
                worker_id: worker.worker.worker_id,
                input: json!({}),
                idempotency_key: "cancel-owned-mixed-worker".to_owned(),
                trace_id: child_execution.trace_id,
                causal_depth: child_execution.causal_depth.saturating_add(1),
                trigger_kind: "manual".to_owned(),
                origin_session_id: Some(root.id.clone()),
                model: None,
                reasoning_level: None,
            },
            Some("provider-cancel-owned-mixed-worker"),
            None,
            Some(&child_execution_id),
            Some(0),
        )
        .unwrap();

    let cancelled = runtime
        .agent_manage(&coordination_invocation(
            "worker_kernel::agent_manage",
            json!({
                "action":"cancel",
                "target":{"kind":"agent","id":child.agent_id}
            }),
            &root.id,
            &root.workspace_id,
            "cancel-owned-model",
        ))
        .await
        .unwrap();
    assert!(cancelled["affected"].as_u64().unwrap() >= 3);
    assert!(child_cancel.is_cancelled());
    assert!(descendant_cancel.is_cancelled());
    drop(child_run);
    drop(descendant_run);

    for assignment_id in [&child_assignment_id, &descendant_assignment_id] {
        let assignment = runtime
            .store
            .agent_assignment(assignment_id)
            .unwrap()
            .unwrap();
        assert_eq!(
            assignment.status,
            crate::domains::worker_kernel::persistence::AgentAssignmentStatus::Cancelled
        );
        assert!(
            runtime
                .store
                .list_agent_execution_events(&assignment.execution_id, None, 50)
                .unwrap()
                .iter()
                .any(|event| event.kind == "cancelled")
        );
    }
    assert_eq!(
        runtime
            .store
            .list_agent_assignment_attempts(&child_assignment_id, 1)
            .unwrap()[0]
            .status,
        "interrupted"
    );
    assert_eq!(
        runtime
            .store
            .list_agent_assignment_attempts(&descendant_assignment_id, 1)
            .unwrap()[0]
            .status,
        "interrupted"
    );
    assert_eq!(
        runtime
            .store
            .invocation(&mixed_worker.invocation_id)
            .unwrap()
            .unwrap()
            .status,
        "cancelled"
    );
    assert!(
        runtime
            .event_store
            .get_session(&child.session_id)
            .unwrap()
            .unwrap()
            .ended_at
            .is_none()
    );
    assert!(
        runtime
            .event_store
            .get_session(&grandchild.session_id)
            .unwrap()
            .unwrap()
            .ended_at
            .is_none()
    );

    // Reuse both stable agents, then exercise the authenticated native path on
    // the same ownership tree. Neither path is allowed to stop at the selected
    // row or use a presentation-page cap.
    let child_second = runtime
        .agent_send(&coordination_invocation(
            "worker_kernel::agent_send",
            json!({
                "to":child.agent_id,
                "kind":"instruction",
                "content":"Accept a second reusable assignment."
            }),
            &root.id,
            &root.workspace_id,
            "cancel-native-child-second",
        ))
        .await
        .unwrap();
    let descendant_second = runtime
        .agent_send(&coordination_invocation(
            "worker_kernel::agent_send",
            json!({
                "to":grandchild.agent_id,
                "kind":"instruction",
                "content":"Accept another independent descendant assignment."
            }),
            &root.id,
            &root.workspace_id,
            "cancel-native-descendant-second",
        ))
        .await
        .unwrap();
    let native = invoke_client_agent_operation(
        &runtime,
        "agent::manage",
        json!({
            "ownerSessionId":root.id,
            "agentId":child.agent_id,
            "clientMutationId":"cancel-owned-native",
            "action":"cancel"
        }),
        &root.id,
        &root.workspace_id,
        "cancel-owned-native",
    )
    .await;
    assert_eq!(native["agent"]["agentId"], child.agent_id);
    for assignment_id in [
        child_second["assignmentId"].as_str().unwrap(),
        descendant_second["assignmentId"].as_str().unwrap(),
    ] {
        assert_eq!(
            runtime
                .store
                .agent_assignment(assignment_id)
                .unwrap()
                .unwrap()
                .status,
            crate::domains::worker_kernel::persistence::AgentAssignmentStatus::Cancelled
        );
    }
}

#[tokio::test]
async fn deadline_maintenance_expires_offers_and_times_out_accepted_work() {
    let (runtime, _home) = test_runtime(None);
    let root = runtime
        .event_store
        .create_session("gpt-5.6-sol", "/tmp/project", Some("Deadline owner"), None)
        .unwrap()
        .session;

    let offered_child = runtime
        .agent_spawn(&coordination_invocation(
            "worker_kernel::agent_spawn",
            json!({
                "task":"Complete the first bounded assignment.",
                "name":"Offer target",
                "limits":{"maxAssignmentSeconds":1}
            }),
            &root.id,
            &root.workspace_id,
            "deadline-offer-target",
        ))
        .await
        .unwrap();
    let offered_agent = runtime
        .store
        .agent_instance(offered_child["agentId"].as_str().unwrap())
        .unwrap()
        .unwrap();
    let running =
        transition_assignment_to_running(&runtime, offered_child["assignmentId"].as_str().unwrap());
    runtime
        .store
        .transition_agent_assignment(
            &crate::domains::worker_kernel::persistence::AgentAssignmentTransition {
                assignment_id: running.assignment_id,
                expected_status:
                    crate::domains::worker_kernel::persistence::AgentAssignmentStatus::Running,
                target_status:
                    crate::domains::worker_kernel::persistence::AgentAssignmentStatus::Completed,
                result: Some(json!({"done":true})),
                error: None,
            },
        )
        .unwrap();
    let offer = runtime
        .agent_send(&coordination_invocation(
            "worker_kernel::agent_send",
            json!({
                "to":offered_agent.agent_id,
                "kind":"request",
                "content":"Accept or decline this bounded offer."
            }),
            &root.id,
            &root.workspace_id,
            "deadline-offer",
        ))
        .await
        .unwrap();
    assert_eq!(offer["disposition"], "offered");

    let timed_out_child = runtime
        .agent_spawn(&coordination_invocation(
            "worker_kernel::agent_spawn",
            json!({
                "task":"This accepted assignment must time out while queued.",
                "name":"Timeout target",
                "limits":{"maxAssignmentSeconds":1}
            }),
            &root.id,
            &root.workspace_id,
            "deadline-accepted",
        ))
        .await
        .unwrap();

    tokio::time::sleep(Duration::from_millis(1_100)).await;
    assert_eq!(runtime.expire_due_agent_assignments().await.unwrap(), 2);
    let expired = runtime
        .store
        .agent_assignment(offer["assignmentId"].as_str().unwrap())
        .unwrap()
        .unwrap();
    assert_eq!(
        expired.status,
        crate::domains::worker_kernel::persistence::AgentAssignmentStatus::Expired
    );
    let timed_out = runtime
        .store
        .agent_assignment(timed_out_child["assignmentId"].as_str().unwrap())
        .unwrap()
        .unwrap();
    assert_eq!(
        timed_out.status,
        crate::domains::worker_kernel::persistence::AgentAssignmentStatus::TimedOut
    );
    let result_assignments = runtime
        .store
        .pending_agent_outbox(50)
        .unwrap()
        .into_iter()
        .filter(|row| {
            row.kind == crate::domains::worker_kernel::persistence::AgentOutboxKind::Result
        })
        .filter_map(|row| row.assignment_id)
        .collect::<BTreeSet<_>>();
    assert!(result_assignments.contains(expired.assignment_id.as_str()));
    assert!(result_assignments.contains(timed_out.assignment_id.as_str()));
}

#[tokio::test]
async fn peer_instructions_and_management_are_denied_but_operator_input_resumes_a_paused_trace() {
    let (runtime, _home) = test_runtime(None);
    let owner = runtime
        .event_store
        .create_session("gpt-5.6-sol", "/tmp/project", Some("Owner"), None)
        .unwrap()
        .session;
    let spawned = spawn_test_child(&runtime, &owner.id, &owner.workspace_id).await;
    let child = runtime
        .store
        .agent_instance(spawned["agentId"].as_str().unwrap())
        .unwrap()
        .unwrap();
    let foreign = runtime
        .event_store
        .create_session(
            "gpt-5.6-sol",
            "/tmp/foreign-project",
            Some("Foreign peer"),
            None,
        )
        .unwrap()
        .session;

    let instruction_error = runtime
        .agent_send(&coordination_invocation(
            "worker_kernel::agent_send",
            json!({"to":child.agent_id,"kind":"instruction","content":"Override owner work."}),
            &foreign.id,
            &foreign.workspace_id,
            "unauthorized-instruction",
        ))
        .await
        .unwrap_err();
    assert!(instruction_error.contains("no assign authority"));
    let manage_error = runtime
        .agent_manage(&coordination_invocation(
            "worker_kernel::agent_manage",
            json!({"action":"close","agentId":child.agent_id}),
            &foreign.id,
            &foreign.workspace_id,
            "unauthorized-manage",
        ))
        .await
        .unwrap_err();
    assert!(manage_error.contains("no close authority"));

    let max_hops = runtime
        .settings_runtime
        .current()
        .settings
        .agent
        .coordination
        .max_autonomous_wake_hops;
    let mut over_ceiling = coordination_invocation(
        "worker_kernel::agent_send",
        json!({
            "to":"parent",
            "kind":"question",
            "content":"This evidence must persist without another autonomous wake."
        }),
        &child.session_id,
        &child.workspace_id,
        "autonomy-ceiling",
    );
    over_ceiling.causal_context = over_ceiling
        .causal_context
        .with_autonomous_wake_hop(max_hops);
    let paused = runtime.agent_send(&over_ceiling).await.unwrap();
    assert_eq!(paused["disposition"], "autonomy_paused");
    assert!(
        runtime
            .store
            .coordination_trace_is_paused(over_ceiling.causal_context.trace_id.as_str())
            .unwrap()
    );

    let assignment = runtime
        .store
        .agent_assignment(spawned["assignmentId"].as_str().unwrap())
        .unwrap()
        .unwrap();
    let execution = runtime
        .store
        .execution_node(&assignment.execution_id)
        .unwrap()
        .unwrap();
    runtime
        .store
        .pause_coordination_trace(&execution.trace_id, "test autonomous ceiling")
        .unwrap();
    assert!(
        runtime
            .store
            .coordination_trace_is_paused(&execution.trace_id)
            .unwrap()
    );
    let operator = runtime
        .agent_send(&coordination_invocation_as(
            ActorKind::Client,
            "worker_kernel::agent_send",
            json!({
                "to":child.agent_id,
                "kind":"instruction",
                "content":"Authenticated operator review."
            }),
            &owner.id,
            &owner.workspace_id,
            "operator-resume",
        ))
        .await
        .unwrap();
    assert_eq!(operator["assignmentId"], assignment.assignment_id);
    assert!(
        !runtime
            .store
            .coordination_trace_is_paused(&execution.trace_id)
            .unwrap()
    );
}

#[tokio::test]
async fn model_close_checks_waits_in_the_exact_owned_subtree_beyond_global_directory_pages() {
    let (runtime, _home) = test_runtime(None);
    let root = runtime
        .event_store
        .create_session(
            "gpt-5.6-sol",
            "/tmp/exact-close-waits",
            Some("Exact close owner"),
            None,
        )
        .unwrap()
        .session;
    let child_spawn = spawn_test_child(&runtime, &root.id, &root.workspace_id).await;
    let child = runtime
        .store
        .agent_instance(child_spawn["agentId"].as_str().unwrap())
        .unwrap()
        .unwrap();
    let child_assignment_id = child_spawn["assignmentId"].as_str().unwrap().to_owned();
    let child_execution_id = child_spawn["executionId"].as_str().unwrap().to_owned();
    let child_execution = runtime
        .store
        .execution_node(&child_execution_id)
        .unwrap()
        .unwrap();

    let mut descendant_invocation = with_assignment(
        coordination_invocation(
            "worker_kernel::agent_spawn",
            json!({
                "task":"Retain one exact descendant wait.",
                "name":"Wait holder",
                "tools":["agent_send","agent_wait"]
            }),
            &child.session_id,
            &child.workspace_id,
            "close-wait-descendant",
        ),
        &child.agent_id,
        &child_assignment_id,
        &child_execution_id,
    );
    descendant_invocation.causal_context.trace_id =
        TraceId::new(child_execution.trace_id.clone()).unwrap();
    descendant_invocation.causal_context = descendant_invocation
        .causal_context
        .with_trigger_depth(child_execution.causal_depth.saturating_add(1));
    let descendant_spawn = runtime.agent_spawn(&descendant_invocation).await.unwrap();
    let descendant = runtime
        .store
        .agent_instance(descendant_spawn["agentId"].as_str().unwrap())
        .unwrap()
        .unwrap();
    let descendant_assignment_id = descendant_spawn["assignmentId"]
        .as_str()
        .unwrap()
        .to_owned();
    let descendant_execution = runtime
        .store
        .execution_node(descendant_spawn["executionId"].as_str().unwrap())
        .unwrap()
        .unwrap();

    for assignment_id in [&descendant_assignment_id, &child_assignment_id] {
        let running = transition_assignment_to_running(&runtime, assignment_id);
        runtime
            .store
            .transition_agent_assignment(
                &crate::domains::worker_kernel::persistence::AgentAssignmentTransition {
                    assignment_id: running.assignment_id,
                    expected_status: running.status,
                    target_status:
                        crate::domains::worker_kernel::persistence::AgentAssignmentStatus::Completed,
                    result: Some(json!({"complete":true})),
                    error: None,
                },
            )
            .unwrap();
    }
    runtime
        .event_store
        .create_coordination_wait(
            &NewCoordinationWait {
                idempotency_key: "close_wait_beyond_global_page".to_owned(),
                session_id: descendant.session_id.clone(),
                owner_agent_id: descendant.agent_id.clone(),
                owner_assignment_id: Some(descendant_assignment_id),
                trace_id: descendant_execution.trace_id,
                autonomous_hop: 0,
                mode: CoordinationWaitMode::All,
                targets: vec![CoordinationWaitTarget {
                    kind: CoordinationTargetKind::Reply,
                    id: "question_close_wait_beyond_global_page".to_owned(),
                }],
                owner_dependency_id: format!("coordination_agent:{}", descendant.agent_id),
                dependencies: vec![CoordinationWaitDependency {
                    target: CoordinationWaitTarget {
                        kind: CoordinationTargetKind::Reply,
                        id: "question_close_wait_beyond_global_page".to_owned(),
                    },
                    dependency_id: "coordination_agent:unrelated_responder".to_owned(),
                }],
                dependency_edges: Vec::new(),
            },
            &[],
        )
        .unwrap();

    // The old model path searched a global, 200-row presentation page. Newer
    // unrelated roots could therefore hide this stable descendant and its
    // wait even though the native path used the exact ownership tree.
    for ordinal in 0..205_u32 {
        let unrelated = runtime
            .event_store
            .create_session(
                "gpt-5.6-sol",
                &format!("/tmp/unrelated-close-root-{ordinal}"),
                None,
                None,
            )
            .unwrap()
            .session;
        runtime
            .ensure_agent_identity_for_session(&unrelated.id)
            .await
            .unwrap();
    }

    let error = runtime
        .agent_manage(&coordination_invocation(
            "worker_kernel::agent_manage",
            json!({"action":"close","agentId":child.agent_id}),
            &root.id,
            &root.workspace_id,
            "close-must-see-exact-descendant-wait",
        ))
        .await
        .unwrap_err();
    assert!(error.contains("pending coordination wait"), "{error}");
    assert_ne!(
        runtime
            .store
            .agent_instance(&child.agent_id)
            .unwrap()
            .unwrap()
            .state,
        crate::domains::worker_kernel::persistence::AgentInstanceState::Closed
    );
}

#[tokio::test]
async fn team_context_uses_one_total_entry_budget_and_projects_real_child_work() {
    let (runtime, _home) = test_runtime(None);
    let mut role = command_bundle(vec!["true".to_owned()]);
    role.worker_id = Some("protocol-reviewer".to_owned());
    role.name = "Protocol reviewer".to_owned();
    role.runner = WorkerRunner::Agent {
        instructions: "Review the protocol.".to_owned(),
        model: None,
        reasoning_level: None,
    };
    role.agent_role = Some(WorkerAgentRole::Enabled {
        display_name: "Protocol reviewer".to_owned(),
        summary: "Reviews coordination invariants".to_owned(),
        discoverable: true,
        collaboration_instructions: "Cite exact durable evidence.".to_owned(),
        default_model: None,
        default_reasoning_level: Some("high".to_owned()),
        tool_ceiling: vec!["agent_send".to_owned()],
        limits: WorkerAgentRoleLimits::default(),
        result_mode: WorkerAgentResultMode::Schema,
    });
    role.output_schema = json!({
        "type":"object",
        "additionalProperties":false,
        "required":["finding"],
        "properties":{"finding":{"type":"string"}}
    });
    runtime.upsert(role, None).await.unwrap();
    let root_session = runtime
        .event_store
        .create_session(
            "gpt-5.6-sol",
            "/tmp/project",
            Some("Coordination owner"),
            None,
        )
        .unwrap()
        .session;
    let discovered = runtime
        .agent_discover(&coordination_invocation(
            "worker_kernel::agent_discover",
            json!({"scope":"roles"}),
            &root_session.id,
            &root_session.workspace_id,
            "discover-role",
        ))
        .await
        .unwrap();
    assert_eq!(discovered["roles"].as_array().unwrap().len(), 1);
    assert_eq!(discovered["roles"][0]["roleId"], "protocol-reviewer");
    let spawned = spawn_test_child(&runtime, &root_session.id, &root_session.workspace_id).await;

    let context = runtime
        .agent_team_context(&coordination_invocation(
            "worker_kernel::agent_team_context",
            json!({"sessionId":root_session.id,"limit":32}),
            &root_session.id,
            &root_session.workspace_id,
            "team-context",
        ))
        .await
        .unwrap();
    assert_eq!(context["children"].as_array().unwrap().len(), 1);
    assert_eq!(context["children"][0]["agentId"], spawned["agentId"]);
    assert_eq!(
        context["children"][0]["taskPreview"],
        "Inspect the durable coordination protocol."
    );

    let bounded = runtime
        .agent_team_context(&coordination_invocation(
            "worker_kernel::agent_team_context",
            json!({"sessionId":root_session.id,"limit":1}),
            &root_session.id,
            &root_session.workspace_id,
            "team-context-bounded",
        ))
        .await
        .unwrap();
    assert!(bounded["children"].as_array().unwrap().is_empty());
    assert!(bounded["unread"].as_array().unwrap().is_empty());
    assert!(bounded["resourceClaims"].as_array().unwrap().is_empty());
    assert!(bounded["overflowCount"].as_u64().unwrap() >= 1);
}

#[tokio::test]
async fn native_agent_protocol_round_trips_through_host_and_validates_every_response() {
    let (runtime, _home) = test_runtime(None);
    let root = runtime
        .event_store
        .create_session(
            "gpt-5.6-sol",
            "/tmp/project",
            Some("Native coordination owner"),
            None,
        )
        .unwrap()
        .session;
    let spawned = spawn_test_child(&runtime, &root.id, &root.workspace_id).await;
    let child = runtime
        .store
        .agent_instance(spawned["agentId"].as_str().unwrap())
        .unwrap()
        .unwrap();

    let relations = invoke_client_agent_operation(
        &runtime,
        "agent::relations",
        json!({"ownerSessionId":root.id,"limit":1}),
        &root.id,
        &root.workspace_id,
        "native-relations",
    )
    .await;
    assert_eq!(relations["items"][0]["agentId"], child.agent_id);
    let inspect = invoke_client_agent_operation(
        &runtime,
        "agent::inspect",
        json!({"ownerSessionId":root.id,"agentId":child.agent_id}),
        &root.id,
        &root.workspace_id,
        "native-inspect",
    )
    .await;
    assert_disabled_actions_have_reasons(&inspect);
    let cancel = inspect["allowedActions"]
        .as_array()
        .unwrap()
        .iter()
        .find(|action| action["action"] == "cancel")
        .unwrap();
    assert!(cancel["affectedCount"].as_u64().unwrap() >= 1);
    let assignments = invoke_client_agent_operation(
        &runtime,
        "agent::assignments",
        json!({"ownerSessionId":root.id,"agentId":child.agent_id,"limit":20}),
        &root.id,
        &root.workspace_id,
        "native-assignments",
    )
    .await;
    assert_eq!(
        assignments["items"][0]["assignmentId"],
        spawned["assignmentId"]
    );
    let messages = invoke_client_agent_operation(
        &runtime,
        "agent::messages",
        json!({"ownerSessionId":root.id,"agentId":child.agent_id,"limit":20}),
        &root.id,
        &root.workspace_id,
        "native-messages",
    )
    .await;
    let message_id = messages["items"][0]["messageId"].as_str().unwrap();
    let detail = invoke_client_agent_operation(
        &runtime,
        "agent::message_detail",
        json!({
            "ownerSessionId":root.id,
            "agentId":child.agent_id,
            "messageId":message_id
        }),
        &root.id,
        &root.workspace_id,
        "native-message-detail",
    )
    .await;
    assert!(!detail["content"].as_str().unwrap().is_empty());

    let running =
        transition_assignment_to_running(&runtime, spawned["assignmentId"].as_str().unwrap());
    let execution = runtime
        .store
        .execution_node(&running.execution_id)
        .unwrap()
        .unwrap();
    runtime
        .store
        .pause_coordination_trace(&execution.trace_id, "operator review required")
        .unwrap();
    let paused = invoke_client_agent_operation(
        &runtime,
        "agent::inspect",
        json!({"ownerSessionId":root.id,"agentId":child.agent_id}),
        &root.id,
        &root.workspace_id,
        "native-paused-inspect",
    )
    .await;
    assert_eq!(paused["status"], "autonomy_paused");
    assert_eq!(paused["statusDetail"], "operator review required");
    assert_eq!(paused["currentAssignment"]["status"], "autonomy_paused");
    assert_eq!(
        paused["technical"]["coordinationTraceState"]["reason"],
        "operator review required"
    );
    runtime
        .store
        .resume_coordination_trace(&execution.trace_id)
        .unwrap();
    let completed = runtime
        .store
        .transition_agent_assignment(
            &crate::domains::worker_kernel::persistence::AgentAssignmentTransition {
                assignment_id: running.assignment_id,
                expected_status:
                    crate::domains::worker_kernel::persistence::AgentAssignmentStatus::Running,
                target_status:
                    crate::domains::worker_kernel::persistence::AgentAssignmentStatus::Completed,
                result: Some(json!({"finding":"stable identity","evidence":[1,2,3]})),
                error: None,
            },
        )
        .unwrap();
    let result = invoke_client_agent_operation(
        &runtime,
        "agent::result_read",
        json!({
            "ownerSessionId":root.id,
            "agentId":child.agent_id,
            "resultId":completed.result_id,
            "pointer":"",
            "offset":0,
            "limit":20
        }),
        &root.id,
        &root.workspace_id,
        "native-result-read",
    )
    .await;
    assert_eq!(result["value"]["finding"], "stable identity");
    let reference = result["reference"].as_object().unwrap();
    assert_eq!(
        reference.keys().cloned().collect::<BTreeSet<_>>(),
        BTreeSet::from([
            "assignmentId".to_owned(),
            "contentSha256".to_owned(),
            "kind".to_owned(),
            "preview".to_owned(),
            "resultId".to_owned(),
            "sizeBytes".to_owned(),
        ])
    );

    let operator = invoke_client_agent_operation(
        &runtime,
        "agent::operator_message",
        json!({
            "ownerSessionId":root.id,
            "agentId":child.agent_id,
            "clientMutationId":"operator-one",
            "content":"Review the next invariant."
        }),
        &root.id,
        &root.workspace_id,
        "native-operator",
    )
    .await;
    assert_eq!(operator["agent"]["agentId"], child.agent_id);
    let cancelled = invoke_client_agent_operation(
        &runtime,
        "agent::manage",
        json!({
            "ownerSessionId":root.id,
            "agentId":child.agent_id,
            "clientMutationId":"cancel-one",
            "action":"cancel"
        }),
        &root.id,
        &root.workspace_id,
        "native-cancel",
    )
    .await;
    let cancelled_assignment = cancelled["agent"]["currentAssignment"]["assignmentId"]
        .as_str()
        .map(ToOwned::to_owned)
        .or_else(|| {
            runtime
                .store
                .list_agent_assignments(&child.agent_id, 2)
                .ok()?
                .into_iter()
                .find(|assignment| {
                    assignment.status
                        == crate::domains::worker_kernel::persistence::AgentAssignmentStatus::Cancelled
                })
                .map(|assignment| assignment.assignment_id)
        })
        .unwrap();
    let retried = invoke_client_agent_operation(
        &runtime,
        "agent::retry",
        json!({
            "ownerSessionId":root.id,
            "agentId":child.agent_id,
            "assignmentId":cancelled_assignment,
            "clientMutationId":"retry-one"
        }),
        &root.id,
        &root.workspace_id,
        "native-retry",
    )
    .await;
    assert_eq!(retried["agent"]["agentId"], child.agent_id);
    let _ = invoke_client_agent_operation(
        &runtime,
        "agent::manage",
        json!({
            "ownerSessionId":root.id,
            "agentId":child.agent_id,
            "clientMutationId":"cancel-two",
            "action":"cancel"
        }),
        &root.id,
        &root.workspace_id,
        "native-cancel-retry",
    )
    .await;
    let promoted = invoke_client_agent_operation(
        &runtime,
        "agent::promote",
        json!({
            "ownerSessionId":root.id,
            "agentId":child.agent_id,
            "clientMutationId":"promote-one"
        }),
        &root.id,
        &root.workspace_id,
        "native-promote",
    )
    .await;
    assert_eq!(promoted["agent"]["agentId"], child.agent_id);
    assert_eq!(promoted["agent"]["relationship"], "promoted_child");

    let former_parent_view = invoke_client_agent_operation(
        &runtime,
        "agent::relations",
        json!({"ownerSessionId":root.id,"limit":50}),
        &root.id,
        &root.workspace_id,
        "native-relations-after-promotion",
    )
    .await;
    let promoted_relation = former_parent_view["items"]
        .as_array()
        .unwrap()
        .iter()
        .find(|relation| relation["agentId"] == child.agent_id)
        .expect("promoted child remains visible as a durable former relationship");
    assert_eq!(promoted_relation["relationship"], "promoted_child");
    assert!(promoted_relation["parentAgentId"].is_null());

    let discovered_after_promotion = runtime
        .agent_discover(&coordination_invocation(
            "worker_kernel::agent_discover",
            json!({"scope":"agents","query":child.name.clone(),"limit":20}),
            &root.id,
            &root.workspace_id,
            "discover-promoted-child",
        ))
        .await
        .unwrap();
    let discovered_child = discovered_after_promotion["agents"]
        .as_array()
        .unwrap()
        .iter()
        .find(|entry| entry["agentId"] == child.agent_id)
        .expect("promoted agent remains discoverable");
    assert_eq!(discovered_child["relationship"], "peer");

    let promoted_team = runtime
        .agent_team_context(&coordination_invocation(
            "worker_kernel::agent_team_context",
            json!({"sessionId":child.session_id}),
            &child.session_id,
            &child.workspace_id,
            "promoted-team-context",
        ))
        .await
        .unwrap();
    assert!(promoted_team["parent"].is_null());
    let parent_send = runtime
        .agent_send(&coordination_invocation(
            "worker_kernel::agent_send",
            json!({"to":"parent","kind":"information","content":"former owner"}),
            &child.session_id,
            &child.workspace_id,
            "promoted-parent-address",
        ))
        .await
        .unwrap_err();
    assert!(parent_send.contains("do not have a parent address"));
}

#[tokio::test]
async fn relation_paging_never_emits_a_descendant_before_its_parent() {
    let (runtime, _home) = test_runtime(None);
    let root = runtime
        .event_store
        .create_session("gpt-5.6-sol", "/tmp/project", Some("Hierarchy owner"), None)
        .unwrap()
        .session;
    let parent_spawn = runtime
        .agent_spawn(&coordination_invocation(
            "worker_kernel::agent_spawn",
            json!({"task":"Own a nested review branch.","name":"Parent"}),
            &root.id,
            &root.workspace_id,
            "hierarchy-parent",
        ))
        .await
        .unwrap();
    let parent = runtime
        .store
        .agent_instance(parent_spawn["agentId"].as_str().unwrap())
        .unwrap()
        .unwrap();
    let running =
        transition_assignment_to_running(&runtime, parent_spawn["assignmentId"].as_str().unwrap());
    runtime
        .store
        .transition_agent_assignment(
            &crate::domains::worker_kernel::persistence::AgentAssignmentTransition {
                assignment_id: running.assignment_id,
                expected_status:
                    crate::domains::worker_kernel::persistence::AgentAssignmentStatus::Running,
                target_status:
                    crate::domains::worker_kernel::persistence::AgentAssignmentStatus::Completed,
                result: Some(json!({"done":true})),
                error: None,
            },
        )
        .unwrap();
    let descendant = runtime
        .agent_spawn(&coordination_invocation(
            "worker_kernel::agent_spawn",
            json!({"task":"Remain active beneath an idle parent.","name":"Descendant"}),
            &parent.session_id,
            &parent.workspace_id,
            "hierarchy-descendant",
        ))
        .await
        .unwrap();

    let first = invoke_client_agent_operation(
        &runtime,
        "agent::relations",
        json!({"ownerSessionId":root.id,"limit":1}),
        &root.id,
        &root.workspace_id,
        "hierarchy-page-one",
    )
    .await;
    assert_eq!(first["items"][0]["agentId"], parent.agent_id);
    let second = invoke_client_agent_operation(
        &runtime,
        "agent::relations",
        json!({
            "ownerSessionId":root.id,
            "limit":1,
            "cursor":first["nextCursor"]
        }),
        &root.id,
        &root.workspace_id,
        "hierarchy-page-two",
    )
    .await;
    assert_eq!(second["items"][0]["agentId"], descendant["agentId"]);
}

#[tokio::test]
async fn assignment_usage_follows_exact_identity_across_interleaved_work() {
    let (runtime, _home) = test_runtime(None);
    let root = runtime
        .event_store
        .create_session("gpt-5.6-sol", "/tmp/project", Some("Usage owner"), None)
        .unwrap()
        .session;
    let spawned = runtime
        .agent_spawn(&coordination_invocation(
            "worker_kernel::agent_spawn",
            json!({"task":"Complete the first analysis.","name":"Usage child"}),
            &root.id,
            &root.workspace_id,
            "usage-first",
        ))
        .await
        .unwrap();
    let child = runtime
        .store
        .agent_instance(spawned["agentId"].as_str().unwrap())
        .unwrap()
        .unwrap();
    let first_assignment = spawned["assignmentId"].as_str().unwrap().to_owned();
    let second = runtime
        .agent_send(&coordination_invocation(
            "worker_kernel::agent_send",
            json!({
                "to":child.agent_id,
                "kind":"instruction",
                "content":"Queue a second analysis while the first is still active."
            }),
            &root.id,
            &root.workspace_id,
            "usage-second",
        ))
        .await
        .unwrap();
    let second_assignment = second["assignmentId"].as_str().unwrap().to_owned();

    for (assignment_id, input, output, cache_read, cache_creation, cost, latency) in [
        (&first_assignment, 10, 2, 3, 4, 0.1, 5),
        (&second_assignment, 20, 3, 5, 6, 0.2, 7),
        (&first_assignment, 30, 4, 7, 8, 0.3, 11),
    ] {
        runtime
            .event_store
            .append(&AppendOptions {
                session_id: &child.session_id,
                event_type: EventType::StreamTurnEnd,
                payload: json!({
                    "agentAssignmentId":assignment_id,
                    "tokenUsage":{
                        "inputTokens":input,
                        "outputTokens":output,
                        "cacheReadTokens":cache_read,
                        "cacheCreationTokens":cache_creation,
                    },
                    "cost":cost,
                    "latency":latency,
                }),
                parent_id: None,
                sequence: None,
            })
            .unwrap();
    }

    let history = invoke_client_agent_operation(
        &runtime,
        "agent::assignments",
        json!({
            "ownerSessionId":root.id,
            "agentId":child.agent_id,
            "limit":20
        }),
        &root.id,
        &root.workspace_id,
        "usage-history",
    )
    .await;
    let items = history["items"].as_array().unwrap();
    let usage = |assignment_id: &str| {
        items
            .iter()
            .find(|item| item["assignmentId"] == assignment_id)
            .unwrap()["usage"]
            .clone()
    };
    let first_usage = usage(&first_assignment);
    assert_eq!(first_usage["inputTokens"], 40);
    assert_eq!(first_usage["outputTokens"], 6);
    assert_eq!(first_usage["cacheReadTokens"], 10);
    assert_eq!(first_usage["cacheCreationTokens"], 12);
    assert_eq!(first_usage["cost"].as_f64().unwrap(), 0.4);
    assert_eq!(first_usage["wallTimeMs"], 16);
    let second_usage = usage(&second_assignment);
    assert_eq!(second_usage["inputTokens"], 20);
    assert_eq!(second_usage["outputTokens"], 3);
    assert_eq!(second_usage["cost"].as_f64().unwrap(), 0.2);
    assert_eq!(second_usage["wallTimeMs"], 7);
}

#[tokio::test]
async fn assignment_waits_absorb_results_only_for_the_registering_recipient() {
    let (runtime, _home) = test_runtime(None);
    let root = runtime
        .event_store
        .create_session(
            "gpt-5.6-sol",
            "/tmp/project",
            Some("Wait ownership delegator"),
            None,
        )
        .unwrap()
        .session;
    let spawned = spawn_test_child(&runtime, &root.id, &root.workspace_id).await;
    let child = runtime
        .store
        .agent_instance(spawned["agentId"].as_str().unwrap())
        .unwrap()
        .unwrap();
    let manager_spawn = runtime
        .agent_spawn(&coordination_invocation(
            "worker_kernel::agent_spawn",
            json!({
                "task":"Observe assigned work without taking over its requester.",
                "name":"Bounded assignment manager",
                "tools":["agent_wait"]
            }),
            &root.id,
            &root.workspace_id,
            "wait-ownership-manager",
        ))
        .await
        .unwrap();
    let manager = runtime
        .store
        .agent_instance(manager_spawn["agentId"].as_str().unwrap())
        .unwrap()
        .unwrap();
    runtime
        .agent_manage(&coordination_invocation(
            "worker_kernel::agent_manage",
            json!({
                "action":"grant_management",
                "agentId":child.agent_id,
                "toAgentId":manager.agent_id,
                "capabilities":["assign"]
            }),
            &root.id,
            &root.workspace_id,
            "wait-ownership-grant",
        ))
        .await
        .unwrap();

    let first_assignment_id = spawned["assignmentId"].as_str().unwrap().to_owned();
    let manager_wait = runtime
        .agent_wait(&coordination_invocation(
            "worker_kernel::agent_wait",
            json!({
                "targets":[{"kind":"assignment","id":first_assignment_id}],
                "mode":"all"
            }),
            &manager.session_id,
            &manager.workspace_id,
            "manager-waits-on-delegator-assignment",
        ))
        .await
        .unwrap();
    assert_eq!(manager_wait["status"], "pending");
    transition_assignment_to_running(&runtime, &first_assignment_id);
    runtime
        .store
        .transition_agent_assignment(
            &crate::domains::worker_kernel::persistence::AgentAssignmentTransition {
                assignment_id: first_assignment_id.clone(),
                expected_status:
                    crate::domains::worker_kernel::persistence::AgentAssignmentStatus::Running,
                target_status:
                    crate::domains::worker_kernel::persistence::AgentAssignmentStatus::Completed,
                result: Some(json!({"owner":"delegator","result":1})),
                error: None,
            },
        )
        .unwrap();
    runtime.import_agent_coordination_outbox().await.unwrap();

    let root_agent = runtime
        .store
        .agent_instance_for_session(&root.id)
        .unwrap()
        .unwrap();
    let root_messages = runtime
        .event_store
        .list_agent_messages_for_participant(&root_agent.agent_id, None, 100)
        .unwrap();
    assert_eq!(
        root_messages
            .iter()
            .filter(|message| {
                message.kind == crate::shared::protocol::messages::AgentMessageKind::Result
                    && message.content.assignment_id.as_deref()
                        == Some(first_assignment_id.as_str())
            })
            .count(),
        1,
        "a third-party manager wait must not steal the requester's automatic result"
    );
    assert_eq!(
        runtime
            .event_store
            .list_agent_messages_for_participant(&manager.agent_id, None, 100)
            .unwrap()
            .iter()
            .filter(|message| {
                message.kind == crate::shared::protocol::messages::AgentMessageKind::Result
                    && message
                        .content
                        .text
                        .contains(manager_wait["waitId"].as_str().unwrap())
            })
            .count(),
        1,
        "the manager must still receive its own aggregate continuation"
    );

    let second = runtime
        .agent_send(&coordination_invocation(
            "worker_kernel::agent_send",
            json!({
                "to":child.agent_id,
                "kind":"instruction",
                "content":"Produce a second result for an owner-scoped fan-in."
            }),
            &root.id,
            &root.workspace_id,
            "owner-wait-second-assignment",
        ))
        .await
        .unwrap();
    let second_assignment_id = second["assignmentId"].as_str().unwrap().to_owned();
    let owner_wait_invocation = coordination_invocation(
        "worker_kernel::agent_wait",
        json!({
            "targets":[{"kind":"assignment","id":second_assignment_id}],
            "mode":"all"
        }),
        &root.id,
        &root.workspace_id,
        "owner-waits-on-own-assignment",
    );
    let owner_wait = runtime.agent_wait(&owner_wait_invocation).await.unwrap();
    assert_eq!(owner_wait["status"], "pending");
    transition_assignment_to_running(&runtime, &second_assignment_id);
    runtime
        .store
        .transition_agent_assignment(
            &crate::domains::worker_kernel::persistence::AgentAssignmentTransition {
                assignment_id: second_assignment_id.clone(),
                expected_status:
                    crate::domains::worker_kernel::persistence::AgentAssignmentStatus::Running,
                target_status:
                    crate::domains::worker_kernel::persistence::AgentAssignmentStatus::Completed,
                result: Some(json!({"owner":"delegator","result":2})),
                error: None,
            },
        )
        .unwrap();
    runtime.import_agent_coordination_outbox().await.unwrap();
    runtime.import_agent_coordination_outbox().await.unwrap();

    let root_messages = runtime
        .event_store
        .list_agent_messages_for_participant(&root_agent.agent_id, None, 200)
        .unwrap();
    assert_eq!(
        root_messages
            .iter()
            .filter(|message| {
                message.kind == crate::shared::protocol::messages::AgentMessageKind::Result
                    && message
                        .content
                        .text
                        .contains(owner_wait["waitId"].as_str().unwrap())
            })
            .count(),
        1,
        "the requester's wait must coalesce replay into one aggregate result"
    );
    assert_eq!(
        root_messages
            .iter()
            .filter(|message| {
                message.kind == crate::shared::protocol::messages::AgentMessageKind::Result
                    && message.content.assignment_id.as_deref()
                        == Some(second_assignment_id.as_str())
                    && !message
                        .content
                        .text
                        .contains(owner_wait["waitId"].as_str().unwrap())
            })
            .count(),
        0,
        "an owner wait replaces only that owner's ordinary per-assignment wake"
    );
}

#[tokio::test]
async fn automatic_assignment_results_inline_only_context_safe_values_with_reference() {
    let (runtime, _home) = test_runtime(None);
    let root = runtime
        .event_store
        .create_session(
            "gpt-5.6-sol",
            "/tmp/project",
            Some("Automatic result custody"),
            None,
        )
        .unwrap()
        .session;
    let spawned = spawn_test_child(&runtime, &root.id, &root.workspace_id).await;
    let child = runtime
        .store
        .agent_instance(spawned["agentId"].as_str().unwrap())
        .unwrap()
        .unwrap();
    let root_agent = runtime
        .store
        .agent_instance_for_session(&root.id)
        .unwrap()
        .unwrap();

    let small_assignment_id = spawned["assignmentId"].as_str().unwrap().to_owned();
    transition_assignment_to_running(&runtime, &small_assignment_id);
    let small_result = json!({"answer":"context safe","items":[1,2,3]});
    runtime
        .store
        .transition_agent_assignment(
            &crate::domains::worker_kernel::persistence::AgentAssignmentTransition {
                assignment_id: small_assignment_id.clone(),
                expected_status:
                    crate::domains::worker_kernel::persistence::AgentAssignmentStatus::Running,
                target_status:
                    crate::domains::worker_kernel::persistence::AgentAssignmentStatus::Completed,
                result: Some(small_result.clone()),
                error: None,
            },
        )
        .unwrap();
    runtime.import_agent_coordination_outbox().await.unwrap();

    let second = runtime
        .agent_send(&coordination_invocation(
            "worker_kernel::agent_send",
            json!({
                "to":child.agent_id,
                "kind":"instruction",
                "content":"Return a result larger than the inline context boundary."
            }),
            &root.id,
            &root.workspace_id,
            "automatic-large-result",
        ))
        .await
        .unwrap();
    let large_assignment_id = second["assignmentId"].as_str().unwrap().to_owned();
    transition_assignment_to_running(&runtime, &large_assignment_id);
    let large_result = json!({
        "blob":"x".repeat(
            crate::shared::protocol::model_tools::DEFAULT_MAX_INLINE_MODEL_TOOL_RESULT_BYTES + 128
        )
    });
    runtime
        .store
        .transition_agent_assignment(
            &crate::domains::worker_kernel::persistence::AgentAssignmentTransition {
                assignment_id: large_assignment_id.clone(),
                expected_status:
                    crate::domains::worker_kernel::persistence::AgentAssignmentStatus::Running,
                target_status:
                    crate::domains::worker_kernel::persistence::AgentAssignmentStatus::Completed,
                result: Some(large_result),
                error: None,
            },
        )
        .unwrap();
    runtime.import_agent_coordination_outbox().await.unwrap();

    let result_payload = |assignment_id: &str| {
        runtime
            .event_store
            .list_agent_messages_for_participant(&root_agent.agent_id, None, 100)
            .unwrap()
            .into_iter()
            .filter(|message| {
                message.kind == crate::shared::protocol::messages::AgentMessageKind::Result
            })
            .find_map(|message| {
                let payload = serde_json::from_str::<Value>(&message.content.text).ok()?;
                (payload["assignmentId"] == assignment_id).then_some(payload)
            })
            .unwrap_or_else(|| panic!("automatic result for '{assignment_id}' was not delivered"))
    };
    let small_delivery = result_payload(&small_assignment_id);
    assert_eq!(small_delivery["result"], small_result);
    assert_eq!(
        small_delivery["resultReference"]["kind"],
        "agent_assignment_result_reference"
    );
    assert!(
        small_delivery["resultReference"]["contentSha256"]
            .as_str()
            .is_some_and(|hash| hash.starts_with("sha256:"))
    );

    let large_delivery = result_payload(&large_assignment_id);
    assert!(large_delivery["result"].is_null());
    assert_eq!(
        large_delivery["resultReference"]["kind"],
        "agent_assignment_result_reference"
    );
    assert!(
        large_delivery["resultReference"]["sizeBytes"]
            .as_u64()
            .is_some_and(|size| {
                size > crate::shared::protocol::model_tools::DEFAULT_MAX_INLINE_MODEL_TOOL_RESULT_BYTES
                    as u64
            })
    );
    assert!(
        large_delivery["resultReference"]["contentSha256"]
            .as_str()
            .is_some_and(|hash| hash.starts_with("sha256:"))
    );
}
