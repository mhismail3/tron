//! Prompt run orchestration services.
//!
//! `execute` owns the linear run-turn lifecycle, while sibling modules own the
//! request DTO, dependency bundle, run plan, spawning, queue drain, stream event
//! publication, and the major run-turn phases.

use std::sync::atomic::AtomicI64;

use crate::domains::agent::runner::orchestrator::agent_factory::{AgentFactory, CreateAgentOpts};
use crate::domains::agent::runner::orchestrator::agent_runner::run_agent;
use crate::domains::agent::runner::orchestrator::orchestrator::StartedRun;
use crate::domains::agent::runner::types::{AgentConfig, RunContext};

use crate::engine::policy::ENGINE_INTERNAL_INVOKE_SCOPE;
use crate::engine::{
    ActorContext, ActorId, ActorKind, AuthorityGrantId, CausalContext, EngineQueueDrainer,
    EnqueueInvocation, FunctionId, FunctionRevision, InvocationId, TraceId,
};
use crate::shared::server::context::AgentDeps;

use super::cleanup::{PromptRunCleanup, ShutdownCancelForwarder};
use super::predicates::retain_eligible;
use crate::domains::agent::runtime::runtime::{
    build_user_content_override, build_user_event_payload, load_session_update_data,
    persist_user_message_event, resume_prompt_session,
};

mod agent_build;
mod completion;
mod context;
mod deps;
mod events;
mod execute;
mod plan;
mod queue;
mod request;
mod spawn;

pub use deps::{PromptDrainOutcome, PromptEngineCausality, PromptRuntimeDeps};
pub(super) use events::publish_prompt_runtime_stream;
pub(super) use execute::execute_prompt_run;
pub(super) use plan::PromptRunPlan;
pub(crate) use queue::drain_prompt_queue;
pub(super) use queue::enqueue_prompt_queue_drain;
pub use request::PromptRequest;
pub use spawn::spawn_prompt_run;
