//! End-to-end integration tests using a real WebSocket client.

use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use async_trait::async_trait;
use futures::{SinkExt, StreamExt, stream};
use parking_lot::RwLock;
use serde_json::{Value, json};
use tokio::task::JoinHandle;
use tokio::time::timeout;
use tokio_tungstenite::connect_async;
use tokio_tungstenite::tungstenite::Message;

use tron::core::content::AssistantContent;
use tron::core::events::{AssistantMessage, BaseEvent, StreamEvent, TronEvent};
use tron::core::messages::TokenUsage;
use tron::events::{ConnectionConfig, EventStore};
use tron::llm::models::types::Provider as ProviderKind;
use tron::llm::provider::{
    Provider, ProviderError, ProviderFactory, ProviderStreamOptions, StreamEventStream,
};
use tron::runtime::orchestrator::orchestrator::Orchestrator;
use tron::runtime::orchestrator::session_manager::SessionManager;
use tron::server::config::ServerConfig;
use tron::server::rpc::context::{AgentDeps, RpcContext};
use tron::server::rpc::registry::MethodRegistry;
use tron::server::server::TronServer;
use tron::server::websocket::event_bridge::EventBridge;
use tron::skills::registry::SkillRegistry;
use tron::tools::registry::ToolRegistry;

const TIMEOUT: Duration = Duration::from_secs(5);

type WsStream =
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;

/// Boot a test server and return the WS URL + shutdown handle.
async fn boot_server_without_deps() -> (String, Arc<TronServer>) {
    let pool = tron::events::new_in_memory(&ConnectionConfig::default()).unwrap();
    {
        let conn = pool.get().unwrap();
        let _ = tron::events::run_migrations(&conn).unwrap();
        tron::runtime::tasks::migrations::run_migrations(&conn).unwrap();
    }
    let task_pool = pool.clone();
    let event_store = Arc::new(EventStore::new(pool));

    let session_manager = Arc::new(SessionManager::new(event_store.clone()));
    let orchestrator = Arc::new(Orchestrator::new(session_manager.clone(), 10));
    let skill_registry = Arc::new(RwLock::new(SkillRegistry::new()));

    let rpc_context = RpcContext {
        orchestrator: orchestrator.clone(),
        session_manager,
        event_store,
        skill_registry,
        task_pool: Some(task_pool),
        settings_path: PathBuf::from("/tmp/tron-test-settings.json"),
        agent_deps: None,
        server_start_time: std::time::Instant::now(),
        browser_service: None,
        transcription_engine: Arc::new(std::sync::OnceLock::new()),
        subagent_manager: None,
        embedding_controller: None,
        health_tracker: Arc::new(tron::llm::ProviderHealthTracker::new()),
        shutdown_coordinator: None,
        origin: "localhost:9847".to_string(),
        cron_scheduler: None,
        worktree_coordinator: None,
        device_request_broker: None,
        context_artifacts: Arc::new(
            tron::server::rpc::session_context::ContextArtifactsService::new(),
        ),
    };

    let mut registry = MethodRegistry::new();
    tron::server::rpc::handlers::register_all(&mut registry);

    let config = ServerConfig::default(); // port 0 = auto-assign
    let metrics_handle = metrics_exporter_prometheus::PrometheusBuilder::new()
        .build_recorder()
        .handle();
    let server = Arc::new(TronServer::new(
        config,
        registry,
        rpc_context,
        metrics_handle,
    ));

    let bridge = EventBridge::new(
        orchestrator.subscribe(),
        server.broadcast().clone(),
        None,
        server.shutdown().token(),
        orchestrator.turn_accumulators().clone(),
    );
    let _bridge_handle = tokio::spawn(bridge.run());

    let (addr, _handle) = server.listen().await.unwrap();
    let ws_url = format!("ws://{addr}/ws");

    (ws_url, server)
}

/// Boot the default test server with a provider that stays active briefly so
/// busy-session behavior is observable in integration tests.
async fn boot_server() -> (String, Arc<TronServer>) {
    boot_server_with_provider(Arc::new(LaggyTextProvider::new("ok"))).await
}

// ── Mock Providers ──

struct TextOnlyProvider {
    text: String,
}
impl TextOnlyProvider {
    fn new(text: &str) -> Self {
        Self {
            text: text.to_owned(),
        }
    }
}
#[async_trait]
impl Provider for TextOnlyProvider {
    fn provider_type(&self) -> ProviderKind {
        ProviderKind::Anthropic
    }
    fn model(&self) -> &'static str {
        "mock"
    }
    async fn stream(
        &self,
        _c: &tron::core::messages::Context,
        _o: &ProviderStreamOptions,
    ) -> Result<StreamEventStream, ProviderError> {
        let text = self.text.clone();
        let events = vec![
            Ok(StreamEvent::Start),
            Ok(StreamEvent::TextDelta {
                delta: text.clone(),
            }),
            Ok(StreamEvent::Done {
                message: AssistantMessage {
                    content: vec![AssistantContent::text(&text)],
                    token_usage: Some(TokenUsage {
                        input_tokens: 10,
                        output_tokens: 5,
                        ..Default::default()
                    }),
                },
                stop_reason: "end_turn".into(),
            }),
        ];
        Ok(Box::pin(stream::iter(events)))
    }
}

struct LaggyTextProvider {
    text: String,
}
impl LaggyTextProvider {
    fn new(text: &str) -> Self {
        Self {
            text: text.to_owned(),
        }
    }
}
#[async_trait]
impl Provider for LaggyTextProvider {
    fn provider_type(&self) -> ProviderKind {
        ProviderKind::Anthropic
    }
    fn model(&self) -> &'static str {
        "mock"
    }
    async fn stream(
        &self,
        _c: &tron::core::messages::Context,
        _o: &ProviderStreamOptions,
    ) -> Result<StreamEventStream, ProviderError> {
        let text = self.text.clone();
        let s = async_stream::stream! {
            yield Ok(StreamEvent::Start);
            yield Ok(StreamEvent::TextDelta { delta: text.clone() });
            tokio::time::sleep(Duration::from_millis(500)).await;
            yield Ok(StreamEvent::Done {
                message: AssistantMessage {
                    content: vec![AssistantContent::text(&text)],
                    token_usage: Some(TokenUsage::default()),
                },
                stop_reason: "end_turn".into(),
            });
        };
        Ok(Box::pin(s))
    }
}

struct ErrorProvider;
#[async_trait]
impl Provider for ErrorProvider {
    fn provider_type(&self) -> ProviderKind {
        ProviderKind::Anthropic
    }
    fn model(&self) -> &'static str {
        "mock"
    }
    async fn stream(
        &self,
        _c: &tron::core::messages::Context,
        _o: &ProviderStreamOptions,
    ) -> Result<StreamEventStream, ProviderError> {
        Err(ProviderError::Auth {
            message: "token expired".into(),
        })
    }
}

struct SlowProvider;
#[async_trait]
impl Provider for SlowProvider {
    fn provider_type(&self) -> ProviderKind {
        ProviderKind::Anthropic
    }
    fn model(&self) -> &'static str {
        "mock"
    }
    async fn stream(
        &self,
        _c: &tron::core::messages::Context,
        _o: &ProviderStreamOptions,
    ) -> Result<StreamEventStream, ProviderError> {
        let s = async_stream::stream! {
            yield Ok(StreamEvent::Start);
            yield Ok(StreamEvent::TextDelta { delta: "partial...".into() });
            tokio::time::sleep(Duration::from_secs(30)).await;
            yield Ok(StreamEvent::Done {
                message: AssistantMessage {
                    content: vec![AssistantContent::text("partial...")],
                    token_usage: Some(TokenUsage::default()),
                },
                stop_reason: "end_turn".into(),
            });
        };
        Ok(Box::pin(s))
    }
}

struct PanicThenTextProvider {
    has_panicked: AtomicBool,
    text: String,
}

impl PanicThenTextProvider {
    fn new(text: &str) -> Self {
        Self {
            has_panicked: AtomicBool::new(false),
            text: text.to_owned(),
        }
    }
}

#[async_trait]
impl Provider for PanicThenTextProvider {
    fn provider_type(&self) -> ProviderKind {
        ProviderKind::Anthropic
    }

    fn model(&self) -> &'static str {
        "mock"
    }

    async fn stream(
        &self,
        _c: &tron::core::messages::Context,
        _o: &ProviderStreamOptions,
    ) -> Result<StreamEventStream, ProviderError> {
        assert!(
            self.has_panicked.swap(true, Ordering::SeqCst),
            "provider panicked"
        );

        let text = self.text.clone();
        let events = vec![
            Ok(StreamEvent::Start),
            Ok(StreamEvent::TextDelta {
                delta: text.clone(),
            }),
            Ok(StreamEvent::Done {
                message: AssistantMessage {
                    content: vec![AssistantContent::text(&text)],
                    token_usage: Some(TokenUsage::default()),
                },
                stop_reason: "end_turn".into(),
            }),
        ];
        Ok(Box::pin(stream::iter(events)))
    }
}

/// Factory that always returns the same provider instance.
struct FixedProviderFactory(Arc<dyn Provider>);
#[async_trait]
impl ProviderFactory for FixedProviderFactory {
    async fn create_for_model(&self, _model: &str) -> Result<Arc<dyn Provider>, ProviderError> {
        Ok(self.0.clone())
    }
}

/// Boot a test server with an injected LLM provider.
async fn boot_server_with_provider(provider: Arc<dyn Provider>) -> (String, Arc<TronServer>) {
    let (ws_url, server, _handles) = boot_server_with_provider_and_handles(provider).await;
    (ws_url, server)
}

async fn boot_server_with_provider_and_handles(
    provider: Arc<dyn Provider>,
) -> (String, Arc<TronServer>, Vec<JoinHandle<()>>) {
    let pool = tron::events::new_in_memory(&ConnectionConfig::default()).unwrap();
    {
        let conn = pool.get().unwrap();
        let _ = tron::events::run_migrations(&conn).unwrap();
        tron::runtime::tasks::migrations::run_migrations(&conn).unwrap();
    }
    let task_pool = pool.clone();
    let event_store = Arc::new(EventStore::new(pool));

    let session_manager = Arc::new(SessionManager::new(event_store.clone()));
    let orchestrator = Arc::new(Orchestrator::new(session_manager.clone(), 10));
    let skill_registry = Arc::new(RwLock::new(SkillRegistry::new()));

    let rpc_context = RpcContext {
        orchestrator: orchestrator.clone(),
        session_manager,
        event_store,
        skill_registry,
        task_pool: Some(task_pool),
        settings_path: PathBuf::from("/tmp/tron-test-settings.json"),
        agent_deps: Some(AgentDeps {
            provider_factory: Arc::new(FixedProviderFactory(provider)),
            tool_factory: Arc::new(ToolRegistry::new),
            guardrails: None,
            hooks: None,
        }),
        server_start_time: std::time::Instant::now(),
        browser_service: None,
        transcription_engine: Arc::new(std::sync::OnceLock::new()),
        subagent_manager: None,
        embedding_controller: None,
        health_tracker: Arc::new(tron::llm::ProviderHealthTracker::new()),
        shutdown_coordinator: None,
        origin: "localhost:9847".to_string(),
        cron_scheduler: None,
        worktree_coordinator: None,
        device_request_broker: None,
        context_artifacts: Arc::new(
            tron::server::rpc::session_context::ContextArtifactsService::new(),
        ),
    };

    let mut registry = MethodRegistry::new();
    tron::server::rpc::handlers::register_all(&mut registry);

    let config = ServerConfig::default();
    let metrics_handle = metrics_exporter_prometheus::PrometheusBuilder::new()
        .build_recorder()
        .handle();
    let server = Arc::new(TronServer::new(
        config,
        registry,
        rpc_context,
        metrics_handle,
    ));

    let bridge = EventBridge::new(
        orchestrator.subscribe(),
        server.broadcast().clone(),
        None,
        server.shutdown().token(),
        orchestrator.turn_accumulators().clone(),
    );
    let bridge_handle = tokio::spawn(bridge.run());

    let (addr, server_handle) = server.listen().await.unwrap();
    let ws_url = format!("ws://{addr}/ws");

    (ws_url, server, vec![bridge_handle, server_handle])
}

/// Connect and skip the initial system.connected message.
async fn connect(url: &str) -> WsStream {
    let (ws, _) = connect_async(url).await.unwrap();
    ws
}

/// Read the next text message as JSON.
async fn read_json(ws: &mut WsStream) -> Value {
    loop {
        let msg = timeout(TIMEOUT, ws.next())
            .await
            .expect("timeout waiting for message")
            .expect("stream closed")
            .expect("ws error");
        if let Message::Text(text) = msg {
            return serde_json::from_str(&text).unwrap();
        }
    }
}

/// Send a JSON-RPC request and read the response.
async fn rpc_call(ws: &mut WsStream, id: u64, method: &str, params: Option<Value>) -> Value {
    let id_str = format!("r{id}");
    let mut req = json!({"id": id_str, "method": method});
    if let Some(p) = params {
        req["params"] = p;
    }
    ws.send(Message::text(req.to_string())).await.unwrap();

    // Read until we get a response with matching id
    loop {
        let parsed = read_json(ws).await;
        if parsed.get("id").and_then(|v| v.as_str()) == Some(&id_str) {
            return parsed;
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[path = "integration/tests.rs"]
mod tests;
