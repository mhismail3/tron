//! Agent runner — wraps `TronAgent` with orchestrator integration.
//!
//! Handles primitive run execution and the critical
//! `agent.complete` → `agent.ready` ordering.

use std::sync::Arc;
use std::sync::atomic::AtomicI64;

#[cfg(test)]
use crate::shared::protocol::events::TronEvent;
use tracing::{debug, instrument};

use crate::domains::agent::r#loop::event_emitter::EventEmitter;
use crate::domains::agent::r#loop::tron_agent::TronAgent;
use crate::domains::agent::r#loop::types::{RunContext, RunResult};

/// Run an agent with orchestrator integration.
///
/// This wraps `TronAgent::run` with:
/// 1. Build and inject the primitive `RunContext`
/// 2. Execute `agent.run(content, ctx)`
/// 3. Emit run events directly through the orchestrator's canonical emitter
///
/// Terminal readiness is owned by prompt completion, which publishes the final
/// session projection and synchronizes `agent.ready` with run-slot release.
#[instrument(skip_all, fields(session_id = agent.session_id()))]
pub async fn run_agent(
    agent: &mut TronAgent,
    content: &str,
    ctx: RunContext,
    broadcast: &Arc<EventEmitter>,
    sequence_counter: Option<Arc<AtomicI64>>,
) -> RunResult {
    let session_id = agent.session_id().to_owned();
    debug!(session_id = agent.session_id(), "agent runner starting");

    // Inject sequence counter so the agent can assign monotonic sequences to events.
    if let Some(ref counter) = sequence_counter {
        agent.set_sequence_counter(counter.clone());
    }

    // INVARIANT: there is no intermediate broadcast hop. The outer emitter
    // synchronously updates reconnect state before broadcasting each event.
    agent.set_emitter(broadcast.clone());

    // Run the agent.
    let result = agent.run(content, ctx).await;

    debug!(session_id, stop_reason = ?result.stop_reason, turns = result.turns_executed, "agent run completed");

    result
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domains::agent::context::context_manager::ContextManager;
    use crate::domains::agent::context::types::ContextManagerConfig;
    use crate::domains::agent::r#loop::errors::StopReason;
    use crate::domains::agent::r#loop::event_emitter::TronEventObserver;
    use crate::domains::agent::r#loop::orchestrator::invocation_abort_registry::InvocationAbortRegistry;
    use crate::domains::model::responder::{
        ModelResponder, ModelResponderInfo, ModelResponse, ModelResponseError,
        ModelResponseRequest, ModelResponseStream,
    };
    use crate::shared::protocol::content::AssistantContent;
    use crate::shared::protocol::events::{AssistantMessage, StreamEvent};
    use crate::shared::protocol::messages::TokenUsage;
    use async_trait::async_trait;
    use futures::{StreamExt, stream};
    use std::sync::atomic::{AtomicUsize, Ordering};
    use tokio_util::sync::CancellationToken;

    use crate::domains::agent::r#loop::tron_agent::AgentDeps;
    use crate::domains::agent::r#loop::types::AgentConfig;

    struct StreamBackedResponder {
        events: Vec<Result<StreamEvent, ModelResponseError>>,
        respond_calls: Option<Arc<AtomicUsize>>,
    }

    impl StreamBackedResponder {
        fn new(events: Vec<Result<StreamEvent, ModelResponseError>>) -> Self {
            Self {
                events,
                respond_calls: None,
            }
        }

        fn new_counted(
            events: Vec<Result<StreamEvent, ModelResponseError>>,
            respond_calls: Arc<AtomicUsize>,
        ) -> Self {
            Self {
                events,
                respond_calls: Some(respond_calls),
            }
        }
    }

    #[async_trait]
    impl ModelResponder for StreamBackedResponder {
        fn info(&self) -> ModelResponderInfo {
            ModelResponderInfo {
                provider_type: crate::shared::protocol::messages::Provider::Anthropic,
                provider_name: "anthropic",
                model: "mock".to_owned(),
                context_window: 200_000,
            }
        }

        async fn respond(
            &self,
            _request: ModelResponseRequest,
        ) -> Result<ModelResponse, ModelResponseError> {
            if let Some(calls) = &self.respond_calls {
                calls.fetch_add(1, Ordering::SeqCst);
            }
            let events = self.events.clone();
            let s = stream::iter(events);
            Ok(ModelResponse {
                info: self.info(),
                stream: Box::pin(s) as ModelResponseStream,
            })
        }
    }

    struct PartialThenCancelResponder;

    #[async_trait]
    impl ModelResponder for PartialThenCancelResponder {
        fn info(&self) -> ModelResponderInfo {
            ModelResponderInfo {
                provider_type: crate::shared::protocol::messages::Provider::Anthropic,
                provider_name: "anthropic",
                model: "mock".to_owned(),
                context_window: 200_000,
            }
        }

        async fn respond(
            &self,
            request: ModelResponseRequest,
        ) -> Result<ModelResponse, ModelResponseError> {
            let cancel = request.cancel;
            let events = vec![
                Ok(StreamEvent::Start),
                Ok(StreamEvent::TextDelta {
                    delta: "partial".into(),
                }),
            ];
            let stream = stream::iter(events.into_iter().enumerate()).map(move |(index, event)| {
                if index == 1 {
                    cancel.cancel();
                }
                event
            });
            Ok(ModelResponse {
                info: self.info(),
                stream: Box::pin(stream),
            })
        }
    }

    struct CancelBeforeStreamResponder;

    #[async_trait]
    impl ModelResponder for CancelBeforeStreamResponder {
        fn info(&self) -> ModelResponderInfo {
            ModelResponderInfo {
                provider_type: crate::shared::protocol::messages::Provider::Anthropic,
                provider_name: "anthropic",
                model: "mock".to_owned(),
                context_window: 200_000,
            }
        }

        async fn respond(
            &self,
            request: ModelResponseRequest,
        ) -> Result<ModelResponse, ModelResponseError> {
            request.cancel.cancel();
            Err(ModelResponseError::other("provider observed cancellation"))
        }
    }

    fn default_events() -> Vec<Result<StreamEvent, ModelResponseError>> {
        vec![
            Ok(StreamEvent::Start),
            Ok(StreamEvent::TextDelta {
                delta: "Hello".into(),
            }),
            Ok(StreamEvent::Done {
                message: AssistantMessage {
                    content: vec![AssistantContent::text("Hello")],
                    token_usage: Some(TokenUsage {
                        input_tokens: 10,
                        output_tokens: 5,
                        ..Default::default()
                    }),
                },
                stop_reason: "end_turn".into(),
            }),
        ]
    }

    fn capability_events() -> Vec<Result<StreamEvent, ModelResponseError>> {
        let mut arguments = serde_json::Map::new();
        let _ = arguments.insert("operation".to_owned(), serde_json::json!("observe"));
        let _ = arguments.insert("input".to_owned(), serde_json::json!("lifecycle test"));
        vec![
            Ok(StreamEvent::Start),
            Ok(StreamEvent::CapabilityInvocationDraftStart {
                invocation_id: "call-lifecycle".to_owned(),
                name: "execute".to_owned(),
            }),
            Ok(StreamEvent::CapabilityInvocationDraftDelta {
                invocation_id: "call-lifecycle".to_owned(),
                arguments_delta: serde_json::to_string(&arguments).unwrap(),
            }),
            Ok(StreamEvent::CapabilityInvocationDraftEnd {
                capability_invocation:
                    crate::shared::protocol::messages::CapabilityInvocationDraft::new(
                        "call-lifecycle",
                        "execute",
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
        ]
    }

    struct JournalCleanup {
        session_id: String,
    }

    impl JournalCleanup {
        fn new(session_id: &str) -> Self {
            Self {
                session_id: session_id.to_owned(),
            }
        }
    }

    impl Drop for JournalCleanup {
        fn drop(&mut self) {
            let dir = crate::shared::foundation::paths::journals_dir().join(&self.session_id);
            if dir.exists() {
                let _ = std::fs::remove_dir_all(&dir);
            }
        }
    }

    fn unique_test_session_id() -> String {
        format!("agent-runner-test-{}", uuid::Uuid::now_v7())
    }

    fn make_agent_with_responder(
        responder: Arc<dyn ModelResponder>,
    ) -> (TronAgent, JournalCleanup) {
        let session_id = unique_test_session_id();
        make_agent_with_responder_for_session(responder, session_id)
    }

    fn make_agent_with_responder_for_session(
        responder: Arc<dyn ModelResponder>,
        session_id: String,
    ) -> (TronAgent, JournalCleanup) {
        let cleanup = JournalCleanup::new(&session_id);
        let agent = TronAgent::new(
            AgentConfig::default(),
            AgentDeps {
                responder,
                context_manager: ContextManager::new(ContextManagerConfig {
                    system_prompt: Some("You are helpful.".into()),
                    working_directory: None,
                    compaction: crate::domains::agent::context::types::CompactionConfig::default(),
                }),
                compaction_trigger_config:
                    crate::domains::agent::context::types::CompactionTriggerConfig::default(),
                invocation_abort_registry: Arc::new(InvocationAbortRegistry::new()),
                engine_host: crate::engine::EngineHostHandle::new_in_memory().expect("engine host"),
            },
            session_id,
        );
        (agent, cleanup)
    }

    fn make_agent() -> (TronAgent, JournalCleanup) {
        make_agent_with_responder(Arc::new(StreamBackedResponder::new(default_events())))
    }

    fn run_context() -> RunContext {
        RunContext::default()
    }

    #[derive(Default)]
    struct MessageUpdateObserver(AtomicUsize);

    impl TronEventObserver for MessageUpdateObserver {
        fn observe_tron_event(&self, event: &TronEvent) {
            if matches!(event, TronEvent::MessageUpdate { .. }) {
                let _ = self.0.fetch_add(1, Ordering::SeqCst);
            }
        }
    }

    #[tokio::test]
    async fn run_agent_defers_terminal_lifecycle_to_prompt_completion() {
        let (mut agent, _journal) = make_agent();
        let broadcast = Arc::new(EventEmitter::new());
        let mut rx = broadcast.subscribe();

        let result = run_agent(&mut agent, "Hello", run_context(), &broadcast, None).await;

        assert_eq!(result.stop_reason, StopReason::EndTurn);
        assert_eq!(result.turns_executed, 1);

        // Collect broadcast events
        let mut event_types = vec![];
        while let Ok(event) = rx.try_recv() {
            event_types.push(event.event_type().to_owned());
        }

        assert!(
            event_types.iter().all(|event_type| !matches!(
                event_type.as_str(),
                "agent_end" | "agent_ready" | "session.processing_changed"
            )),
            "run_agent must not publish terminal admission events: {event_types:?}"
        );
    }

    #[tokio::test]
    async fn cancelled_turn_uses_session_ordinal_and_row_backed_sequence() {
        use crate::domains::agent::r#loop::orchestrator::event_persister::EventPersister;
        use crate::domains::session::event_store::sqlite::connection::{self, ConnectionConfig};
        use crate::domains::session::event_store::sqlite::migrations::run_migrations;
        use crate::domains::session::event_store::{EventStore, ListEventsOptions};
        use crate::shared::server::failure::RUNTIME_CANCELLED;

        let pool = connection::new_in_memory(&ConnectionConfig::default()).unwrap();
        {
            let conn = pool.get().unwrap();
            run_migrations(&conn).unwrap();
        }
        let store = Arc::new(EventStore::new(pool));
        let session = store
            .create_session("mock", "/tmp", Some("cancel"), None)
            .unwrap();
        let (mut agent, _journal) = make_agent_with_responder_for_session(
            Arc::new(StreamBackedResponder::new(default_events())),
            session.session.id.clone(),
        );
        agent.set_turn_offset(19);
        agent.set_persister(Some(Arc::new(EventPersister::new(Arc::clone(&store)))));
        let cancel = CancellationToken::new();
        cancel.cancel();
        agent.set_abort_token(cancel);
        let counter = Arc::new(AtomicI64::new(
            store.get_max_sequence(&session.session.id).unwrap(),
        ));
        let broadcast = Arc::new(EventEmitter::new());
        let mut rx = broadcast.subscribe();

        let result = run_agent(
            &mut agent,
            "cancel now",
            run_context(),
            &broadcast,
            Some(counter),
        )
        .await;

        assert!(result.interrupted, "unexpected run result: {result:?}");
        assert_eq!(result.turns_executed, 1);
        let rows = store
            .get_events_by_session(&session.session.id, &ListEventsOptions::default())
            .unwrap();
        let failures = rows
            .iter()
            .filter(|row| row.event_type == "turn.failed")
            .collect::<Vec<_>>();
        assert_eq!(failures.len(), 1, "cancellation has one durable owner");
        let start = rows
            .iter()
            .find(|row| row.event_type == "stream.turn_start")
            .expect("cancelled turn must have a durable start");
        let failure_payload: serde_json::Value =
            serde_json::from_str(&failures[0].payload).unwrap();
        assert_eq!(failure_payload["turn"], 20);
        assert_eq!(failure_payload["code"], RUNTIME_CANCELLED);

        let live_events = std::iter::from_fn(|| rx.try_recv().ok()).collect::<Vec<_>>();
        let live_start = live_events
            .iter()
            .find(|event| matches!(event, TronEvent::TurnStart { turn: 20, .. }))
            .expect("cancelled turn start must be broadcast");
        assert_eq!(live_start.sequence(), Some(start.sequence));
        let live_failure = live_events
            .iter()
            .find(|event| matches!(event, TronEvent::TurnFailed { turn: 20, .. }))
            .expect("cancelled turn failure must be broadcast");
        assert_eq!(live_failure.sequence(), Some(failures[0].sequence));

        let sequenced = live_events
            .iter()
            .filter_map(TronEvent::sequence)
            .collect::<Vec<_>>();
        assert!(
            sequenced.windows(2).all(|pair| pair[0] < pair[1]),
            "live cancellation lifecycle must be strictly sequenced: {sequenced:?}"
        );
    }

    #[tokio::test]
    async fn partial_cancellation_atomically_persists_message_and_failure() {
        use crate::domains::agent::r#loop::orchestrator::event_persister::EventPersister;
        use crate::domains::agent::r#loop::orchestrator::streaming_journal::StreamingJournal;
        use crate::domains::session::event_store::sqlite::connection::{self, ConnectionConfig};
        use crate::domains::session::event_store::sqlite::migrations::run_migrations;
        use crate::domains::session::event_store::{EventStore, ListEventsOptions};

        let pool = connection::new_in_memory(&ConnectionConfig::default()).unwrap();
        {
            let conn = pool.get().unwrap();
            run_migrations(&conn).unwrap();
        }
        let store = Arc::new(EventStore::new(pool));
        let session = store
            .create_session("mock", "/tmp", Some("partial cancel"), None)
            .unwrap();
        let (mut agent, _journal) = make_agent_with_responder_for_session(
            Arc::new(PartialThenCancelResponder),
            session.session.id.clone(),
        );
        agent.set_turn_offset(19);
        agent.set_persister(Some(Arc::new(EventPersister::new(Arc::clone(&store)))));
        let counter = Arc::new(AtomicI64::new(
            store.get_max_sequence(&session.session.id).unwrap(),
        ));
        let broadcast = Arc::new(EventEmitter::new());
        let mut rx = broadcast.subscribe();

        let result = run_agent(
            &mut agent,
            "cancel after partial",
            run_context(),
            &broadcast,
            Some(counter),
        )
        .await;

        assert!(result.interrupted, "unexpected run result: {result:?}");
        let rows = store
            .get_events_by_session(&session.session.id, &ListEventsOptions::default())
            .unwrap();
        let assistant = rows
            .iter()
            .filter(|row| row.event_type == "message.assistant")
            .collect::<Vec<_>>();
        assert_eq!(
            assistant.len(),
            1,
            "partial assistant has one durable owner"
        );
        let failure = rows
            .iter()
            .filter(|row| row.event_type == "turn.failed")
            .collect::<Vec<_>>();
        assert_eq!(
            failure.len(),
            1,
            "cancellation failure has one durable owner"
        );
        let assistant = assistant[0];
        let failure = failure[0];
        assert_eq!(failure.sequence, assistant.sequence + 1);
        assert_eq!(failure.parent_id.as_deref(), Some(assistant.id.as_str()));
        assert_eq!(assistant.turn, Some(20));
        assert_eq!(failure.turn, Some(20));
        let assistant_payload: serde_json::Value =
            serde_json::from_str(&assistant.payload).unwrap();
        assert_eq!(assistant_payload["content"][0]["text"], "partial");
        let failure_payload: serde_json::Value = serde_json::from_str(&failure.payload).unwrap();
        assert_eq!(failure_payload["partialContent"], "partial");
        assert_eq!(
            store
                .get_session(&session.session.id)
                .unwrap()
                .unwrap()
                .turn_count,
            1
        );
        let live_failure = std::iter::from_fn(|| rx.try_recv().ok())
            .find(|event| matches!(event, TronEvent::TurnFailed { turn: 20, .. }))
            .expect("row-backed failure broadcast");
        assert_eq!(live_failure.sequence(), Some(failure.sequence));
        assert!(!StreamingJournal::journal_path(&session.session.id, 20).exists());
    }

    #[tokio::test]
    async fn persisted_happy_path_has_one_ordered_lifecycle_and_no_journal() {
        use crate::domains::agent::r#loop::orchestrator::event_persister::EventPersister;
        use crate::domains::agent::r#loop::orchestrator::streaming_journal::StreamingJournal;
        use crate::domains::session::event_store::sqlite::connection::{self, ConnectionConfig};
        use crate::domains::session::event_store::sqlite::migrations::run_migrations;
        use crate::domains::session::event_store::{EventStore, ListEventsOptions};

        let pool = connection::new_in_memory(&ConnectionConfig::default()).unwrap();
        {
            let conn = pool.get().unwrap();
            run_migrations(&conn).unwrap();
        }
        let store = Arc::new(EventStore::new(pool));
        let session = store
            .create_session("mock", "/tmp", Some("happy lifecycle"), None)
            .unwrap();
        let (mut agent, _cleanup) = make_agent_with_responder_for_session(
            Arc::new(StreamBackedResponder::new(default_events())),
            session.session.id.clone(),
        );
        agent.set_persister(Some(Arc::new(EventPersister::new(Arc::clone(&store)))));
        let counter = Arc::new(AtomicI64::new(
            store.get_max_sequence(&session.session.id).unwrap(),
        ));
        let broadcast = Arc::new(EventEmitter::new());
        let mut receiver = broadcast.subscribe();

        let result = run_agent(
            &mut agent,
            "complete normally",
            run_context(),
            &broadcast,
            Some(counter),
        )
        .await;

        assert_eq!(result.stop_reason, StopReason::EndTurn);
        let rows = store
            .get_events_by_session(&session.session.id, &ListEventsOptions::default())
            .unwrap();
        let lifecycle = [
            "stream.turn_start",
            "model.provider_request",
            "message.assistant",
            "stream.turn_end",
        ]
        .map(|event_type| {
            rows.iter()
                .filter(|row| row.event_type == event_type)
                .collect::<Vec<_>>()
        });
        assert!(lifecycle.iter().all(|matches| matches.len() == 1));
        let durable_sequences = lifecycle
            .iter()
            .map(|matches| matches[0].sequence)
            .collect::<Vec<_>>();
        assert!(durable_sequences.windows(2).all(|pair| pair[0] < pair[1]));
        assert_eq!(lifecycle[0][0].turn, Some(1));
        assert_eq!(lifecycle[2][0].turn, Some(1));
        assert_eq!(lifecycle[3][0].turn, Some(1));
        assert!(!StreamingJournal::journal_path(&session.session.id, 1).exists());

        let live = std::iter::from_fn(|| receiver.try_recv().ok()).collect::<Vec<_>>();
        let live_sequences = live
            .iter()
            .filter_map(TronEvent::sequence)
            .collect::<Vec<_>>();
        assert!(
            live_sequences.windows(2).all(|pair| pair[0] < pair[1]),
            "live lifecycle must be strictly ordered: {live_sequences:?}"
        );
        let start = live
            .iter()
            .find(|event| matches!(event, TronEvent::TurnStart { .. }))
            .expect("live turn start");
        let end = live
            .iter()
            .find(|event| matches!(event, TronEvent::TurnEnd { .. }))
            .expect("live turn end");
        assert_eq!(start.sequence(), Some(lifecycle[0][0].sequence));
        assert_eq!(end.sequence(), Some(lifecycle[3][0].sequence));

        assert!(live.iter().all(|event| !matches!(
            event,
            TronEvent::AgentEnd { .. }
                | TronEvent::SessionProcessingChanged {
                    is_processing: false,
                    ..
                }
                | TronEvent::AgentReady { .. }
        )));
    }

    #[tokio::test]
    async fn provider_stream_failure_atomically_preserves_visible_partial_output() {
        use crate::domains::agent::r#loop::orchestrator::event_persister::EventPersister;
        use crate::domains::agent::r#loop::orchestrator::streaming_journal::StreamingJournal;
        use crate::domains::session::event_store::sqlite::connection::{self, ConnectionConfig};
        use crate::domains::session::event_store::sqlite::migrations::run_migrations;
        use crate::domains::session::event_store::{EventStore, ListEventsOptions};

        let pool = connection::new_in_memory(&ConnectionConfig::default()).unwrap();
        {
            let conn = pool.get().unwrap();
            run_migrations(&conn).unwrap();
        }
        let store = Arc::new(EventStore::new(pool));
        let session = store
            .create_session("mock", "/tmp", Some("partial failure"), None)
            .unwrap();
        let events = vec![
            Ok(StreamEvent::Start),
            Ok(StreamEvent::TextDelta {
                delta: "visible partial".into(),
            }),
            Err(ModelResponseError::other("provider connection lost")),
        ];
        let (mut agent, _cleanup) = make_agent_with_responder_for_session(
            Arc::new(StreamBackedResponder::new(events)),
            session.session.id.clone(),
        );
        agent.set_persister(Some(Arc::new(EventPersister::new(Arc::clone(&store)))));
        let counter = Arc::new(AtomicI64::new(
            store.get_max_sequence(&session.session.id).unwrap(),
        ));
        let broadcast = Arc::new(EventEmitter::new());
        let mut receiver = broadcast.subscribe();

        let result = run_agent(
            &mut agent,
            "fail after output",
            run_context(),
            &broadcast,
            Some(counter),
        )
        .await;

        assert_eq!(result.stop_reason, StopReason::Error);
        assert!(
            result
                .error
                .as_deref()
                .is_some_and(|error| error.contains("provider connection lost"))
        );
        let rows = store
            .get_events_by_session(&session.session.id, &ListEventsOptions::default())
            .unwrap();
        let assistant = rows
            .iter()
            .filter(|row| row.event_type == "message.assistant")
            .collect::<Vec<_>>();
        let failure = rows
            .iter()
            .filter(|row| row.event_type == "turn.failed")
            .collect::<Vec<_>>();
        assert_eq!(assistant.len(), 1);
        assert_eq!(failure.len(), 1);
        assert_eq!(failure[0].sequence, assistant[0].sequence + 1);
        assert_eq!(
            failure[0].parent_id.as_deref(),
            Some(assistant[0].id.as_str())
        );
        assert!(rows.iter().all(|row| row.event_type != "stream.turn_end"));
        let payload: serde_json::Value = serde_json::from_str(&assistant[0].payload).unwrap();
        assert_eq!(payload["content"][0]["text"], "visible partial");
        assert_eq!(payload["stopReason"], "error");
        assert_eq!(payload["partial"], true);
        assert!(!StreamingJournal::journal_path(&session.session.id, 1).exists());

        let live_failure = std::iter::from_fn(|| receiver.try_recv().ok())
            .find(|event| matches!(event, TronEvent::TurnFailed { turn: 1, .. }))
            .expect("row-backed live failure");
        assert_eq!(live_failure.sequence(), Some(failure[0].sequence));
        let reconstructed =
            crate::domains::agent::r#loop::orchestrator::session_reconstructor::reconstruct(
                &store,
                &session.session.id,
            )
            .expect("partial failure reconstructs");
        assert!(reconstructed.messages.iter().any(|message| {
            matches!(
                message,
                crate::shared::protocol::messages::Message::Assistant { content, .. }
                    if content.iter().any(|block| matches!(
                        block,
                        AssistantContent::Text { text, .. } if text == "visible partial"
                    ))
            )
        }));
    }

    #[tokio::test]
    async fn cancellation_before_stream_open_terminalizes_current_turn_once() {
        use crate::domains::agent::r#loop::orchestrator::event_persister::EventPersister;
        use crate::domains::session::event_store::sqlite::connection::{self, ConnectionConfig};
        use crate::domains::session::event_store::sqlite::migrations::run_migrations;
        use crate::domains::session::event_store::{EventStore, ListEventsOptions};

        let pool = connection::new_in_memory(&ConnectionConfig::default()).unwrap();
        {
            let conn = pool.get().unwrap();
            run_migrations(&conn).unwrap();
        }
        let store = Arc::new(EventStore::new(pool));
        let session = store
            .create_session("mock", "/tmp", Some("pre-stream cancel"), None)
            .unwrap();
        let (mut agent, _journal) = make_agent_with_responder_for_session(
            Arc::new(CancelBeforeStreamResponder),
            session.session.id.clone(),
        );
        agent.set_turn_offset(8);
        agent.set_persister(Some(Arc::new(EventPersister::new(Arc::clone(&store)))));
        let counter = Arc::new(AtomicI64::new(
            store.get_max_sequence(&session.session.id).unwrap(),
        ));

        let result = run_agent(
            &mut agent,
            "cancel before stream",
            run_context(),
            &Arc::new(EventEmitter::new()),
            Some(counter),
        )
        .await;

        assert!(result.interrupted, "unexpected run result: {result:?}");
        assert_eq!(result.stop_reason, StopReason::Interrupted);
        let rows = store
            .get_events_by_session(&session.session.id, &ListEventsOptions::default())
            .unwrap();
        assert_eq!(
            rows.iter()
                .filter(|row| row.event_type == "stream.turn_start" && row.turn == Some(9))
                .count(),
            1
        );
        assert_eq!(
            rows.iter()
                .filter(|row| row.event_type == "turn.failed" && row.turn == Some(9))
                .count(),
            1
        );
        assert!(rows.iter().all(|row| {
            row.event_type != "message.assistant" && row.event_type != "stream.turn_end"
        }));
    }

    #[tokio::test]
    async fn partial_cancellation_rolls_back_message_when_terminal_write_fails() {
        use crate::domains::agent::r#loop::orchestrator::event_persister::EventPersister;
        use crate::domains::agent::r#loop::orchestrator::streaming_journal::StreamingJournal;
        use crate::domains::session::event_store::sqlite::connection::{self, ConnectionConfig};
        use crate::domains::session::event_store::sqlite::migrations::run_migrations;
        use crate::domains::session::event_store::{EventStore, ListEventsOptions};

        let pool = connection::new_in_memory(&ConnectionConfig::default()).unwrap();
        {
            let conn = pool.get().unwrap();
            run_migrations(&conn).unwrap();
            conn.execute_batch(
                "CREATE TRIGGER fail_partial_cancel_terminal
                 BEFORE INSERT ON events
                 WHEN NEW.type = 'turn.failed'
                 BEGIN
                   SELECT RAISE(FAIL, 'forced partial terminal failure');
                 END;",
            )
            .unwrap();
        }
        let store = Arc::new(EventStore::new(pool));
        let session = store
            .create_session("mock", "/tmp", Some("partial rollback"), None)
            .unwrap();
        let (mut agent, _journal) = make_agent_with_responder_for_session(
            Arc::new(PartialThenCancelResponder),
            session.session.id.clone(),
        );
        agent.set_persister(Some(Arc::new(EventPersister::new(Arc::clone(&store)))));
        let counter = Arc::new(AtomicI64::new(
            store.get_max_sequence(&session.session.id).unwrap(),
        ));

        let result = run_agent(
            &mut agent,
            "cancel after partial",
            run_context(),
            &Arc::new(EventEmitter::new()),
            Some(counter),
        )
        .await;

        assert_eq!(result.stop_reason, StopReason::Error);
        assert!(!result.interrupted);
        let rows = store
            .get_events_by_session(&session.session.id, &ListEventsOptions::default())
            .unwrap();
        assert!(rows.iter().all(|row| {
            row.event_type != "message.assistant" && row.event_type != "turn.failed"
        }));
        assert!(
            StreamingJournal::journal_path(&session.session.id, 1).exists(),
            "failed atomic terminalization must retain recoverable stream data"
        );
    }

    #[tokio::test]
    async fn failed_turn_end_is_terminal_error_not_success() {
        use crate::domains::agent::r#loop::orchestrator::event_persister::EventPersister;
        use crate::domains::agent::r#loop::orchestrator::streaming_journal::StreamingJournal;
        use crate::domains::session::event_store::sqlite::connection::{self, ConnectionConfig};
        use crate::domains::session::event_store::sqlite::migrations::run_migrations;
        use crate::domains::session::event_store::{EventStore, ListEventsOptions};

        let pool = connection::new_in_memory(&ConnectionConfig::default()).unwrap();
        {
            let conn = pool.get().unwrap();
            run_migrations(&conn).unwrap();
            conn.execute_batch(
                "CREATE TRIGGER fail_turn_end
                 BEFORE INSERT ON events
                 WHEN NEW.type = 'stream.turn_end'
                 BEGIN
                   SELECT RAISE(FAIL, 'forced turn-end failure');
                 END;",
            )
            .unwrap();
        }
        let store = Arc::new(EventStore::new(pool));
        let session = store
            .create_session("mock", "/tmp", Some("end failure"), None)
            .unwrap();
        let (mut agent, _journal) = make_agent_with_responder_for_session(
            Arc::new(StreamBackedResponder::new(default_events())),
            session.session.id.clone(),
        );
        agent.set_persister(Some(Arc::new(EventPersister::new(Arc::clone(&store)))));
        let counter = Arc::new(AtomicI64::new(
            store.get_max_sequence(&session.session.id).unwrap(),
        ));

        let result = run_agent(
            &mut agent,
            "finish durably",
            run_context(),
            &Arc::new(EventEmitter::new()),
            Some(counter),
        )
        .await;

        assert_eq!(result.stop_reason, StopReason::Error);
        assert!(!result.interrupted);
        let rows = store
            .get_events_by_session(&session.session.id, &ListEventsOptions::default())
            .unwrap();
        assert_eq!(
            rows.iter()
                .filter(|row| row.event_type == "message.assistant")
                .count(),
            1
        );
        assert_eq!(
            rows.iter()
                .filter(|row| row.event_type == "turn.failed")
                .count(),
            1
        );
        assert!(rows.iter().all(|row| row.event_type != "stream.turn_end"));
        assert!(!StreamingJournal::journal_path(&session.session.id, 1).exists());
    }

    #[tokio::test]
    async fn failed_capability_start_batch_stops_turn_and_retains_recovery_journal() {
        use crate::domains::agent::r#loop::orchestrator::event_persister::EventPersister;
        use crate::domains::agent::r#loop::orchestrator::streaming_journal::StreamingJournal;
        use crate::domains::session::event_store::sqlite::connection::{self, ConnectionConfig};
        use crate::domains::session::event_store::sqlite::migrations::run_migrations;
        use crate::domains::session::event_store::{EventStore, ListEventsOptions};

        let pool = connection::new_in_memory(&ConnectionConfig::default()).unwrap();
        {
            let conn = pool.get().unwrap();
            run_migrations(&conn).unwrap();
            conn.execute_batch(
                "CREATE TRIGGER fail_capability_start
                 BEFORE INSERT ON events
                 WHEN NEW.type = 'capability.invocation.started'
                 BEGIN
                   SELECT RAISE(FAIL, 'forced capability-start failure');
                 END;",
            )
            .unwrap();
        }
        let store = Arc::new(EventStore::new(pool));
        let session = store
            .create_session("mock", "/tmp", Some("capability start failure"), None)
            .unwrap();
        let (mut agent, _journal) = make_agent_with_responder_for_session(
            Arc::new(StreamBackedResponder::new(capability_events())),
            session.session.id.clone(),
        );
        agent.set_persister(Some(Arc::new(EventPersister::new(Arc::clone(&store)))));
        let counter = Arc::new(AtomicI64::new(
            store.get_max_sequence(&session.session.id).unwrap(),
        ));

        let result = run_agent(
            &mut agent,
            "use a capability",
            run_context(),
            &Arc::new(EventEmitter::new()),
            Some(counter),
        )
        .await;

        assert_eq!(result.stop_reason, StopReason::Error);
        let rows = store
            .get_events_by_session(&session.session.id, &ListEventsOptions::default())
            .unwrap();
        assert_eq!(
            rows.iter()
                .filter(|row| row.event_type == "message.assistant")
                .count(),
            1
        );
        assert_eq!(
            rows.iter()
                .filter(|row| row.event_type == "turn.failed")
                .count(),
            1
        );
        assert!(rows.iter().all(|row| {
            row.event_type != "capability.invocation.started"
                && row.event_type != "capability.invocation.completed"
                && row.event_type != "stream.turn_end"
        }));
        assert!(
            StreamingJournal::journal_path(&session.session.id, 1).exists(),
            "incomplete capability lifecycle must remain recoverable on restart"
        );
    }

    #[tokio::test]
    async fn failed_turn_start_stops_before_provider_execution() {
        use crate::domains::agent::r#loop::orchestrator::event_persister::EventPersister;
        use crate::domains::session::event_store::sqlite::connection::{self, ConnectionConfig};
        use crate::domains::session::event_store::sqlite::migrations::run_migrations;
        use crate::domains::session::event_store::{EventStore, ListEventsOptions};

        let pool = connection::new_in_memory(&ConnectionConfig::default()).unwrap();
        {
            let conn = pool.get().unwrap();
            run_migrations(&conn).unwrap();
            conn.execute_batch(
                "CREATE TRIGGER fail_turn_start
                 BEFORE INSERT ON events
                 WHEN NEW.type = 'stream.turn_start'
                 BEGIN
                   SELECT RAISE(FAIL, 'forced turn-start failure');
                 END;",
            )
            .unwrap();
        }
        let store = Arc::new(EventStore::new(pool));
        let session = store
            .create_session("mock", "/tmp", Some("start failure"), None)
            .unwrap();
        let respond_calls = Arc::new(AtomicUsize::new(0));
        let (mut agent, _journal) = make_agent_with_responder_for_session(
            Arc::new(StreamBackedResponder::new_counted(
                default_events(),
                Arc::clone(&respond_calls),
            )),
            session.session.id.clone(),
        );
        agent.set_persister(Some(Arc::new(EventPersister::new(Arc::clone(&store)))));
        let counter = Arc::new(AtomicI64::new(
            store.get_max_sequence(&session.session.id).unwrap(),
        ));
        let broadcast = Arc::new(EventEmitter::new());
        let mut rx = broadcast.subscribe();

        let result = run_agent(
            &mut agent,
            "do not invoke provider",
            run_context(),
            &broadcast,
            Some(counter),
        )
        .await;

        assert_eq!(result.stop_reason, StopReason::Error);
        assert_eq!(respond_calls.load(Ordering::SeqCst), 0);
        let rows = store
            .get_events_by_session(&session.session.id, &ListEventsOptions::default())
            .unwrap();
        assert!(rows.iter().all(|row| row.event_type != "stream.turn_start"));
        assert!(
            rows.iter()
                .all(|row| row.event_type != "model.provider_request")
        );
        assert!(
            std::iter::from_fn(|| rx.try_recv().ok())
                .all(|event| !matches!(event, TronEvent::TurnStart { .. }))
        );
    }

    #[tokio::test]
    async fn failed_cancellation_terminalization_is_not_reported_as_interrupted_success() {
        use crate::domains::agent::r#loop::orchestrator::event_persister::EventPersister;
        use crate::domains::session::event_store::sqlite::connection::{self, ConnectionConfig};
        use crate::domains::session::event_store::sqlite::migrations::run_migrations;
        use crate::domains::session::event_store::{EventStore, ListEventsOptions};

        let pool = connection::new_in_memory(&ConnectionConfig::default()).unwrap();
        {
            let conn = pool.get().unwrap();
            run_migrations(&conn).unwrap();
            conn.execute_batch(
                "CREATE TRIGGER fail_cancel_terminal
                 BEFORE INSERT ON events
                 WHEN NEW.type = 'turn.failed'
                 BEGIN
                   SELECT RAISE(FAIL, 'forced cancellation terminal failure');
                 END;",
            )
            .unwrap();
        }
        let store = Arc::new(EventStore::new(pool));
        let session = store
            .create_session("mock", "/tmp", Some("cancel failure"), None)
            .unwrap();
        let (mut agent, _journal) = make_agent_with_responder_for_session(
            Arc::new(StreamBackedResponder::new(default_events())),
            session.session.id.clone(),
        );
        agent.set_persister(Some(Arc::new(EventPersister::new(Arc::clone(&store)))));
        let cancel = CancellationToken::new();
        cancel.cancel();
        agent.set_abort_token(cancel);
        let counter = Arc::new(AtomicI64::new(
            store.get_max_sequence(&session.session.id).unwrap(),
        ));
        let broadcast = Arc::new(EventEmitter::new());
        let mut rx = broadcast.subscribe();

        let result = run_agent(
            &mut agent,
            "cancel",
            run_context(),
            &broadcast,
            Some(counter),
        )
        .await;

        assert_eq!(result.stop_reason, StopReason::Error);
        assert!(!result.interrupted);
        assert!(
            result
                .error
                .as_deref()
                .is_some_and(|error| error.contains("failed to persist interrupted turn"))
        );
        let rows = store
            .get_events_by_session(&session.session.id, &ListEventsOptions::default())
            .unwrap();
        assert!(rows.iter().all(|row| row.event_type != "turn.failed"));
        assert!(
            std::iter::from_fn(|| rx.try_recv().ok())
                .all(|event| !matches!(event, TronEvent::TurnFailed { .. }))
        );
    }

    #[tokio::test]
    async fn run_agent_does_not_publish_agent_end() {
        let (mut agent, _journal) = make_agent();
        let broadcast = Arc::new(EventEmitter::new());
        let mut rx = broadcast.subscribe();

        let _ = run_agent(&mut agent, "Hello", run_context(), &broadcast, None).await;

        let mut agent_end_count = 0;
        while let Ok(event) = rx.try_recv() {
            if event.event_type() == "agent_end" {
                agent_end_count += 1;
            }
        }
        assert_eq!(
            agent_end_count, 0,
            "prompt completion owns agent_end, got {agent_end_count} early events"
        );
    }

    #[tokio::test]
    async fn run_agent_error_still_defers_terminal_lifecycle() {
        let (mut agent, _journal) = make_agent_with_responder(Arc::new(
            StreamBackedResponder::new(vec![Err(ModelResponseError::other("expired"))]),
        ));

        let broadcast = Arc::new(EventEmitter::new());
        let mut rx = broadcast.subscribe();

        let result = run_agent(&mut agent, "Hi", run_context(), &broadcast, None).await;
        assert_eq!(result.stop_reason, StopReason::Error);

        let mut saw_terminal = false;
        while let Ok(event) = rx.try_recv() {
            saw_terminal |= matches!(
                event,
                TronEvent::AgentEnd { .. } | TronEvent::AgentReady { .. }
            );
        }
        assert!(!saw_terminal, "prompt completion owns error termination");
    }

    #[tokio::test]
    async fn provider_request_audit_persist_failure_prevents_model_response() {
        use crate::domains::agent::r#loop::orchestrator::event_persister::EventPersister;
        use crate::domains::session::event_store::sqlite::connection::{self, ConnectionConfig};
        use crate::domains::session::event_store::sqlite::migrations::run_migrations;
        use crate::domains::session::event_store::{EventStore, ListEventsOptions};

        let pool = connection::new_in_memory(&ConnectionConfig::default()).unwrap();
        {
            let conn = pool.get().unwrap();
            run_migrations(&conn).unwrap();
            conn.execute_batch(
                "CREATE TRIGGER fail_model_provider_request
                 BEFORE INSERT ON events
                 WHEN NEW.type = 'model.provider_request'
                 BEGIN
                   SELECT RAISE(FAIL, 'forced provider audit failure');
                 END;",
            )
            .unwrap();
        }
        let store = Arc::new(EventStore::new(pool));
        let session = store
            .create_session("mock", "/tmp", Some("audit"), None)
            .unwrap();
        let respond_calls = Arc::new(AtomicUsize::new(0));
        let (mut agent, _journal) = make_agent_with_responder_for_session(
            Arc::new(StreamBackedResponder::new_counted(
                default_events(),
                Arc::clone(&respond_calls),
            )),
            session.session.id.clone(),
        );

        let persister = Arc::new(EventPersister::new(Arc::clone(&store)));
        agent.set_persister(Some(persister));

        let result = run_agent(
            &mut agent,
            "Do not open stream",
            run_context(),
            &Arc::new(EventEmitter::new()),
            None,
        )
        .await;

        assert_eq!(result.stop_reason, StopReason::Error);
        assert_eq!(
            respond_calls.load(Ordering::SeqCst),
            0,
            "model responder must not be called after provider-audit persistence fails"
        );
        let event_types: Vec<_> = store
            .get_events_by_session(&session.session.id, &ListEventsOptions::default())
            .unwrap()
            .into_iter()
            .map(|event| event.event_type)
            .collect();
        assert!(
            event_types
                .iter()
                .any(|event_type| event_type == "stream.turn_start"),
            "the scoped trigger must allow earlier turn persistence"
        );
        assert!(
            !event_types
                .iter()
                .any(|event_type| event_type == "model.provider_request"),
            "failed audit persist must not leave a partial provider request event"
        );
    }

    #[tokio::test]
    async fn provider_request_audit_persists_before_assistant_message() {
        use crate::domains::agent::r#loop::orchestrator::event_persister::EventPersister;
        use crate::domains::session::event_store::sqlite::connection::{self, ConnectionConfig};
        use crate::domains::session::event_store::sqlite::migrations::run_migrations;
        use crate::domains::session::event_store::{EventStore, ListEventsOptions};

        let pool = connection::new_in_memory(&ConnectionConfig::default()).unwrap();
        {
            let conn = pool.get().unwrap();
            run_migrations(&conn).unwrap();
        }
        let store = Arc::new(EventStore::new(pool));
        let session = store
            .create_session("mock", "/tmp", Some("audit"), None)
            .unwrap();
        let respond_calls = Arc::new(AtomicUsize::new(0));
        let (mut agent, _journal) = make_agent_with_responder_for_session(
            Arc::new(StreamBackedResponder::new_counted(
                default_events(),
                Arc::clone(&respond_calls),
            )),
            session.session.id.clone(),
        );
        let persister = Arc::new(EventPersister::new(Arc::clone(&store)));
        agent.set_persister(Some(Arc::clone(&persister)));

        let result = run_agent(
            &mut agent,
            "Persist audit",
            run_context(),
            &Arc::new(EventEmitter::new()),
            None,
        )
        .await;

        assert_eq!(result.stop_reason, StopReason::EndTurn);
        assert_eq!(respond_calls.load(Ordering::SeqCst), 1);
        let rows = store
            .get_events_by_session(&session.session.id, &ListEventsOptions::default())
            .unwrap();
        let audit_sequence = rows
            .iter()
            .find(|event| event.event_type == "model.provider_request")
            .map(|event| event.sequence)
            .expect("provider request audit event must be persisted");
        let assistant_sequence = rows
            .iter()
            .find(|event| event.event_type == "message.assistant")
            .map(|event| event.sequence)
            .expect("assistant message event must be persisted");
        assert!(
            audit_sequence < assistant_sequence,
            "provider request audit sequence {audit_sequence} must precede assistant message sequence {assistant_sequence}"
        );
    }

    #[tokio::test]
    async fn canonical_emitter_receives_all_run_events() {
        let (mut agent, _journal) =
            make_agent_with_responder(Arc::new(StreamBackedResponder::new(vec![
                Ok(StreamEvent::Start),
                Ok(StreamEvent::TextDelta { delta: "a".into() }),
                Ok(StreamEvent::TextDelta { delta: "b".into() }),
                Ok(StreamEvent::TextDelta { delta: "c".into() }),
                Ok(StreamEvent::TextDelta { delta: "d".into() }),
                Ok(StreamEvent::TextDelta { delta: "e".into() }),
                Ok(StreamEvent::Done {
                    message: AssistantMessage {
                        content: vec![AssistantContent::text("abcde")],
                        token_usage: Some(TokenUsage {
                            input_tokens: 10,
                            output_tokens: 5,
                            ..Default::default()
                        }),
                    },
                    stop_reason: "end_turn".into(),
                }),
            ])));

        let broadcast = Arc::new(EventEmitter::new());
        let mut rx = broadcast.subscribe();

        let result = run_agent(&mut agent, "Hi", run_context(), &broadcast, None).await;
        assert_eq!(result.stop_reason, StopReason::EndTurn);

        // Collect all forwarded events
        let mut event_types = vec![];
        while let Ok(event) = rx.try_recv() {
            event_types.push(event.event_type().to_owned());
        }

        // All message_update deltas should be forwarded
        let update_count = event_types
            .iter()
            .filter(|t| *t == "message_update")
            .count();
        assert_eq!(update_count, 5, "all 5 text deltas must be forwarded");
    }

    #[tokio::test]
    async fn canonical_observer_is_lossless_above_broadcast_capacity() {
        const DELTA_COUNT: usize = 1_300;
        let mut events = Vec::with_capacity(DELTA_COUNT + 2);
        events.push(Ok(StreamEvent::Start));
        events.extend((0..DELTA_COUNT).map(|_| {
            Ok(StreamEvent::TextDelta {
                delta: "x".to_owned(),
            })
        }));
        events.push(Ok(StreamEvent::Done {
            message: AssistantMessage {
                content: vec![AssistantContent::text("complete")],
                token_usage: None,
            },
            stop_reason: "end_turn".to_owned(),
        }));
        let (mut agent, _journal) =
            make_agent_with_responder(Arc::new(StreamBackedResponder::new(events)));
        let observer = Arc::new(MessageUpdateObserver::default());
        let broadcast = Arc::new(EventEmitter::with_observer(observer.clone()));

        let result = run_agent(&mut agent, "Hi", run_context(), &broadcast, None).await;

        assert_eq!(result.stop_reason, StopReason::EndTurn);
        assert_eq!(observer.0.load(Ordering::SeqCst), DELTA_COUNT);
    }
}
