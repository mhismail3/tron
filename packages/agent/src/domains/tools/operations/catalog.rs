//! Built-in tool capability registration.
use std::sync::Arc;

use super::ToolFunctionHandler;
use super::{
    AuthorityRequirement, EffectClass, EngineResult, FunctionDefinition, FunctionId,
    IdempotencyContract, Provenance, RiskLevel, TronTool, capability_runtime,
};
use crate::domains::tools::implementations::backends::{
    RealFileSystem, ReqwestHttpClient, TokioProcessRunner,
};
use crate::domains::tools::implementations::traits::{
    BlobStore, ContentSummarizer, FileSystemOps, HttpClient, ProcessRunner,
};
use crate::domains::worker::DomainFunctionRegistration;
use crate::domains::worker::DomainRegistrationContext;
use crate::engine::VisibilityScope;
use crate::engine::{CompensationContract, CompensationKind};
use serde_json::Value;
use serde_json::json;

pub(crate) struct ToolCapabilitySpec {
    pub(crate) function_id: FunctionId,
    pub(crate) tool: Arc<dyn TronTool>,
    pub(crate) model_tool_name: String,
    pub(crate) tool_order: usize,
    pub(crate) effect: EffectClass,
    pub(crate) risk: RiskLevel,
    pub(crate) authority_scope: &'static str,
    pub(crate) approval_required: bool,
}

impl ToolCapabilitySpec {
    fn new(tool: Arc<dyn TronTool>, tool_order: usize) -> EngineResult<Self> {
        let model_tool_name = tool.name().to_owned();
        let function_id = tool_function_id(&model_tool_name)?;
        let (effect, risk, authority_scope, approval_required) =
            classify_tool_capability(&model_tool_name);
        Ok(Self {
            function_id,
            tool,
            model_tool_name,
            tool_order,
            effect,
            risk,
            authority_scope,
            approval_required,
        })
    }
}

pub(crate) fn builtin_function_registrations(
    deps: &DomainRegistrationContext,
) -> EngineResult<Vec<DomainFunctionRegistration>> {
    let specs = builtin_tool_specs(deps)?;
    let tool_names = specs
        .iter()
        .map(|spec| spec.model_tool_name.clone())
        .collect::<Vec<_>>();
    let mut registrations = Vec::with_capacity(specs.len());
    for spec in specs {
        let definition = tool_function_definition(&spec, &tool_names)?;
        let handler = ToolFunctionHandler { tool: spec.tool };
        registrations.push(DomainFunctionRegistration {
            definition,
            handler: Arc::new(handler),
        });
    }
    Ok(registrations)
}

pub(crate) fn builtin_tool_specs(
    deps: &DomainRegistrationContext,
) -> EngineResult<Vec<ToolCapabilitySpec>> {
    let fs: Arc<dyn FileSystemOps> = Arc::new(RealFileSystem);
    let runner: Arc<dyn ProcessRunner> = Arc::new(TokioProcessRunner);
    let http: Arc<dyn HttpClient> = Arc::new(ReqwestHttpClient::from_client(
        deps.tool_runtime.http_client.clone(),
    ));
    let blob_store: Arc<dyn BlobStore> = deps.event_store.clone();

    let mut tools: Vec<Arc<dyn TronTool>> = vec![
        Arc::new(crate::domains::tools::implementations::fs::read::ReadTool::new(fs.clone())),
        Arc::new(crate::domains::tools::implementations::fs::write::WriteTool::new(fs.clone())),
        Arc::new(crate::domains::tools::implementations::fs::edit::EditTool::new(fs.clone())),
        Arc::new(
            crate::domains::tools::implementations::system::bash::BashTool::new(
                runner.clone(),
                Some(blob_store.clone()),
            )
            .with_sandbox_settings(
                deps.tool_runtime.sandbox_settings.default_image.clone(),
                deps.tool_runtime.sandbox_settings.network_enabled,
            ),
        ),
        Arc::new(
            crate::domains::tools::implementations::search::search_tool::SearchTool::new(
                runner.clone(),
            ),
        ),
        Arc::new(crate::domains::tools::implementations::fs::find::FindTool::new()),
        Arc::new(crate::domains::tools::implementations::ui::ask_user::AskUserQuestionTool::new()),
        Arc::new(
            crate::domains::tools::implementations::ui::get_confirmation::GetConfirmationTool::new(
            ),
        ),
        Arc::new(
            crate::domains::tools::implementations::ui::notify::NotifyAppTool::new(
                deps.tool_runtime.notify_delegate.clone(),
            ),
        ),
    ];

    let summarizer = deps.subagent_manager.as_ref().map(|manager| {
        Arc::new(
            crate::domains::agent::runner::agent::compaction_handler::SubagentContentSummarizer {
                manager: manager.clone(),
            },
        ) as Arc<dyn ContentSummarizer>
    });
    if let Some(summarizer) = summarizer {
        tools.push(Arc::new(
            crate::domains::tools::implementations::web::web_fetch::WebFetchTool::new_with_summarizer(
                http.clone(),
                summarizer,
            ),
        ));
    } else {
        tools.push(Arc::new(
            crate::domains::tools::implementations::web::web_fetch::WebFetchTool::new(http.clone()),
        ));
    }
    tools.push(Arc::new(
        crate::domains::tools::implementations::web::web_search::WebSearchTool::new_with_auth_path(
            http.clone(),
            deps.auth_path.clone(),
        ),
    ));

    let mut display_tool =
        crate::domains::tools::implementations::ui::display::DisplayTool::new(Some(blob_store));
    display_tool = display_tool.with_event_tx(deps.orchestrator.broadcast().sender());
    tools.push(Arc::new(display_tool));

    tools.push(Arc::new(
        crate::domains::tools::implementations::ui::computer_use::ComputerUseTool::new(
            runner,
            deps.tool_runtime
                .computer_use_settings
                .confirm_before_action,
            deps.tool_runtime
                .computer_use_settings
                .screenshot_throttle_ms,
        ),
    ));

    tools.push(Arc::new(
        crate::domains::tools::implementations::engine::EngineDiscoverTool::new(
            deps.engine_host.clone(),
        ),
    ));
    tools.push(Arc::new(
        crate::domains::tools::implementations::engine::EngineInspectTool::new(
            deps.engine_host.clone(),
        ),
    ));
    tools.push(Arc::new(
        crate::domains::tools::implementations::engine::EngineWatchTool::new(
            deps.engine_host.clone(),
        ),
    ));
    tools.push(Arc::new(
        crate::domains::tools::implementations::engine::EngineInvokeTool::new(
            deps.engine_host.clone(),
        ),
    ));

    if let Some(router) = deps.mcp_router.as_ref() {
        tools.push(Arc::new(
            crate::domains::mcp::search_tool::McpSearchTool::new(router.clone()),
        ));
        tools.push(Arc::new(crate::domains::mcp::call_tool::McpCallTool::new(
            router.clone(),
        )));
    }

    if let Some(subagent_manager) = deps.subagent_manager.as_ref() {
        let spawner: Arc<dyn crate::domains::tools::implementations::traits::SubagentSpawner> =
            subagent_manager.clone();
        tools.push(Arc::new(
            crate::domains::tools::implementations::subagent::spawn::SpawnSubagentTool::with_profile_runtime(
                spawner,
                deps.profile_runtime.clone(),
            ),
        ));
    }
    if let Some(job_manager) = deps.job_manager.as_ref() {
        tools.push(Arc::new(
            crate::domains::tools::implementations::system::manage_process::ManageJobTool::new(
                job_manager.clone(),
            ),
        ));
        tools.push(Arc::new(
            crate::domains::tools::implementations::system::wait::WaitTool::new(
                job_manager.clone(),
            ),
        ));
    }

    tools
        .into_iter()
        .enumerate()
        .map(|(tool_order, tool)| ToolCapabilitySpec::new(tool, tool_order))
        .collect()
}

pub(crate) fn tool_function_id(tool_name: &str) -> EngineResult<FunctionId> {
    FunctionId::new(capability_runtime::canonical_tool_function_id(tool_name))
}

fn tool_function_definition(
    spec: &ToolCapabilitySpec,
    all_tool_names: &[String],
) -> EngineResult<FunctionDefinition> {
    let id = &spec.function_id;
    let tool = spec.tool.as_ref();
    let tool_def = tool.definition();
    let local_tool_def = tool.local_definition();
    let mut authority = AuthorityRequirement::scope(spec.authority_scope);
    if spec.approval_required {
        authority = authority.with_approval_required();
    }
    let mut definition = FunctionDefinition::new(
        id.clone(),
        crate::domains::catalog::worker_id("tool")?,
        tool_def.description.clone(),
        VisibilityScope::System,
        spec.effect,
    )
    .with_risk(spec.risk)
    .with_required_authority(authority)
    .with_provenance(Provenance::system())
    .with_request_schema(normalize_engine_schema(
        serde_json::to_value(&tool_def.parameters).unwrap_or_else(|_| json!({"type": "object"})),
    ))
    .with_response_schema(json!({
        "type": "object",
        "additionalProperties": true
    }));
    if spec.effect.is_mutating() {
        definition = definition
            .with_idempotency(IdempotencyContract::caller_session_engine_ledger())
            .with_compensation(tool_compensation_contract(
                &spec.model_tool_name,
                spec.effect,
            ));
    }
    definition.metadata = json!({
        "domainWorker": "tool",
        "canonicalCapability": id.as_str(),
        "modelToolName": tool.name(),
        "toolOrder": spec.tool_order,
        "toolName": tool.name(),
        "toolCategory": format!("{:?}", tool.category()),
        "stopsTurn": tool.stops_turn(),
        "isInteractive": tool.is_interactive(),
        "toolExecutionMode": execution_mode_metadata(tool.execution_mode()),
        "toolStopsTurn": tool.stops_turn(),
        "toolInteractive": tool.is_interactive(),
        "toolSchema": tool_def,
        "localToolSchema": local_tool_def,
        "allToolNames": all_tool_names,
    });
    Ok(definition)
}

fn execution_mode_metadata(
    mode: crate::domains::tools::implementations::traits::ExecutionMode,
) -> Value {
    match mode {
        crate::domains::tools::implementations::traits::ExecutionMode::Parallel => {
            json!({"kind": "parallel"})
        }
        crate::domains::tools::implementations::traits::ExecutionMode::Serialized(group) => {
            json!({"kind": "serialized", "group": group})
        }
    }
}

fn tool_compensation_contract(tool_name: &str, effect: EffectClass) -> CompensationContract {
    match (tool_name, effect) {
        ("Write" | "Edit", EffectClass::ReversibleSideEffect) => CompensationContract::new(
            CompensationKind::InverseCommandAvailable,
            "file mutation tools are ledgered and can be compensated by a follow-up inverse file edit or write",
        ),
        (_, EffectClass::ReversibleSideEffect) => CompensationContract::new(
            CompensationKind::InverseCommandAvailable,
            "tool side effect is ledgered and exposes enough result context for a domain-specific inverse action",
        ),
        _ => CompensationContract::new(
            CompensationKind::ExternalIrreversible,
            "external or delegated tool side effects are ledgered for audit; automatic rollback is not available",
        ),
    }
}

pub(crate) fn normalize_engine_schema(schema: Value) -> Value {
    let Some(object) = schema.as_object() else {
        return json!({"type": "object"});
    };
    let mut normalized = serde_json::Map::new();
    for key in [
        "type",
        "description",
        "required",
        "additionalProperties",
        "maxItems",
        "enum",
    ] {
        if let Some(value) = object.get(key) {
            if key == "additionalProperties" {
                let _ = normalized.insert(
                    key.to_owned(),
                    value
                        .as_bool()
                        .map(Value::Bool)
                        .unwrap_or(Value::Bool(true)),
                );
            } else {
                let _ = normalized.insert(key.to_owned(), value.clone());
            }
        }
    }
    if let Some(properties) = object.get("properties").and_then(Value::as_object) {
        let props = properties
            .iter()
            .map(|(key, value)| (key.clone(), normalize_engine_schema(value.clone())))
            .collect();
        let _ = normalized.insert("properties".to_owned(), Value::Object(props));
    }
    if let Some(items) = object.get("items") {
        let _ = normalized.insert("items".to_owned(), normalize_engine_schema(items.clone()));
    }
    if !normalized.contains_key("type") {
        let _ = normalized.insert("type".to_owned(), Value::String("object".to_owned()));
    }
    Value::Object(normalized)
}

pub(crate) fn classify_tool_capability(
    tool_name: &str,
) -> (EffectClass, RiskLevel, &'static str, bool) {
    match tool_name {
        "Read" | "Search" | "Find" | "engine_discover" | "engine_inspect" | "engine_watch" => {
            (EffectClass::PureRead, RiskLevel::Low, "tool.read", false)
        }
        "WebFetch" | "WebSearch" => (
            EffectClass::ExternalSideEffect,
            RiskLevel::Medium,
            "tool.invoke",
            true,
        ),
        "Write" | "Edit" => (
            EffectClass::ReversibleSideEffect,
            RiskLevel::High,
            "tool.write",
            true,
        ),
        "engine_invoke" => (
            EffectClass::DelegatedInvocation,
            RiskLevel::High,
            "tool.invoke",
            true,
        ),
        _ => (
            EffectClass::ExternalSideEffect,
            RiskLevel::Medium,
            "tool.invoke",
            true,
        ),
    }
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeSet;

    use serde_json::{Value, json};

    use super::*;
    use crate::engine::{
        ActorId, ActorKind, AuthorityGrantId, CausalContext, EngineError, Invocation, TraceId,
    };
    use crate::shared::server::test_support::make_test_context;

    fn test_registration_context() -> DomainRegistrationContext {
        DomainRegistrationContext::from_context(&make_test_context())
    }

    #[test]
    fn built_in_tool_functions_project_complete_catalog_metadata() {
        let deps = test_registration_context();
        let registrations = builtin_function_registrations(&deps).expect("tool registrations");
        assert!(
            !registrations.is_empty(),
            "built-in tools must register canonical tool::* functions"
        );

        let mut names = BTreeSet::new();
        for (expected_order, registration) in registrations.iter().enumerate() {
            let definition = &registration.definition;
            assert!(
                definition.id.as_str().starts_with("tool::"),
                "{} must use the canonical tool namespace",
                definition.id.as_str()
            );
            assert_eq!(definition.owner_worker.as_str(), "tool");
            assert!(definition.request_schema.is_some());
            assert!(definition.response_schema.is_some());
            assert!(
                !definition.required_authority.scopes.is_empty(),
                "{} must declare tool authority",
                definition.id.as_str()
            );
            if definition.effect_class.requires_idempotency() {
                assert!(
                    definition.idempotency.is_some(),
                    "{} mutates and must require explicit idempotency",
                    definition.id.as_str()
                );
            }

            let metadata = &definition.metadata;
            let model_tool_name = metadata
                .get("modelToolName")
                .and_then(Value::as_str)
                .expect("model tool name metadata");
            assert!(
                names.insert(model_tool_name.to_owned()),
                "duplicate model tool name {model_tool_name}"
            );
            assert_eq!(
                metadata.get("toolOrder").and_then(Value::as_u64),
                Some(expected_order as u64),
                "{model_tool_name} must preserve deterministic model ordering"
            );
            assert!(metadata.get("toolSchema").is_some_and(Value::is_object));
            assert!(
                metadata
                    .get("localToolSchema")
                    .is_some_and(Value::is_object)
            );
            assert!(
                metadata
                    .get("toolExecutionMode")
                    .and_then(|value| value.get("kind"))
                    .and_then(Value::as_str)
                    .is_some(),
                "{model_tool_name} must expose execution-mode metadata"
            );
        }

        for expected in [
            "Read",
            "Write",
            "Edit",
            "Bash",
            "Search",
            "Find",
            "AskUserQuestion",
            "GetConfirmation",
            "NotifyApp",
            "WebFetch",
            "WebSearch",
            "Display",
            "ComputerUse",
            "engine_discover",
            "engine_inspect",
            "engine_watch",
            "engine_invoke",
        ] {
            assert!(
                names.contains(expected),
                "expected built-in model tool {expected} in the tool worker catalog"
            );
        }
    }

    #[tokio::test]
    async fn built_in_tool_handler_requires_prepared_runtime_context() {
        let deps = test_registration_context();
        let registration = builtin_function_registrations(&deps)
            .expect("tool registrations")
            .into_iter()
            .find(|registration| {
                registration
                    .definition
                    .metadata
                    .get("modelToolName")
                    .and_then(Value::as_str)
                    == Some("Read")
            })
            .expect("Read tool registration");
        let context = CausalContext::new(
            ActorId::new("test-user").expect("actor id"),
            ActorKind::Agent,
            AuthorityGrantId::new("test-grant").expect("grant id"),
            TraceId::generate(),
        )
        .with_scope("tool.read")
        .with_session_id("test-session");
        let invocation = Invocation::new_sync(
            registration.definition.id.clone(),
            json!({"params":{"file_path":"/tmp/no-runtime-context"}}),
            context,
        );
        let error = registration
            .handler
            .invoke(invocation)
            .await
            .expect_err("direct tool invocation must fail closed");
        match error {
            EngineError::DomainFailure { code, .. } => {
                assert_eq!(code, "TOOL_RUNTIME_CONTEXT_REQUIRED");
            }
            other => panic!("expected TOOL_RUNTIME_CONTEXT_REQUIRED, got {other:?}"),
        }
    }
}
