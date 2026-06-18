//! Background session title generation for new prompt sessions.
//!
//! This service is deliberately metadata-only: it derives a compact title from
//! the initial user prompt, persists it on the session row, and broadcasts a
//! normal `session_updated` event. It does not restore the old hook/subagent
//! surface or add presentation-specific behavior to the runtime.

use std::sync::Arc;
use std::time::Duration;

use futures::StreamExt;
use tokio_util::sync::CancellationToken;
use tracing::{debug, warn};

use crate::app::lifecycle::shutdown::ShutdownCoordinator;
use crate::domains::agent::r#loop::EventEmitter;
use crate::domains::model::responder::{
    ModelReasoningLevel, ModelResponderFactory, ModelResponseError, ModelResponseRequest,
};
use crate::domains::session::event_store::{EventStore, EventType, ListEventsOptions, SessionRow};
use crate::shared::protocol::events::{BaseEvent, StreamEvent, TronEvent};
use crate::shared::protocol::messages::{Context, Message, extract_assistant_text};

const TITLE_GENERATION_TIMEOUT: Duration = Duration::from_secs(20);
const MAX_TITLE_CHARS: usize = 80;
const DEFAULT_SESSION_TITLES: &[&str] = &["chat", "workspace", "untitled", "untitled session"];
const TITLE_LABEL_PREFIXES: &[&str] = &["Title:", "Session title:", "Generated title:"];

pub(super) struct SessionTitleGenerationRequest {
    pub(super) session_id: String,
    pub(super) model: String,
    pub(super) prompt: String,
    pub(super) working_dir: String,
    pub(super) server_origin: String,
}

struct SessionTitleGenerationDeps {
    responder_factory: Arc<dyn ModelResponderFactory>,
    event_store: Arc<EventStore>,
    broadcast: Arc<EventEmitter>,
}

struct SessionTitleGenerationJob {
    deps: SessionTitleGenerationDeps,
    request: SessionTitleGenerationRequest,
    cancel: CancellationToken,
}

pub(super) fn spawn_session_title_generation(
    responder_factory: Arc<dyn ModelResponderFactory>,
    event_store: Arc<EventStore>,
    broadcast: Arc<EventEmitter>,
    shutdown_coordinator: Option<Arc<ShutdownCoordinator>>,
    request: SessionTitleGenerationRequest,
) {
    let cancel = shutdown_coordinator
        .as_ref()
        .map_or_else(CancellationToken::new, |coordinator| coordinator.token());
    let task_cancel = cancel.clone();
    let session_id = request.session_id.clone();
    let deps = SessionTitleGenerationDeps {
        responder_factory,
        event_store,
        broadcast,
    };
    let handle = tokio::spawn(async move {
        if task_cancel.is_cancelled() {
            return;
        }
        let completed = tokio::time::timeout(
            TITLE_GENERATION_TIMEOUT,
            run_session_title_generation(SessionTitleGenerationJob {
                deps,
                request,
                cancel: task_cancel,
            }),
        )
        .await;

        if completed.is_err() {
            warn!(
                session_id = %session_id,
                "session title generation timed out"
            );
        }
    });

    if let Some(coordinator) = shutdown_coordinator {
        coordinator.register_task(handle);
    }
}

async fn run_session_title_generation(job: SessionTitleGenerationJob) -> bool {
    let SessionTitleGenerationJob {
        deps:
            SessionTitleGenerationDeps {
                responder_factory,
                event_store,
                broadcast,
            },
        request,
        cancel,
    } = job;
    let session_id = request.session_id;
    let Ok(Some(session)) = event_store.get_session(&session_id) else {
        return false;
    };
    if !session_can_accept_generated_title(&event_store, &session) {
        return false;
    }

    let title = match generate_title(
        responder_factory,
        &session_id,
        &request.model,
        &request.prompt,
        &request.working_dir,
        &request.server_origin,
        cancel,
    )
    .await
    {
        Ok(Some(title)) => title,
        Ok(None) => return false,
        Err(error) => {
            if !error.is_cancelled() {
                warn!(
                    session_id = %session_id,
                    error = %error,
                    "session title generation failed"
                );
            }
            return false;
        }
    };

    let Ok(Some(current)) = event_store.get_session(&session_id) else {
        return false;
    };
    if !session_can_accept_generated_title(&event_store, &current) {
        debug!(
            session_id = %session_id,
            "session title generation skipped because the session is no longer titleable"
        );
        return false;
    }

    match event_store.update_session_title(&session_id, Some(&title)) {
        Ok(true) => {
            emit_title_update(&broadcast, &current, title);
            true
        }
        Ok(false) => false,
        Err(error) => {
            warn!(
                session_id = %session_id,
                error = %error,
                "failed to persist generated session title"
            );
            false
        }
    }
}

async fn generate_title(
    responder_factory: Arc<dyn ModelResponderFactory>,
    session_id: &str,
    model: &str,
    prompt: &str,
    working_dir: &str,
    server_origin: &str,
    cancel: CancellationToken,
) -> Result<Option<String>, ModelResponseError> {
    let responder = responder_factory.create_for_model(model).await?;
    let request = ModelResponseRequest {
        context: Context {
            system_prompt: Some(title_generation_system_prompt().to_owned()),
            messages: Arc::from(vec![Message::user(prompt)]),
            capabilities: None,
            working_directory: Some(working_dir.to_owned()),
            agent_state_context: None,
            server_origin: Some(server_origin.to_owned()),
        },
        session_id: session_id.to_owned(),
        reasoning_level: Some(ModelReasoningLevel::None),
        cancel,
        retry_config: None,
    };
    let mut response = responder.respond(request).await?;
    let mut text = String::new();

    while let Some(event) = response.stream.next().await {
        match event? {
            StreamEvent::TextDelta { delta } => text.push_str(&delta),
            StreamEvent::TextEnd {
                text: completed, ..
            } if text.trim().is_empty() => {
                text = completed;
            }
            StreamEvent::Done { message, .. } if text.trim().is_empty() => {
                text = extract_assistant_text(&message.content);
            }
            StreamEvent::Error { error } => return Err(ModelResponseError::other(error)),
            _ => {}
        }
    }

    Ok(clean_generated_title(&text))
}

fn title_generation_system_prompt() -> &'static str {
    "Create a concise session title from the user's first prompt.\n\
     Rules:\n\
     - Return only the title.\n\
     - Use 3 to 6 words when possible.\n\
     - No quotes, punctuation-only endings, markdown, labels, or explanation.\n\
     - Preserve important file, product, or feature names."
}

fn session_needs_generated_title(title: Option<&str>) -> bool {
    let Some(title) = title.map(str::trim).filter(|title| !title.is_empty()) else {
        return true;
    };

    let normalized = title.to_ascii_lowercase();
    DEFAULT_SESSION_TITLES.contains(&normalized.as_str())
}

fn session_can_accept_generated_title(event_store: &EventStore, session: &SessionRow) -> bool {
    session_needs_generated_title(session.title.as_deref())
        && initial_user_prompt_count(event_store, &session.id) == Some(1)
}

fn initial_user_prompt_count(event_store: &EventStore, session_id: &str) -> Option<usize> {
    match event_store.get_events_by_session(session_id, &ListEventsOptions::default()) {
        Ok(events) => Some(
            events
                .iter()
                .filter(|event| event.event_type == EventType::MessageUser.as_str())
                .count(),
        ),
        Err(error) => {
            warn!(
                session_id,
                error = %error,
                "failed to inspect user prompt count for session title generation"
            );
            None
        }
    }
}

fn clean_generated_title(raw: &str) -> Option<String> {
    let mut title = raw
        .lines()
        .find_map(|line| {
            let trimmed = line.trim();
            (!trimmed.is_empty()).then_some(trimmed)
        })?
        .trim_start_matches(|char| matches!(char, '-' | '*' | '#' | ' '))
        .trim_matches(|char| matches!(char, '"' | '\'' | '`'))
        .trim();

    for &prefix in TITLE_LABEL_PREFIXES {
        if title
            .get(..prefix.len())
            .is_some_and(|candidate| candidate.eq_ignore_ascii_case(prefix))
        {
            title = title[prefix.len()..].trim();
        }
    }

    let title = title
        .trim_matches(|char| matches!(char, '"' | '\'' | '`'))
        .trim_end_matches(|char| matches!(char, '.' | ':' | ';'))
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ");

    let mut bounded = String::new();
    for char in title.chars() {
        if bounded.chars().count() >= MAX_TITLE_CHARS {
            break;
        }
        bounded.push(char);
    }

    let cleaned = bounded.trim().to_owned();
    (!cleaned.is_empty() && !session_needs_generated_title(Some(&cleaned))).then_some(cleaned)
}

fn emit_title_update(broadcast: &Arc<EventEmitter>, session: &SessionRow, title: String) {
    let _ = broadcast.emit(TronEvent::SessionUpdated {
        base: BaseEvent::now(&session.id),
        title: Some(title),
        model: Some(session.latest_model.clone()),
        event_count: Some(session.event_count),
        turn_count: Some(session.turn_count),
        message_count: Some(session.message_count),
        input_tokens: Some(session.total_input_tokens),
        output_tokens: Some(session.total_output_tokens),
        last_turn_input_tokens: Some(session.last_turn_input_tokens),
        cache_read_tokens: Some(session.total_cache_read_tokens),
        cache_creation_tokens: Some(session.total_cache_creation_tokens),
        cost: Some(session.total_cost),
        last_activity: session.last_activity_at.clone(),
        is_active: false,
        last_user_prompt: None,
        last_assistant_response: None,
        parent_session_id: session.parent_session_id.clone(),
        activity_lines: None,
    });
}

#[cfg(test)]
mod tests {
    use std::pin::Pin;

    use async_trait::async_trait;
    use futures::{Stream, stream};

    use super::*;
    use crate::domains::model::responder::{
        ModelResponder, ModelResponderInfo, ModelResponse, ModelResponseStream,
    };
    use crate::domains::session::event_store::{
        AppendOptions, ConnectionConfig, EventType, new_in_memory, run_migrations,
    };
    use crate::shared::protocol::content::AssistantContent;
    use crate::shared::protocol::events::AssistantMessage;
    use crate::shared::protocol::messages::Provider;

    #[test]
    fn clean_generated_title_strips_labels_quotes_and_bounds_length() {
        assert_eq!(
            clean_generated_title("\"Title: Review Composer Attachments.\""),
            Some("Review Composer Attachments".to_owned())
        );
        assert_eq!(
            clean_generated_title("- Session title: Harden Local Transcription"),
            Some("Harden Local Transcription".to_owned())
        );
        assert_eq!(clean_generated_title("Workspace"), None);
        assert_eq!(
            clean_generated_title(
                "This generated title is intentionally long enough to exceed the hard maximum title character budget by a healthy margin"
            )
            .unwrap()
            .chars()
            .count(),
            MAX_TITLE_CHARS
        );
    }

    #[test]
    fn session_needs_generated_title_only_allows_empty_or_default_titles() {
        assert!(session_needs_generated_title(None));
        assert!(session_needs_generated_title(Some("")));
        assert!(session_needs_generated_title(Some("Chat")));
        assert!(session_needs_generated_title(Some("Workspace")));
        assert!(!session_needs_generated_title(Some(
            "Implement Runtime Changes"
        )));
    }

    #[tokio::test]
    async fn run_session_title_generation_persists_and_broadcasts_title() {
        let store = Arc::new(setup_event_store());
        let created = store
            .create_session("mock-title", "/tmp/project", None, None)
            .unwrap();
        append_user_message(
            &store,
            &created.session.id,
            "please implement the runtime changes",
        );
        let emitter = Arc::new(EventEmitter::new());
        let mut receiver = emitter.subscribe();

        let updated = run_title_generation(
            store.clone(),
            emitter,
            &created.session.id,
            "please implement the runtime changes",
            "Implement Runtime Changes",
        )
        .await;

        assert!(updated);
        let session = store.get_session(&created.session.id).unwrap().unwrap();
        assert_eq!(session.title.as_deref(), Some("Implement Runtime Changes"));

        let event = receiver.recv().await.unwrap();
        match event {
            TronEvent::SessionUpdated { title, .. } => {
                assert_eq!(title.as_deref(), Some("Implement Runtime Changes"));
            }
            other => panic!("unexpected event: {other:?}"),
        }
    }

    #[tokio::test]
    async fn run_session_title_generation_preserves_existing_title() {
        let store = Arc::new(setup_event_store());
        let created = store
            .create_session("mock-title", "/tmp/project", Some("Existing Title"), None)
            .unwrap();
        append_user_message(&store, &created.session.id, "please replace");
        let emitter = Arc::new(EventEmitter::new());

        let updated = run_title_generation(
            store.clone(),
            emitter,
            &created.session.id,
            "please replace",
            "Replacement",
        )
        .await;

        assert!(!updated);
        let session = store.get_session(&created.session.id).unwrap().unwrap();
        assert_eq!(session.title.as_deref(), Some("Existing Title"));
    }

    #[tokio::test]
    async fn run_session_title_generation_allows_fast_assistant_response() {
        let store = Arc::new(setup_event_store());
        let created = store
            .create_session("mock-title", "/tmp/project", None, None)
            .unwrap();
        append_user_message(&store, &created.session.id, "summarize the architecture");
        append_assistant_message(&store, &created.session.id, "sure");
        let emitter = Arc::new(EventEmitter::new());

        let updated = run_title_generation(
            store.clone(),
            emitter,
            &created.session.id,
            "summarize the architecture",
            "Summarize Architecture",
        )
        .await;

        assert!(updated);
        let session = store.get_session(&created.session.id).unwrap().unwrap();
        assert_eq!(session.title.as_deref(), Some("Summarize Architecture"));
    }

    #[tokio::test]
    async fn run_session_title_generation_requires_persisted_user_message() {
        let store = Arc::new(setup_event_store());
        let created = store
            .create_session("mock-title", "/tmp/project", None, None)
            .unwrap();
        let emitter = Arc::new(EventEmitter::new());

        let updated = run_title_generation(
            store.clone(),
            emitter,
            &created.session.id,
            "not yet persisted",
            "Missing Prompt Title",
        )
        .await;

        assert!(!updated);
        let session = store.get_session(&created.session.id).unwrap().unwrap();
        assert_eq!(session.title, None);
    }

    #[tokio::test]
    async fn run_session_title_generation_skips_after_initial_user_turn() {
        let store = Arc::new(setup_event_store());
        let created = store
            .create_session("mock-title", "/tmp/project", None, None)
            .unwrap();
        append_user_message(&store, &created.session.id, "first prompt");
        append_user_message(&store, &created.session.id, "second prompt");
        let emitter = Arc::new(EventEmitter::new());

        let updated = run_title_generation(
            store.clone(),
            emitter,
            &created.session.id,
            "second prompt",
            "Late Prompt Title",
        )
        .await;

        assert!(!updated);
        let session = store.get_session(&created.session.id).unwrap().unwrap();
        assert_eq!(session.title, None);
    }

    fn setup_event_store() -> EventStore {
        let pool = new_in_memory(&ConnectionConfig::default()).unwrap();
        {
            let conn = pool.get().unwrap();
            run_migrations(&conn).unwrap();
        }
        EventStore::new(pool)
    }

    async fn run_title_generation(
        store: Arc<EventStore>,
        emitter: Arc<EventEmitter>,
        session_id: &str,
        prompt: &str,
        generated_title: &str,
    ) -> bool {
        run_session_title_generation(SessionTitleGenerationJob {
            deps: SessionTitleGenerationDeps {
                responder_factory: Arc::new(StaticTitleFactory(generated_title.to_owned())),
                event_store: store,
                broadcast: emitter,
            },
            request: SessionTitleGenerationRequest {
                session_id: session_id.to_owned(),
                model: "mock-title".to_owned(),
                prompt: prompt.to_owned(),
                working_dir: "/tmp/project".to_owned(),
                server_origin: "localhost:9847".to_owned(),
            },
            cancel: CancellationToken::new(),
        })
        .await
    }

    fn append_user_message(store: &EventStore, session_id: &str, prompt: &str) {
        store
            .append(&AppendOptions {
                session_id,
                event_type: EventType::MessageUser,
                payload: serde_json::json!({ "content": prompt }),
                parent_id: None,
                sequence: None,
            })
            .unwrap();
    }

    fn append_assistant_message(store: &EventStore, session_id: &str, response: &str) {
        store
            .append(&AppendOptions {
                session_id,
                event_type: EventType::MessageAssistant,
                payload: serde_json::json!({
                    "content": [{ "type": "text", "text": response }]
                }),
                parent_id: None,
                sequence: None,
            })
            .unwrap();
    }

    struct StaticTitleFactory(String);

    #[async_trait]
    impl ModelResponderFactory for StaticTitleFactory {
        async fn create_for_model(
            &self,
            model: &str,
        ) -> Result<Arc<dyn ModelResponder>, ModelResponseError> {
            Ok(Arc::new(StaticTitleResponder {
                model: model.to_owned(),
                title: self.0.clone(),
            }))
        }
    }

    struct StaticTitleResponder {
        model: String,
        title: String,
    }

    #[async_trait]
    impl ModelResponder for StaticTitleResponder {
        fn info(&self) -> ModelResponderInfo {
            ModelResponderInfo {
                provider_type: Provider::Anthropic,
                provider_name: "anthropic",
                model: self.model.clone(),
                context_window: 200_000,
            }
        }

        async fn respond(
            &self,
            _request: ModelResponseRequest,
        ) -> Result<ModelResponse, ModelResponseError> {
            let title = self.title.clone();
            let events = vec![
                Ok(StreamEvent::TextDelta {
                    delta: title.clone(),
                }),
                Ok(StreamEvent::Done {
                    message: AssistantMessage {
                        content: vec![AssistantContent::text(title)],
                        token_usage: None,
                    },
                    stop_reason: "end_turn".to_owned(),
                }),
            ];
            let output: Pin<
                Box<dyn Stream<Item = Result<StreamEvent, ModelResponseError>> + Send>,
            > = Box::pin(stream::iter(events));
            let stream: ModelResponseStream = output;

            Ok(ModelResponse {
                info: self.info(),
                stream,
            })
        }
    }
}
