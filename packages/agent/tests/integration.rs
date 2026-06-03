//! End-to-end integration tests using a real WebSocket client.

use std::collections::HashMap;
use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash, Hasher};
#[cfg(unix)]
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, LazyLock, Mutex};
use std::time::Duration;

use async_trait::async_trait;
use futures::{SinkExt, StreamExt, stream};
use parking_lot::RwLock;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use tokio::task::JoinHandle;
use tokio::time::timeout;
use tokio_tungstenite::connect_async;
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;

use tron::app::config::ServerConfig;
use tron::app::server::TronServer;
use tron::domains::agent::runner::orchestrator::orchestrator::Orchestrator;
use tron::domains::agent::runner::orchestrator::session_manager::SessionManager;
use tron::domains::model::providers::models::types::Provider as ProviderKind;
use tron::domains::model::providers::provider::{
    Provider, ProviderError, ProviderFactory, ProviderStreamOptions, StreamEventStream,
};
use tron::domains::session::event_store::{ConnectionConfig, EventStore};
use tron::domains::skills::registry::SkillRegistry;
use tron::engine::{
    ActorId, ActorKind, AuthorityGrantId, CausalContext, EffectClass, FunctionDefinition,
    FunctionId, Invocation, Provenance, RiskLevel, TraceId, VisibilityScope, WorkerDefinition,
    WorkerInvocationResult, WorkerKind, WorkerProtocolMessage,
};
use tron::shared::content::AssistantContent;
use tron::shared::events::{AssistantMessage, BaseEvent, StreamEvent, TronEvent};
use tron::shared::messages::{
    CapabilityInvocationDraft, CapabilityResultMessageContent, Context as ModelContext,
    Message as ModelMessage, TokenUsage,
};
use tron::shared::server::context::{AgentDeps, ServerRuntimeContext};
use tron::transport::runtime::streams::EngineStreamEventPump;

const TIMEOUT: Duration = Duration::from_secs(5);
static TEST_PATH_COUNTER: AtomicU64 = AtomicU64::new(0);
static TEST_SERVER_AUTH_PATHS: LazyLock<Mutex<HashMap<String, PathBuf>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

type WsStream =
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;

fn unique_test_path(name: &str, extension: &str) -> PathBuf {
    let id = TEST_PATH_COUNTER.fetch_add(1, Ordering::Relaxed);
    std::env::temp_dir().join(format!(
        "tron-integration-{name}-{}-{id}.{extension}",
        std::process::id()
    ))
}

fn unique_settings_path() -> PathBuf {
    let dir = unique_test_path("tron-home", "dir");
    let home = dir.join(".tron");
    tron::shared::constitution::ensure_tron_home_at(&home).unwrap();
    home.join(tron::shared::paths::dirs::PROFILES)
        .join(tron::shared::profile::USER_PROFILE)
        .join(tron::shared::paths::files::PROFILE_TOML)
}

fn unique_runtime_path(name: &str, extension: &str) -> PathBuf {
    let path = unique_test_path(name, extension);
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).unwrap();
    }
    path
}

fn unique_event_store() -> Arc<EventStore> {
    let db_path = unique_runtime_path("events", "db");
    let pool = tron::domains::session::event_store::new_file(
        &db_path.to_string_lossy(),
        &ConnectionConfig::default(),
    )
    .unwrap_or_else(|error| panic!("failed to open {}: {error}", db_path.display()));
    {
        let conn = pool.get().unwrap();
        let _ = tron::domains::session::event_store::run_migrations(&conn).unwrap();
    }
    Arc::new(EventStore::new(pool))
}

fn profile_runtime_for_settings_path(
    path: &std::path::Path,
) -> Arc<tron::domains::agent::runner::ProfileRuntime> {
    let home = path
        .ancestors()
        .nth(3)
        .expect("settings path must be profiles/user/profile.toml");
    Arc::new(tron::domains::agent::runner::ProfileRuntime::load(home).unwrap())
}

/// Boot a test server and return the WS URL + shutdown handle.
async fn boot_server_without_deps() -> (String, Arc<TronServer>) {
    boot_server_without_deps_with_config(ServerConfig::default(), "localhost:9847".to_owned()).await
}

async fn boot_server_without_deps_with_config(
    config: ServerConfig,
    origin: String,
) -> (String, Arc<TronServer>) {
    let event_store = unique_event_store();

    let session_manager = Arc::new(SessionManager::new(event_store.clone()));
    let orchestrator = Arc::new(Orchestrator::new(session_manager.clone()));
    let skill_registry = Arc::new(RwLock::new(SkillRegistry::new()));
    let settings_path = unique_settings_path();
    tron::domains::settings::reload_settings_from_path(&settings_path).unwrap();

    let runtime_context = ServerRuntimeContext {
        orchestrator: orchestrator.clone(),
        session_manager,
        event_store,
        engine_host: tron::engine::EngineHostHandle::new_in_memory().unwrap(),
        skill_registry,
        memory_registry: Arc::new(parking_lot::Mutex::new(
            tron::domains::agent::runner::memory::MemoryRegistry::new(),
        )),
        profile_runtime: profile_runtime_for_settings_path(&settings_path),
        settings_path,
        agent_deps: None,
        capability_support_config: tron::shared::server::context::CapabilitySupportConfig::default(
        ),
        server_start_time: std::time::Instant::now(),
        transcription_engine: Arc::new(std::sync::OnceLock::new()),
        subagent_manager: None,
        health_tracker: Arc::new(tron::domains::model::providers::ProviderHealthTracker::new()),
        shutdown_coordinator: None,
        origin,
        cron_scheduler: None,
        worktree_coordinator: None,
        device_request_broker: None,
        context_artifacts: Arc::new(
            tron::domains::session::context::ContextArtifactsService::new(),
        ),
        auth_path: unique_runtime_path("auth", "json"),
        oauth_flows: Arc::new(tokio::sync::Mutex::new(std::collections::HashMap::new())),
        mcp_router: None,
        display_stream_registry: None,
        process_manager: None,
        job_manager: None,
        output_buffer_registry: None,
        hook_abort_tracker: Arc::new(
            tron::domains::agent::runner::hooks::abort_tracker::HookAbortTracker::new(),
        ),
        ws_port: Arc::new(std::sync::atomic::AtomicU16::new(0)),
        onboarded_marker_path: unique_runtime_path("onboarded", "marker"),
        release_fetcher: None,
        updater_state_path: unique_runtime_path("updater-state", "json"),
    };

    let metrics_handle = metrics_exporter_prometheus::PrometheusBuilder::new()
        .build_recorder()
        .handle();
    let server = Arc::new(TronServer::new(config, runtime_context, metrics_handle));
    tron::transport::setup::register_server_domains_for_context(server.runtime_context())
        .expect("integration engine protocol should register");
    tron::transport::runtime::EngineRuntimeServices::start(&server);

    let pump = EngineStreamEventPump::new(
        orchestrator.subscribe(),
        server.runtime_context().engine_host.clone(),
        server.shutdown().token(),
        orchestrator.turn_accumulators().clone(),
    );
    let _stream_event_pump_handle = tokio::spawn(pump.run());

    let (addr, _handle) = server.listen().await.unwrap();
    let ws_url = format!("ws://{addr}/engine");
    register_server_auth_path(&ws_url, &server.runtime_context().auth_path);

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
        _c: &tron::shared::messages::Context,
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

#[derive(Clone, Debug)]
struct HmhEvidenceExplanationScenario {
    function_id: String,
    worker_id: String,
    plugin_id: String,
    implementation_id: String,
    evidence_resource_id: String,
    evidence_version_id: String,
    evidence_trace_id: String,
    evidence_parent_invocation_id: String,
    next_test: String,
}

struct EvidenceExplainingProvider {
    scenario: Mutex<Option<HmhEvidenceExplanationScenario>>,
    call_count: AtomicU64,
    final_answer: Mutex<Option<String>>,
}

impl EvidenceExplainingProvider {
    fn new() -> Self {
        Self {
            scenario: Mutex::new(None),
            call_count: AtomicU64::new(0),
            final_answer: Mutex::new(None),
        }
    }

    fn set_scenario(&self, scenario: HmhEvidenceExplanationScenario) {
        *self.scenario.lock().unwrap() = Some(scenario);
    }

    fn final_answer(&self) -> Option<String> {
        self.final_answer.lock().unwrap().clone()
    }
}

fn is_hmh_title_hook_turn(context: &ModelContext) -> bool {
    hmh_user_context_contains(context, "Generate a 3-5 word title")
}

fn is_hmh_branch_name_hook_turn(context: &ModelContext) -> bool {
    hmh_user_context_contains(context, "Generate a random memorable 3-word branch name")
}

fn is_hmh_suggestion_hook_turn(context: &ModelContext) -> bool {
    hmh_user_context_contains(context, "generate 3-5 short follow-up prompts")
}

fn hmh_user_context_contains(context: &ModelContext, expected: &str) -> bool {
    context.messages.iter().any(|message| match message {
        ModelMessage::User { content, .. } => format!("{content:?}").contains(expected),
        _ => false,
    })
}

#[async_trait]
impl Provider for EvidenceExplainingProvider {
    fn provider_type(&self) -> ProviderKind {
        ProviderKind::Anthropic
    }

    fn model(&self) -> &'static str {
        "mock"
    }

    async fn stream(
        &self,
        context: &ModelContext,
        _o: &ProviderStreamOptions,
    ) -> Result<StreamEventStream, ProviderError> {
        if is_hmh_title_hook_turn(context) {
            return Ok(hmh_text_stream("Explaining worker evidence"));
        }
        if is_hmh_branch_name_hook_turn(context) {
            return Ok(hmh_text_stream("steady-worker-evidence"));
        }
        if is_hmh_suggestion_hook_turn(context) {
            return Ok(hmh_text_stream(
                "Inspect evidence refs\nRerun conformance proof\nCheck worker cleanup",
            ));
        }
        let scenario = self
            .scenario
            .lock()
            .unwrap()
            .clone()
            .expect("HMH evidence explanation scenario must be configured before prompting");
        match self.call_count.fetch_add(1, Ordering::SeqCst) {
            0 => Ok(hmh_evidence_inspect_stream(&scenario)),
            1 => {
                let answer = hmh_evidence_answer_from_context(context, &scenario);
                *self.final_answer.lock().unwrap() = Some(answer.clone());
                let events = vec![
                    Ok(StreamEvent::Start),
                    Ok(StreamEvent::TextDelta {
                        delta: answer.clone(),
                    }),
                    Ok(StreamEvent::Done {
                        message: AssistantMessage {
                            content: vec![AssistantContent::text(&answer)],
                            token_usage: Some(TokenUsage {
                                input_tokens: 30,
                                output_tokens: 20,
                                ..Default::default()
                            }),
                        },
                        stop_reason: "end_turn".into(),
                    }),
                ];
                Ok(Box::pin(stream::iter(events)))
            }
            call => panic!("HMH evidence explanation provider called too many times: {call}"),
        }
    }
}

fn hmh_text_stream(text: &str) -> StreamEventStream {
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

fn hmh_evidence_inspect_stream(scenario: &HmhEvidenceExplanationScenario) -> StreamEventStream {
    let mut arguments = serde_json::Map::new();
    arguments.insert("target".to_owned(), json!("resource::inspect"));
    arguments.insert(
        "arguments".to_owned(),
        json!({"resourceId": scenario.evidence_resource_id}),
    );
    arguments.insert(
        "idempotencyKey".to_owned(),
        json!("hmh-b9-agent-inspect-evidence-resource"),
    );
    arguments.insert(
        "reason".to_owned(),
        json!("HMH-B9 inspect live conformance evidence before explaining"),
    );
    let invocation =
        CapabilityInvocationDraft::new("hmh-b9-inspect-evidence", "execute", arguments.clone());
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
                    input_tokens: 25,
                    output_tokens: 10,
                    ..Default::default()
                }),
            },
            stop_reason: "capability_invocation".into(),
        }),
    ];
    Box::pin(stream::iter(events))
}

fn hmh_evidence_answer_from_context(
    context: &ModelContext,
    scenario: &HmhEvidenceExplanationScenario,
) -> String {
    let inspection = hmh_single_execute_output(context, &scenario.evidence_resource_id);
    assert_eq!(
        inspection["inspection"]["resource"]["resourceId"],
        scenario.evidence_resource_id
    );
    assert_eq!(
        inspection["inspection"]["resource"]["currentVersionId"],
        scenario.evidence_version_id
    );
    let payload = &inspection["inspection"]["versions"][0]["payload"];
    assert_eq!(payload["source"], "capability::conformance_run");
    assert_eq!(payload["target"]["pluginId"], scenario.plugin_id);
    assert_eq!(
        payload["target"]["implementationIds"],
        json!([scenario.implementation_id.as_str()])
    );
    assert_eq!(
        payload["target"]["functionIds"],
        json!([scenario.function_id.as_str()])
    );
    assert_eq!(
        payload["target"]["workerIds"],
        json!([scenario.worker_id.as_str()])
    );
    assert_eq!(payload["metadata"]["traceId"], scenario.evidence_trace_id);
    assert_eq!(
        payload["metadata"]["parentInvocationId"],
        scenario.evidence_parent_invocation_id
    );

    let context_text = hmh_context_text(context);
    for required in [
        scenario.function_id.as_str(),
        scenario.worker_id.as_str(),
        scenario.plugin_id.as_str(),
        scenario.implementation_id.as_str(),
        scenario.evidence_resource_id.as_str(),
        scenario.evidence_version_id.as_str(),
        scenario.evidence_trace_id.as_str(),
        scenario.evidence_parent_invocation_id.as_str(),
        "resource::inspect",
        "executeInvocationId",
        "childInvocationIds",
    ] {
        assert!(
            context_text.contains(required),
            "model context missing HMH-B9 evidence marker `{required}`: {context_text}"
        );
    }
    let inspection_text = inspection.to_string();
    assert!(
        !inspection_text.contains("README-only"),
        "HMH-B9 inspected evidence must not rely on stale README-only explanation"
    );

    format!(
        "HMH-B9 evidence: capability {function_id} is implemented by {implementation_id} in plugin {plugin_id} on worker {worker_id}. Evidence resourceRefs include evidence:{resource_id}@{version_id}. Trace/ledger ids: traceId={trace_id}, parentInvocationId={parent_invocation_id}, and the execute observation exposes executeInvocationId plus childInvocationIds for the resource::inspect proof. Next maintenance actions: rerun capability::conformance_run before promotion, cite resourceRefs and trace ids in user-facing explanations, promote only with expectedFunctionRevision and explicit idempotency, clean up volatile workers with sandbox::stop_spawned_worker or worker::disconnect, and continue with `{next_test}`.",
        function_id = scenario.function_id.as_str(),
        implementation_id = scenario.implementation_id.as_str(),
        plugin_id = scenario.plugin_id.as_str(),
        worker_id = scenario.worker_id.as_str(),
        resource_id = scenario.evidence_resource_id.as_str(),
        version_id = scenario.evidence_version_id.as_str(),
        trace_id = scenario.evidence_trace_id.as_str(),
        parent_invocation_id = scenario.evidence_parent_invocation_id.as_str(),
        next_test = scenario.next_test.as_str(),
    )
}

fn hmh_single_execute_output(context: &ModelContext, expected_resource_id: &str) -> Value {
    hmh_execute_outputs(context)
        .into_iter()
        .find(|output| {
            output
                .pointer("/inspection/resource/resourceId")
                .and_then(Value::as_str)
                == Some(expected_resource_id)
        })
        .unwrap_or_else(|| {
            panic!(
                "provider context did not include inspected evidence resource {expected_resource_id}: {}",
                hmh_context_text(context)
            )
        })
}

fn hmh_execute_outputs(context: &ModelContext) -> Vec<Value> {
    context
        .messages
        .iter()
        .filter_map(|message| match message {
            ModelMessage::CapabilityResult { content, .. } => {
                Some(hmh_capability_result_text(content))
            }
            _ => None,
        })
        .flat_map(|text| hmh_execute_outputs_from_text(&text))
        .collect()
}

fn hmh_capability_result_text(content: &CapabilityResultMessageContent) -> String {
    match content {
        CapabilityResultMessageContent::Text(text) => text.clone(),
        CapabilityResultMessageContent::Blocks(blocks) => blocks
            .iter()
            .filter_map(|block| match block {
                tron::shared::content::CapabilityResultContent::Text { text } => {
                    Some(text.as_str())
                }
                tron::shared::content::CapabilityResultContent::Image { .. } => None,
            })
            .collect::<Vec<_>>()
            .join("\n"),
    }
}

fn hmh_execute_outputs_from_text(text: &str) -> Vec<Value> {
    const START: &str = "[execute result - exact target output or status text]\n";
    const END: &str = "\n[/execute result]";
    let mut outputs = Vec::new();
    let mut rest = text;
    while let Some(start) = rest.find(START) {
        let after_start = &rest[start + START.len()..];
        let Some(end) = after_start.find(END) else {
            break;
        };
        let json_text = &after_start[..end];
        if let Ok(value) = serde_json::from_str::<Value>(json_text) {
            outputs.push(value);
        }
        rest = &after_start[end + END.len()..];
    }
    outputs
}

fn hmh_context_text(context: &ModelContext) -> String {
    serde_json::to_string_pretty(context).unwrap_or_else(|_| "<unserializable context>".to_owned())
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
        _c: &tron::shared::messages::Context,
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
        _c: &tron::shared::messages::Context,
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
        _c: &tron::shared::messages::Context,
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
        _c: &tron::shared::messages::Context,
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
    boot_server_with_provider_config_and_handles(
        provider,
        ServerConfig::default(),
        "localhost:9847".to_string(),
    )
    .await
}

async fn boot_server_with_provider_config_and_handles(
    provider: Arc<dyn Provider>,
    config: ServerConfig,
    origin: String,
) -> (String, Arc<TronServer>, Vec<JoinHandle<()>>) {
    let event_store = unique_event_store();

    let session_manager = Arc::new(SessionManager::new(event_store.clone()));
    let orchestrator = Arc::new(Orchestrator::new(session_manager.clone()));
    let skill_registry = Arc::new(RwLock::new(SkillRegistry::new()));
    let settings_path = unique_settings_path();
    tron::domains::settings::reload_settings_from_path(&settings_path).unwrap();
    let profile_runtime = profile_runtime_for_settings_path(&settings_path);
    let provider_factory: Arc<dyn ProviderFactory> = Arc::new(FixedProviderFactory(provider));
    let engine_host = tron::engine::EngineHostHandle::new_in_memory().unwrap();
    let subagent_manager = Arc::new(
        tron::domains::agent::runner::orchestrator::subagent_manager::SubagentManager::new(
            session_manager.clone(),
            event_store.clone(),
            orchestrator.broadcast().clone(),
            provider_factory.clone(),
            profile_runtime.clone(),
            None,
            None,
        ),
    );
    subagent_manager.set_self_ref();
    subagent_manager.set_run_state_probe(orchestrator.run_state_probe());
    subagent_manager.set_skill_registry(skill_registry.clone());
    subagent_manager.set_engine_host(engine_host.clone());

    let runtime_context = ServerRuntimeContext {
        orchestrator: orchestrator.clone(),
        session_manager,
        event_store,
        engine_host,
        skill_registry,
        memory_registry: Arc::new(parking_lot::Mutex::new(
            tron::domains::agent::runner::memory::MemoryRegistry::new(),
        )),
        profile_runtime,
        settings_path,
        agent_deps: Some(AgentDeps {
            provider_factory,
            guardrails: None,
        }),
        capability_support_config: tron::shared::server::context::CapabilitySupportConfig::default(
        ),
        server_start_time: std::time::Instant::now(),
        transcription_engine: Arc::new(std::sync::OnceLock::new()),
        subagent_manager: Some(subagent_manager),
        health_tracker: Arc::new(tron::domains::model::providers::ProviderHealthTracker::new()),
        shutdown_coordinator: None,
        cron_scheduler: None,
        worktree_coordinator: None,
        device_request_broker: None,
        context_artifacts: Arc::new(
            tron::domains::session::context::ContextArtifactsService::new(),
        ),
        auth_path: unique_runtime_path("auth", "json"),
        oauth_flows: Arc::new(tokio::sync::Mutex::new(std::collections::HashMap::new())),
        mcp_router: None,
        display_stream_registry: None,
        process_manager: None,
        job_manager: None,
        output_buffer_registry: None,
        hook_abort_tracker: Arc::new(
            tron::domains::agent::runner::hooks::abort_tracker::HookAbortTracker::new(),
        ),
        ws_port: Arc::new(std::sync::atomic::AtomicU16::new(0)),
        onboarded_marker_path: unique_runtime_path("onboarded", "marker"),
        release_fetcher: None,
        updater_state_path: unique_runtime_path("updater-state", "json"),
        origin,
    };

    let metrics_handle = metrics_exporter_prometheus::PrometheusBuilder::new()
        .build_recorder()
        .handle();
    let server = Arc::new(TronServer::new(config, runtime_context, metrics_handle));
    tron::transport::setup::register_server_domains_for_context(server.runtime_context())
        .expect("integration engine protocol should register");
    tron::transport::runtime::EngineRuntimeServices::start(&server);

    let pump = EngineStreamEventPump::new(
        orchestrator.subscribe(),
        server.runtime_context().engine_host.clone(),
        server.shutdown().token(),
        orchestrator.turn_accumulators().clone(),
    );
    let stream_event_pump_handle = tokio::spawn(pump.run());

    let (addr, server_handle) = server.listen().await.unwrap();
    let ws_url = format!("ws://{addr}/engine");
    register_server_auth_path(&ws_url, &server.runtime_context().auth_path);

    (
        ws_url,
        server,
        vec![stream_event_pump_handle, server_handle],
    )
}

/// Connect to the `/engine` protocol.
async fn connect(url: &str) -> WsStream {
    let auth_path = TEST_SERVER_AUTH_PATHS
        .lock()
        .unwrap()
        .get(url)
        .cloned()
        .expect("test server auth path should be registered before connect");
    let token = tron::app::onboarding::load_or_create_bearer_token(&auth_path).unwrap();
    let mut request = url.into_client_request().unwrap();
    request
        .headers_mut()
        .insert("authorization", format!("Bearer {token}").parse().unwrap());
    let (ws, _) = connect_async(request).await.unwrap();
    ws
}

/// Connect to the loopback `/engine/workers` protocol for integration workers.
async fn connect_worker(engine_url: &str) -> WsStream {
    let auth_path = TEST_SERVER_AUTH_PATHS
        .lock()
        .unwrap()
        .get(engine_url)
        .cloned()
        .expect("test server auth path should be registered before worker connect");
    let token = tron::app::onboarding::load_or_create_bearer_token(&auth_path).unwrap();
    let mut request = worker_ws_url_for(engine_url).into_client_request().unwrap();
    request
        .headers_mut()
        .insert("authorization", format!("Bearer {token}").parse().unwrap());
    let (ws, _) = connect_async(request).await.unwrap();
    ws
}

fn engine_ws_url_for(ws_url: &str) -> String {
    if ws_url.ends_with("/engine") {
        ws_url.to_owned()
    } else {
        format!("{}/engine", ws_url.trim_end_matches('/'))
    }
}

fn worker_ws_url_for(ws_url: &str) -> String {
    format!(
        "{}/engine/workers",
        ws_url.trim_end_matches("/engine").trim_end_matches('/')
    )
}

fn register_server_auth_path(url: &str, auth_path: &std::path::Path) {
    let _ = tron::app::onboarding::load_or_create_bearer_token(auth_path).unwrap();
    TEST_SERVER_AUTH_PATHS
        .lock()
        .unwrap()
        .insert(url.to_owned(), auth_path.to_path_buf());
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
            let parsed: Value = serde_json::from_str(&text).unwrap();
            return normalize_engine_ws_value(parsed);
        }
    }
}

fn normalize_engine_ws_value(parsed: Value) -> Value {
    if parsed.get("type").and_then(Value::as_str) == Some("event") {
        return parsed.get("event").cloned().unwrap_or(parsed);
    }
    parsed
}

/// Send an engine invocation request and read the response.
async fn rpc_call(ws: &mut WsStream, id: u64, method: &str, params: Option<Value>) -> Value {
    let (response, _) = rpc_call_with_interleaved_events(ws, id, method, params).await;
    response
}

async fn rpc_call_with_interleaved_events(
    ws: &mut WsStream,
    id: u64,
    method: &str,
    params: Option<Value>,
) -> (Value, Vec<Value>) {
    engine_invoke_call_with_interleaved_events(ws, id, method, params).await
}

async fn raw_rpc_call_with_interleaved_events(
    ws: &mut WsStream,
    id: u64,
    message_type: &str,
    payload: Option<Value>,
) -> (Value, Vec<Value>) {
    let id_str = format!("r{id}");
    let mut req = payload.unwrap_or_else(|| json!({}));
    if let Some(object) = req.as_object_mut() {
        object.insert("type".to_owned(), json!(message_type));
        object.insert("id".to_owned(), json!(id_str));
    } else {
        req = json!({"type": message_type, "id": id_str});
    }
    ws.send(Message::text(req.to_string())).await.unwrap();

    // Read until we get a response with matching id
    let mut interleaved = Vec::new();
    loop {
        let parsed = read_json(ws).await;
        if parsed.get("id").and_then(|v| v.as_str()) == Some(&id_str) {
            return (parsed, interleaved);
        }
        interleaved.push(normalize_engine_ws_value(parsed));
    }
}

async fn engine_invoke_call_with_interleaved_events(
    ws: &mut WsStream,
    id: u64,
    function_id: &str,
    params: Option<Value>,
) -> (Value, Vec<Value>) {
    let payload = if function_id == "system::ping" {
        params.unwrap_or_else(ping_params)
    } else {
        params.unwrap_or_else(|| json!({}))
    };
    let idempotency_key = integration_idempotency_key(id, function_id, &payload);
    let mut invoke_params = json!({
        "functionId": function_id,
        "payload": payload,
        "idempotencyKey": idempotency_key,
    });
    let session_id = invoke_params
        .pointer("/payload/sessionId")
        .and_then(Value::as_str)
        .map(str::to_owned);
    let workspace_id = invoke_params
        .pointer("/payload/workspaceId")
        .and_then(Value::as_str)
        .map(str::to_owned);
    if (session_id.is_some() || workspace_id.is_some())
        && let Some(object) = invoke_params.as_object_mut()
    {
        let mut context = serde_json::Map::new();
        if let Some(session_id) = session_id {
            context.insert("sessionId".to_owned(), json!(session_id));
        }
        if let Some(workspace_id) = workspace_id {
            context.insert("workspaceId".to_owned(), json!(workspace_id));
        }
        object.insert("context".to_owned(), Value::Object(context));
    }
    let (response, events) =
        raw_rpc_call_with_interleaved_events(ws, id, "invoke", Some(invoke_params)).await;
    let response = unwrap_engine_invoke_response(response);
    if response.get("success") == Some(&Value::Bool(true))
        && let Some(session_id) = response
            .pointer("/result/sessionId")
            .and_then(Value::as_str)
            .map(ToOwned::to_owned)
    {
        subscribe_to_session_events(ws, id, &session_id).await;
    }
    (response, events)
}

async fn subscribe_to_session_events(ws: &mut WsStream, id: u64, session_id: &str) {
    let subscribe_id = format!("sub-{id}-{session_id}");
    let request = json!({
        "type": "subscribe",
        "id": subscribe_id,
        "topic": "events.session",
        "context": {"sessionId": session_id},
    });
    ws.send(Message::text(request.to_string())).await.unwrap();
    loop {
        let parsed = read_json(ws).await;
        if parsed.get("id").and_then(Value::as_str) == Some(subscribe_id.as_str()) {
            assert_eq!(
                parsed["ok"], true,
                "session event subscription failed: {parsed}"
            );
            return;
        }
    }
}

async fn publish_engine_session_event(
    server: &Arc<TronServer>,
    session_id: &str,
    event_type: &str,
    data: Value,
) {
    let event = json!({
        "type": event_type,
        "sessionId": session_id,
        "timestamp": chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true),
        "data": data,
    });
    server
        .runtime_context()
        .engine_host
        .publish_stream_event(tron::engine::PublishStreamEvent {
            topic: "events.session".to_owned(),
            payload: json!({
                "serverEvent": event,
                "sourceEventType": event_type,
            }),
            visibility: tron::engine::VisibilityScope::Session,
            session_id: Some(session_id.to_owned()),
            workspace_id: None,
            producer: "integration-test".to_owned(),
            trace_id: None,
            parent_invocation_id: None,
        })
        .await
        .expect("publish integration stream event");
}

fn unwrap_engine_invoke_response(response: Value) -> Value {
    if response.get("ok") == Some(&Value::Bool(false)) {
        return json!({
            "id": response.get("id").cloned().unwrap_or(Value::Null),
            "success": false,
            "error": response.get("error").cloned().unwrap_or(Value::Null),
        });
    }
    let Some(child) = response.pointer("/result/child") else {
        return json!({
            "id": response.get("id").cloned().unwrap_or(Value::Null),
            "success": response.get("ok").cloned().unwrap_or(Value::Bool(false)),
            "result": response.get("result").cloned().unwrap_or(Value::Null),
        });
    };
    if !child.get("error").is_none_or(Value::is_null) {
        let error = child.get("error").unwrap_or(&Value::Null);
        let kind = error
            .get("kind")
            .and_then(Value::as_str)
            .unwrap_or("ENGINE_ERROR");
        let domain_code = error
            .pointer("/details/code")
            .and_then(Value::as_str)
            .filter(|_| kind == "domain_failure");
        let domain_message = error
            .pointer("/details/message")
            .filter(|_| kind == "domain_failure")
            .cloned();
        let domain_details = error
            .pointer("/details/details")
            .filter(|_| kind == "domain_failure")
            .cloned();
        return json!({
            "id": response.get("id").cloned().unwrap_or(Value::Null),
            "success": false,
            "error": {
                "code": domain_code.map_or_else(|| json!(kind), |code| json!(code)),
                "message": domain_message
                    .or_else(|| error.get("message").cloned())
                    .unwrap_or_else(|| json!("engine invocation failed")),
                "details": domain_details
                    .or_else(|| error.get("details").cloned())
                    .unwrap_or(Value::Null),
            }
        });
    }
    json!({
        "id": response.get("id").cloned().unwrap_or(Value::Null),
        "success": true,
        "result": child.get("value").cloned().unwrap_or(Value::Null),
    })
}

fn integration_idempotency_key(id: u64, function_id: &str, payload: &Value) -> String {
    let mut hasher = DefaultHasher::new();
    id.hash(&mut hasher);
    function_id.hash(&mut hasher);
    serde_json::to_string(payload)
        .unwrap_or_default()
        .hash(&mut hasher);
    format!(
        "integration:{id}:{}:{:x}",
        function_id.replace("::", "-"),
        hasher.finish()
    )
}

async fn direct_engine_invoke(
    server: &Arc<TronServer>,
    function_id: &str,
    payload: Value,
    idempotency_key: &str,
    scopes: &[&str],
) -> Value {
    direct_engine_invoke_with_session(
        server,
        function_id,
        payload,
        idempotency_key,
        scopes,
        "integration-session",
    )
    .await
}

async fn direct_engine_invoke_with_session(
    server: &Arc<TronServer>,
    function_id: &str,
    payload: Value,
    idempotency_key: &str,
    scopes: &[&str],
    session_id: &str,
) -> Value {
    let mut context = CausalContext::new(
        ActorId::new("integration-system").unwrap(),
        ActorKind::System,
        AuthorityGrantId::new("engine-system").unwrap(),
        TraceId::generate(),
    )
    .with_idempotency_key(idempotency_key.to_owned())
    .with_session_id(session_id);
    for scope in scopes {
        context = context.with_scope(*scope);
    }
    let result = server
        .runtime_context()
        .engine_host
        .invoke(Invocation::new_sync(
            FunctionId::new(function_id).unwrap(),
            payload,
            context,
        ))
        .await;
    if let Some(error) = result.error {
        panic!("{function_id} failed: {error}");
    }
    result.value.unwrap_or(Value::Null)
}

#[cfg(unix)]
fn reserve_loopback_port() -> u16 {
    let listener = std::net::TcpListener::bind(("127.0.0.1", 0)).unwrap();
    let port = listener.local_addr().unwrap().port();
    drop(listener);
    port
}

fn sha256_prefixed(bytes: &[u8]) -> String {
    format!("sha256:{:x}", Sha256::digest(bytes))
}

fn manifest_with_digest(mut manifest: Value) -> Value {
    let digest = manifest_digest(&manifest);
    manifest["packageDigest"] = json!(digest);
    manifest
}

fn manifest_digest(manifest: &Value) -> String {
    let mut canonical = manifest.clone();
    if let Some(object) = canonical.as_object_mut() {
        object.remove("packageDigest");
    }
    sha256_prefixed(&serde_json::to_vec(&canonical).unwrap())
}

fn local_process_runtime_manifest(
    package_id: &str,
    namespace: &str,
    worker_id: &str,
    function_id: &str,
    executable_ref: &Value,
    file_root: &str,
) -> Value {
    json!({
        "packageId": package_id,
        "version": "1.0.0",
        "manifestSchemaId": "tron.module.package_manifest.v1",
        "sourceProvenance": {"kind": "local_digest_pinned"},
        "packageDigest": "sha256:pending",
        "trustTier": "local_digest_pinned",
        "signatureStatus": "unsigned_digest_pinned",
        "declaredWorkerKind": "local_process",
        "namespace": namespace,
        "declaredFiles": [executable_ref],
        "declaredCapabilities": [
            {
                "functionId": function_id,
                "effectClass": "PureRead",
                "risk": "low",
                "requiredAuthority": [],
                "outputResourceKinds": []
            }
        ],
        "requiredGrants": {
            "allowedCapabilities": [function_id],
            "allowedNamespaces": [namespace],
            "allowedAuthorityScopes": [format!("{namespace}.read")],
            "allowedResourceKinds": ["evidence", "activation_record"],
            "resourceSelectors": ["*"],
            "fileRoots": [file_root],
            "networkPolicy": "loopback",
            "maxRisk": "low",
            "canDelegate": false,
            "approvalRequired": false
        },
        "configSchema": {
            "type": "object",
            "additionalProperties": false,
            "properties": {}
        },
        "runtimeEntryPoint": {
            "kind": "local_process",
            "workerId": worker_id,
            "commandTemplate": {
                "kind": "materialized_file",
                "resourceId": executable_ref["resourceId"],
                "versionId": executable_ref["versionId"],
                "contentHash": executable_ref["contentHash"]
            },
            "argsTemplate": [],
            "workingDirectory": {
                "kind": "package_file_parent",
                "resourceId": executable_ref["resourceId"],
                "versionId": executable_ref["versionId"]
            },
            "executableRefs": [executable_ref],
            "expectedFunctionIds": [function_id],
            "environmentPolicy": {"mode": "empty"},
            "visibility": "system",
            "timeoutMs": 10000
        },
        "healthPolicy": {
            "mode": "invoke_function",
            "functionId": function_id,
            "payload": {"ping": true},
            "intervalSeconds": 60
        },
        "sandboxProcessPolicy": {
            "networkPolicy": "loopback",
            "fileRoots": [file_root]
        },
        "redactionPolicy": {"mode": "redacted"}
    })
}

fn ping_params() -> Value {
    json!({
        "protocolVersion": 1,
        "clientVersion": "integration-test",
    })
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[path = "integration/navigation_reconstruction.rs"]
mod navigation_reconstruction;
#[path = "integration/tests.rs"]
mod tests;
