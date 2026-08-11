//! Engine-owned implementation of the frozen code SDK.
//!
//! Operation names are a closed ABI. Identity, authority, namespace, and
//! idempotency are derived from the outer invocation once and cannot be
//! supplied or widened by TypeScript input.

use std::collections::BTreeSet;
use std::sync::Arc;

use async_trait::async_trait;
use serde::Deserialize;
use serde_json::{Value, json};
use tokio_util::sync::CancellationToken;

use super::evaluator::{BrokerError, BrokerRequest};
use super::process_evaluator::AsyncBroker;
use super::services::{FixedServiceId, FixedServiceInvocation, FixedServiceRegistry};
use super::skills::SkillCatalog;
use super::state::{CapabilityState, StateEffect, StateQuery};
use super::{CodeHelper, RuntimeLimits};
use crate::domains::schedule::contract::{
    ScheduleAction, ScheduleAuthoritySnapshot, SchedulePatch, SchedulePolicy, ScheduleResponse,
    ScheduleTarget, ScheduleTiming,
};
use crate::domains::schedule::service::ScheduleService;
use crate::engine::{CausalContext, EngineHostHandle, FunctionId, Invocation};

/// Immutable, engine-derived context supplied to the five agent operations.
#[derive(Clone, Debug)]
pub(crate) struct AgentBrokerContext {
    pub(crate) agent_id: String,
    pub(crate) assignment_id: Option<String>,
    pub(crate) trace_id: String,
    pub(crate) autonomous_hop: u32,
    pub(crate) capability_grant: Vec<String>,
    pub(crate) write_scopes: Vec<String>,
}

/// Full core-agent adapter required before the `code` primitive is registered.
///
/// Keeping five explicit methods makes an incomplete implementation impossible
/// to pass through composition accidentally.
#[async_trait]
pub(crate) trait AgentBrokerOperations: Send + Sync {
    async fn discover(&self, context: &AgentBrokerContext, input: Value) -> Result<Value, String>;
    async fn spawn(
        &self,
        context: &AgentBrokerContext,
        call_id: &str,
        input: Value,
    ) -> Result<Value, String>;
    async fn send(
        &self,
        context: &AgentBrokerContext,
        call_id: &str,
        input: Value,
    ) -> Result<Value, String>;
    async fn wait(
        &self,
        context: &AgentBrokerContext,
        call_id: &str,
        input: Value,
    ) -> Result<Value, String>;
    async fn manage(
        &self,
        context: &AgentBrokerContext,
        call_id: &str,
        input: Value,
    ) -> Result<Value, String>;
}

/// Engine-backed implementation of every non-runtime SDK operation.
#[derive(Clone)]
pub(crate) struct EngineCodeBroker {
    context: AgentBrokerContext,
    authority: BrokerAuthority,
    agents: Arc<dyn AgentBrokerOperations>,
    schedules: ScheduleService,
    services: FixedServiceRegistry,
    skills: SkillCatalog,
    state: CapabilityState,
    helper: CodeHelper,
    limits: RuntimeLimits,
    cancellation: CancellationToken,
    engine_host: EngineHostHandle,
    nested_causal: CausalContext,
}

/// Dependencies whose availability gates registration of the model primitive.
#[derive(Clone)]
pub(crate) struct EngineCodeBrokerDeps {
    pub(crate) agents: Arc<dyn AgentBrokerOperations>,
    pub(crate) schedules: ScheduleService,
    pub(crate) services: FixedServiceRegistry,
    pub(crate) skills: SkillCatalog,
    pub(crate) state: CapabilityState,
    pub(crate) helper: CodeHelper,
    pub(crate) limits: RuntimeLimits,
    pub(crate) engine_host: EngineHostHandle,
}

impl EngineCodeBroker {
    pub(crate) fn from_invocation(
        invocation: &Invocation,
        agent_id: String,
        deps: EngineCodeBrokerDeps,
        cancellation: CancellationToken,
    ) -> Self {
        let causal = &invocation.causal_context;
        let grant = causal
            .delegated_function_grant()
            .unwrap_or_default()
            .to_vec();
        let context = AgentBrokerContext {
            agent_id,
            assignment_id: causal.agent_assignment_id().map(ToOwned::to_owned),
            trace_id: causal.trace_id.as_str().to_owned(),
            autonomous_hop: causal.autonomous_wake_hop(),
            capability_grant: grant.clone(),
            write_scopes: causal.agent_write_scopes().unwrap_or_default().to_vec(),
        };
        Self {
            authority: BrokerAuthority::new(context.assignment_id.is_some(), grant),
            context,
            agents: deps.agents,
            schedules: deps.schedules,
            services: deps.services,
            skills: deps.skills,
            state: deps.state,
            helper: deps.helper,
            limits: deps.limits,
            cancellation,
            engine_host: deps.engine_host,
            nested_causal: nested_causal_context(invocation),
        }
    }

    async fn call_agent(&self, request: &BrokerRequest) -> Result<Value, BrokerError> {
        self.authority.require("agent")?;
        match request.operation.as_str() {
            "agent.discover.v1" => {
                self.agents
                    .discover(&self.context, request.input.clone())
                    .await
            }
            "agent.spawn.v1" => {
                self.agents
                    .spawn(&self.context, &request.call_id, request.input.clone())
                    .await
            }
            "agent.send.v1" => {
                self.agents
                    .send(&self.context, &request.call_id, request.input.clone())
                    .await
            }
            "agent.wait.v1" => {
                self.agents
                    .wait(&self.context, &request.call_id, request.input.clone())
                    .await
            }
            "agent.manage.v1" => {
                self.agents
                    .manage(&self.context, &request.call_id, request.input.clone())
                    .await
            }
            _ => unreachable!("closed agent operation routed incorrectly"),
        }
        .map_err(BrokerError::new)
    }

    fn call_schedule(&self, request: &BrokerRequest) -> Result<Value, BrokerError> {
        self.authority.require("schedule")?;
        let action = schedule_action(request, &self.context)?;
        let response = self
            .schedules
            .execute_for_agent(action, &self.context.agent_id)
            .map_err(|error| BrokerError::new(error.to_string()))?;
        ensure_schedule_owner(&response, &self.context.agent_id)?;
        serde_json::to_value(response).map_err(|error| BrokerError::new(error.to_string()))
    }

    async fn call_service(&self, request: &BrokerRequest) -> Result<Value, BrokerError> {
        self.authority.require("code")?;
        match request.operation.as_str() {
            "service.discover.v1" => serde_json::to_value(self.services.discover())
                .map_err(|error| BrokerError::new(error.to_string())),
            "service.invoke.v1" => {
                let input: ServiceInvokeInput = parse(&request.input)?;
                self.services
                    .invoke(
                        input.service_id,
                        FixedServiceInvocation {
                            call_id: request.call_id.clone(),
                            operation: input.operation,
                            input: input.input,
                        },
                        &self.cancellation,
                    )
                    .await
                    .map_err(|error| BrokerError::new(error.to_string()))
            }
            _ => unreachable!("closed service operation routed incorrectly"),
        }
    }

    async fn call_skill(&self, request: &BrokerRequest) -> Result<Value, BrokerError> {
        self.authority.require("code")?;
        match request.operation.as_str() {
            "skill.discover.v1" => {
                let input: SkillDiscoverInput = parse(&request.input)?;
                let page = self
                    .skills
                    .discover_page(input.query.as_deref(), input.cursor.as_deref(), input.limit)
                    .map_err(|error| BrokerError::new(error.to_string()))?;
                serde_json::to_value(page).map_err(|error| BrokerError::new(error.to_string()))
            }
            "skill.inspect.v1" => {
                let input: SkillInspectInput = parse(&request.input)?;
                let skill = self
                    .skills
                    .inspect(&input.skill_id)
                    .map_err(|error| BrokerError::new(error.to_string()))?;
                serde_json::to_value(skill).map_err(|error| BrokerError::new(error.to_string()))
            }
            "skill.invoke.v1" => {
                let input: SkillInvokeInput = parse(&request.input)?;
                let module = self
                    .skills
                    .resolve_module(
                        &input.skill_id,
                        input.module.as_deref().unwrap_or("scripts/main.ts"),
                    )
                    .map_err(|error| BrokerError::new(error.to_string()))?;
                let result = module
                    .invoke_in_helper(
                        &self.helper,
                        &request.call_id,
                        &input.input,
                        Arc::new(self.clone()),
                        &self.limits,
                        &self.cancellation,
                    )
                    .await
                    .map_err(|error| BrokerError::new(error.to_string()))?;
                serde_json::to_value(result).map_err(|error| BrokerError::new(error.to_string()))
            }
            _ => unreachable!("closed skill operation routed incorrectly"),
        }
    }

    async fn call_state(&self, request: &BrokerRequest) -> Result<Value, BrokerError> {
        self.authority.require("code")?;
        let namespace = format!("agent:{}", self.context.agent_id);
        let state = self.state.clone();
        match request.operation.as_str() {
            "state.query.v1" => {
                let input: StateQueryInput = parse(&request.input)?;
                tokio::task::spawn_blocking(move || state.query(&namespace, &input.query))
                    .await
                    .map_err(|error| BrokerError::new(format!("state task failed: {error}")))?
                    .map_err(|error| BrokerError::new(error.to_string()))
                    .and_then(|rows| {
                        serde_json::to_value(rows)
                            .map_err(|error| BrokerError::new(error.to_string()))
                    })
            }
            "state.execute.v1" => {
                let input: StateExecuteInput = parse(&request.input)?;
                let effect = StateEffect {
                    idempotency_key: request.call_id.clone(),
                    statements: input.statements,
                };
                tokio::task::spawn_blocking(move || state.execute(&namespace, &effect))
                    .await
                    .map_err(|error| BrokerError::new(format!("state task failed: {error}")))?
                    .map_err(|error| BrokerError::new(error.to_string()))
                    .and_then(|result| {
                        serde_json::to_value(result)
                            .map_err(|error| BrokerError::new(error.to_string()))
                    })
            }
            "state.info.v1" => tokio::task::spawn_blocking(move || state.info(&namespace))
                .await
                .map_err(|error| BrokerError::new(format!("state task failed: {error}")))?
                .map_err(|error| BrokerError::new(error.to_string()))
                .and_then(|result| {
                    serde_json::to_value(result)
                        .map_err(|error| BrokerError::new(error.to_string()))
                }),
            _ => unreachable!("closed state operation routed incorrectly"),
        }
    }

    async fn call_file(&self, request: &BrokerRequest) -> Result<Value, BrokerError> {
        let (capability, function_id) = match request.operation.as_str() {
            "file.read.v1" => ("read", "host::read"),
            "file.write.v1" => ("write", "host::write"),
            "file.edit.v1" => ("edit", "host::edit"),
            _ => unreachable!("closed file operation routed incorrectly"),
        };
        self.authority.require(capability)?;
        let causal = self
            .nested_causal
            .clone()
            .with_idempotency_key(request.call_id.clone());
        let invocation = Invocation::new_sync(
            FunctionId::new(function_id).map_err(|error| BrokerError::new(error.to_string()))?,
            request.input.clone(),
            causal,
        );
        let result = self
            .engine_host
            .invoke_regular_cancellable(invocation, &self.cancellation)
            .await
            .map_err(|error| BrokerError::new(error.to_string()))?;
        if let Some(error) = result.error {
            return Err(BrokerError::new(error.to_string()));
        }
        result
            .value
            .ok_or_else(|| BrokerError::new("host file operation returned no value"))
    }
}

#[async_trait]
impl AsyncBroker for EngineCodeBroker {
    async fn call(&self, request: &BrokerRequest) -> Result<Value, BrokerError> {
        match request.operation.as_str() {
            "agent.discover.v1" | "agent.spawn.v1" | "agent.send.v1" | "agent.wait.v1"
            | "agent.manage.v1" => self.call_agent(request).await,
            "schedule.list.v1" | "schedule.create.v1" | "schedule.manage.v1" => {
                self.call_schedule(request)
            }
            "service.discover.v1" | "service.invoke.v1" => self.call_service(request).await,
            "skill.discover.v1" | "skill.inspect.v1" | "skill.invoke.v1" => {
                self.call_skill(request).await
            }
            "state.query.v1" | "state.execute.v1" | "state.info.v1" => {
                self.call_state(request).await
            }
            "file.read.v1" | "file.write.v1" | "file.edit.v1" => self.call_file(request).await,
            operation => Err(BrokerError::new(format!(
                "unknown code broker operation '{operation}'"
            ))),
        }
    }
}

#[derive(Clone)]
struct BrokerAuthority {
    restricted: bool,
    grant: BTreeSet<String>,
}

impl BrokerAuthority {
    fn new(restricted: bool, grant: Vec<String>) -> Self {
        Self {
            restricted,
            grant: grant.into_iter().collect(),
        }
    }

    fn require(&self, capability: &str) -> Result<(), BrokerError> {
        if !self.restricted {
            return Ok(());
        }
        let admitted = match capability {
            "agent" => ["agent", "agent::coordinate"],
            "schedule" => ["schedule", "schedule::schedule"],
            "code" => ["code", "code_runtime::code"],
            "read" => ["read", "host::read"],
            "write" => ["write", "host::write"],
            "edit" => ["edit", "host::edit"],
            _ => unreachable!("closed capability family"),
        };
        if admitted.iter().any(|item| self.grant.contains(*item)) {
            Ok(())
        } else {
            Err(BrokerError::new(format!(
                "active assignment is not granted the '{capability}' capability"
            )))
        }
    }
}

fn nested_causal_context(invocation: &Invocation) -> CausalContext {
    let parent = &invocation.causal_context;
    let mut causal = CausalContext::new(
        parent.actor_id.clone(),
        parent.actor_kind.clone(),
        parent.trace_id.clone(),
    )
    .with_parent_invocation(invocation.id.clone())
    .with_trigger_depth(parent.trigger_depth())
    .with_autonomous_wake_hop(parent.autonomous_wake_hop());
    if let Some(session_id) = &parent.session_id {
        causal = causal.with_session_id(session_id.clone());
    }
    if let Some(workspace_id) = &parent.workspace_id {
        causal = causal.with_workspace_id(workspace_id.clone());
    }
    if let Some(directory) = parent.working_directory() {
        causal = causal.with_working_directory(directory.to_owned());
    }
    if let Some(grant) = parent.delegated_function_grant() {
        causal = causal.with_delegated_function_grant(grant.to_vec());
    }
    if let Some(agent_id) = parent.agent_id() {
        causal = match (parent.agent_assignment_id(), parent.agent_execution_id()) {
            (Some(assignment_id), Some(execution_id)) => causal.with_agent_execution(
                agent_id.to_owned(),
                assignment_id.to_owned(),
                execution_id.to_owned(),
            ),
            (Some(assignment_id), None) => {
                causal.with_agent_assignment(agent_id.to_owned(), assignment_id.to_owned())
            }
            (None, _) => causal.with_agent_identity(agent_id.to_owned()),
        };
    }
    if let Some(limits) = parent.agent_limits() {
        causal = causal.with_agent_limits(limits.clone());
    }
    if let Some(scopes) = parent.agent_write_scopes() {
        causal = causal.with_agent_write_scopes(scopes.to_vec());
    }
    causal
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ServiceInvokeInput {
    service_id: FixedServiceId,
    operation: String,
    #[serde(default)]
    input: Value,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct SkillDiscoverInput {
    query: Option<String>,
    cursor: Option<String>,
    limit: Option<usize>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct SkillInspectInput {
    skill_id: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct SkillInvokeInput {
    skill_id: String,
    module: Option<String>,
    #[serde(default)]
    input: Value,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct StateQueryInput {
    #[serde(flatten)]
    query: StateQuery,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct StateExecuteInput {
    statements: Vec<super::state::StateStatement>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ScheduleCreateInput {
    name: String,
    target: ScheduleTarget,
    timing: ScheduleTiming,
    #[serde(default)]
    policy: SchedulePolicy,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ScheduleListInput {
    #[serde(default)]
    include_deleted: bool,
    cursor: Option<String>,
    limit: Option<u16>,
}

#[derive(Deserialize)]
#[serde(tag = "action", rename_all = "snake_case", deny_unknown_fields)]
enum ScheduleManageInput {
    Get {
        schedule_id: String,
        occurrence_limit: Option<u16>,
    },
    Update {
        schedule_id: String,
        expected_revision: u64,
        patch: SchedulePatch,
    },
    Pause {
        schedule_id: String,
        expected_revision: u64,
    },
    Resume {
        schedule_id: String,
        expected_revision: u64,
    },
    Delete {
        schedule_id: String,
        expected_revision: u64,
    },
    RunNow {
        schedule_id: String,
    },
}

fn schedule_action(
    request: &BrokerRequest,
    context: &AgentBrokerContext,
) -> Result<ScheduleAction, BrokerError> {
    let authority = || ScheduleAuthoritySnapshot {
        principal_agent_id: context.agent_id.clone(),
        grant: json!({
            "capabilities": context.capability_grant,
            "writeScopes": context.write_scopes,
        }),
    };
    match request.operation.as_str() {
        "schedule.list.v1" => {
            let input: ScheduleListInput = parse(&request.input)?;
            Ok(ScheduleAction::List {
                owner_agent_id: Some(context.agent_id.clone()),
                include_deleted: input.include_deleted,
                cursor: input.cursor,
                limit: input.limit,
            })
        }
        "schedule.create.v1" => {
            let input: ScheduleCreateInput = parse(&request.input)?;
            Ok(ScheduleAction::Create {
                idempotency_key: request.call_id.clone(),
                owner_agent_id: context.agent_id.clone(),
                name: input.name,
                target: input.target,
                authority: authority(),
                timing: input.timing,
                policy: input.policy,
            })
        }
        "schedule.manage.v1" => match parse::<ScheduleManageInput>(&request.input)? {
            ScheduleManageInput::Get {
                schedule_id,
                occurrence_limit,
            } => Ok(ScheduleAction::Get {
                schedule_id,
                occurrence_limit,
            }),
            ScheduleManageInput::Update {
                schedule_id,
                expected_revision,
                mut patch,
            } => {
                if patch.target.is_some() {
                    patch.authority = Some(authority());
                } else if patch.authority.is_some() {
                    return Err(BrokerError::new(
                        "schedule authority cannot be supplied without retargeting",
                    ));
                }
                Ok(ScheduleAction::Update {
                    schedule_id,
                    expected_revision,
                    patch,
                })
            }
            ScheduleManageInput::Pause {
                schedule_id,
                expected_revision,
            } => Ok(ScheduleAction::Pause {
                schedule_id,
                expected_revision,
            }),
            ScheduleManageInput::Resume {
                schedule_id,
                expected_revision,
            } => Ok(ScheduleAction::Resume {
                schedule_id,
                expected_revision,
            }),
            ScheduleManageInput::Delete {
                schedule_id,
                expected_revision,
            } => Ok(ScheduleAction::Delete {
                schedule_id,
                expected_revision,
            }),
            ScheduleManageInput::RunNow { schedule_id } => Ok(ScheduleAction::RunNow {
                schedule_id,
                idempotency_key: request.call_id.clone(),
            }),
        },
        _ => unreachable!("closed schedule operation routed incorrectly"),
    }
}

fn ensure_schedule_owner(
    response: &ScheduleResponse,
    expected_agent_id: &str,
) -> Result<(), BrokerError> {
    let owner = match response {
        ScheduleResponse::Create { schedule }
        | ScheduleResponse::Update { schedule }
        | ScheduleResponse::Pause { schedule }
        | ScheduleResponse::Resume { schedule }
        | ScheduleResponse::Delete { schedule } => Some(schedule.owner_agent_id.as_str()),
        ScheduleResponse::Get { detail } => Some(detail.schedule.owner_agent_id.as_str()),
        ScheduleResponse::List { page } => {
            if page
                .schedules
                .iter()
                .all(|schedule| schedule.owner_agent_id == expected_agent_id)
            {
                return Ok(());
            }
            None
        }
        ScheduleResponse::RunNow { .. } => return Ok(()),
    };
    if owner == Some(expected_agent_id) {
        Ok(())
    } else {
        Err(BrokerError::new(
            "schedule is not managed by the current agent",
        ))
    }
}

fn parse<T: serde::de::DeserializeOwned>(input: &Value) -> Result<T, BrokerError> {
    serde_json::from_value(input.clone()).map_err(|error| BrokerError::new(error.to_string()))
}
