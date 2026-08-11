use super::*;
use async_trait::async_trait;
use futures::stream;
use std::collections::{BTreeMap, BTreeSet};
use std::sync::Arc;

use crate::domains::model::responder::{
    ModelResponder, ModelResponderFactory, ModelResponderInfo, ModelResponse, ModelResponseError,
    ModelResponseRequest, ModelResponseStream,
};
use crate::shared::protocol::content::AssistantContent;
use crate::shared::protocol::events::{AssistantMessage, StreamEvent};

mod activation;
mod agent;
mod agent_information;
mod agent_lifecycle;
mod agents;
mod client_actions;
mod command;
mod coordination;
mod deliveries;
mod hooks;
mod projection;
mod resident;
mod role_review;
mod session;

fn system_actor() -> crate::engine::ActorContext {
    crate::engine::ActorContext::new(
        crate::engine::ActorId::new("system:worker-runtime-test").expect("actor id"),
        crate::engine::ActorKind::System,
    )
}

fn command_bundle(command: Vec<String>) -> WorkerBundle {
    WorkerBundle {
        schema_version: super::super::types::BUNDLE_SCHEMA.to_owned(),
        worker_id: None,
        name: "Echo Worker".to_owned(),
        description: "Returns typed JSON input for durable runner tests".to_owned(),
        tool_name: Some("worker_echo".to_owned()),
        model_exposure: Default::default(),
        tool_input_schema: Some(json!({"type":"object"})),
        agent_tools: None,
        agent_role: None,
        input_schema: json!({"type":"object"}),
        output_schema: json!({"type":"object"}),
        runner: WorkerRunner::Command { command },
        files: Default::default(),
        dependencies: Vec::new(),
        triggers: Vec::new(),
        secret_bindings: Vec::new(),
        smoke_tests: Vec::new(),
        health_checks: Vec::new(),
        provenance: vec![super::super::types::SourceProvenance {
            source: "test:deterministic".to_owned(),
            revision: Some("1".to_owned()),
            checksum: None,
        }],
        engine_hooks: Vec::new(),
        engine_deliveries: Vec::new(),
        client_actions: Vec::new(),
        client_deliveries: Vec::new(),
        worker_dispatch_routes: Vec::new(),
        routing: Default::default(),
        execution_limits: Default::default(),
        presentation: None,
    }
}

fn test_runtime(
    responder: Option<Arc<dyn ModelResponderFactory>>,
) -> (Arc<WorkerRuntime>, tempfile::TempDir) {
    let home = tempfile::tempdir().unwrap();
    let runtime = test_runtime_at(home.path(), responder);
    (runtime, home)
}

fn test_runtime_at(
    home: &Path,
    responder: Option<Arc<dyn ModelResponderFactory>>,
) -> Arc<WorkerRuntime> {
    let (_context, runtime) =
        crate::shared::server::test_support::make_test_context_and_worker_runtime_at(
            home, responder,
        );
    runtime
}

fn last30days_bundle(source_url: &str) -> WorkerBundle {
    let script = r#"import datetime,json,os,sys
request=json.loads(sys.stdin.read() or '{}')
topic=request.get('topic','worker adaptation')
as_of=datetime.date.fromisoformat(request.get('asOf','2026-07-19'))
cutoff=as_of-datetime.timedelta(days=30)
with open('sources.json',encoding='utf-8') as handle:
    sources=json.load(handle)
recent=[source for source in sources if cutoff <= datetime.date.fromisoformat(source['publishedAt']) <= as_of]
print(json.dumps({
    'topic':topic,
    'windowDays':30,
    'asOf':as_of.isoformat(),
    'summary':f'Found {len(recent)} deterministic sources about {topic} from the last 30 days.',
    'sources':recent,
    'credentialMode':'optional_credentials_present' if os.getenv('TRON_SECRET_SEARCH_API_KEY') else 'optional_credentials_absent',
    'upstreamAvailable':os.path.isdir('../dependencies/upstream')
},separators=(',',':')))
"#;
    WorkerBundle {
            schema_version: super::super::types::BUNDLE_SCHEMA.to_owned(),
            worker_id: Some("last30days-research".to_owned()),
            name: "Last 30 Days Research".to_owned(),
            description: "Research a topic across sources published in the last 30 days with citations and graceful behavior when optional credentials are absent".to_owned(),
            tool_name: Some("worker_last30days_research".to_owned()),
            model_exposure: Default::default(),
            tool_input_schema: Some(json!({
                "type":"object",
                "additionalProperties":false,
                "required":["topic"],
                "properties":{
                    "topic":{"type":"string","minLength":1},
                    "asOf":{"type":"string"}
                }
            })),
            agent_tools: None,
            agent_role: None,
            input_schema: json!({
                "type":"object",
                "additionalProperties":false,
                "required":["topic"],
                "properties":{
                    "topic":{"type":"string","minLength":1},
                    "asOf":{"type":"string"}
                }
            }),
            output_schema: json!({
                "type":"object",
                "additionalProperties":false,
                "required":["topic","windowDays","asOf","summary","sources","credentialMode","upstreamAvailable"],
                "properties":{
                    "topic":{"type":"string"},
                    "windowDays":{"const":30},
                    "asOf":{"type":"string"},
                    "summary":{"type":"string"},
                    "sources":{"type":"array","items":{"type":"object"}},
                    "credentialMode":{"enum":["optional_credentials_present","optional_credentials_absent"]},
                    "upstreamAvailable":{"type":"boolean"}
                }
            }),
            runner: WorkerRunner::Command {
                command: vec!["python3".to_owned(), "recent_research.py".to_owned()],
            },
            files: BTreeMap::from([
                ("recent_research.py".to_owned(), script.to_owned()),
                (
                    "sources.json".to_owned(),
                    include_str!("../../../../../tests/fixtures/last30days_recent_sources.json").to_owned(),
                ),
            ]),
            dependencies: Vec::new(),
            triggers: vec![
                WorkerTrigger::Manual { id: "manual".to_owned() },
                WorkerTrigger::Schedule {
                    id: "daily".to_owned(),
                    every_seconds: 86_400,
                    input: json!({"topic":"worker adaptation"}),
                },
                WorkerTrigger::EngineEvent {
                    id: "research-requested".to_owned(),
                    topic: "research.requested".to_owned(),
                    filter: json!({"windowDays":30}),
                    input: json!({"topic":"worker adaptation"}),
                },
                WorkerTrigger::Webhook {
                    id: "local-research".to_owned(),
                    input: json!({"topic":"worker adaptation"}),
                },
            ],
            secret_bindings: vec![super::super::types::WorkerSecretBinding::Optional(
                "search-api-key".to_owned(),
            )],
            smoke_tests: vec![WorkerCommand {
                command: vec!["python3".to_owned(), "recent_research.py".to_owned()],
                timeout_seconds: 10,
            }],
            health_checks: vec![WorkerCommand {
                command: vec![
                    "python3".to_owned(),
                    "-m".to_owned(),
                    "py_compile".to_owned(),
                    "recent_research.py".to_owned(),
                ],
                timeout_seconds: 10,
            }],
            provenance: vec![super::super::types::SourceProvenance {
                source: source_url.to_owned(),
                revision: Some("fixture-adaptation-v1".to_owned()),
                checksum: None,
            }],
            engine_hooks: Vec::new(),
            engine_deliveries: Vec::new(),
            client_actions: Vec::new(),
            client_deliveries: Vec::new(),
            worker_dispatch_routes: Vec::new(),
            routing: super::super::types::WorkerRouting {
                intents: vec!["recent research".to_owned(), "last 30 days".to_owned()],
                examples: vec!["What changed in persistent workers in the last month?".to_owned()],
            },
            execution_limits: Default::default(),
            presentation: None,
        }
}

fn request(worker_id: &str, input: Value, key: &str) -> InvokeRequest {
    InvokeRequest {
        worker_id: worker_id.to_owned(),
        input,
        idempotency_key: key.to_owned(),
        trace_id: format!("trace-{key}"),
        causal_depth: 0,
        trigger_kind: "manual".to_owned(),
        origin_session_id: None,
        model: None,
        reasoning_level: None,
    }
}
