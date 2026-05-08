//! Prompt run orchestration services.
//!
//! `execute` owns the linear run-turn lifecycle, while sibling modules own the
//! request DTO, dependency bundle, run plan, spawning, queue drain, stream event
//! publication, and the major run-turn phases.

use std::sync::atomic::AtomicI64;

use crate::runtime::orchestrator::agent_factory::{AgentFactory, CreateAgentOpts};
use crate::runtime::orchestrator::agent_runner::run_agent;
use crate::runtime::orchestrator::orchestrator::StartedRun;
use crate::runtime::types::{AgentConfig, RunContext, VolatileTokens};
use parking_lot::RwLock;

use crate::engine::policy::ENGINE_INTERNAL_INVOKE_SCOPE;
use crate::engine::{
    ActorId, ActorKind, AuthorityGrantId, CausalContext, EngineQueueDrainer, EnqueueInvocation,
    FunctionId, InvocationId, TraceId,
};
use crate::server::shared::context::AgentDeps;

use super::cleanup::{PromptRunCleanup, ShutdownCancelForwarder};
use super::predicates::{retain_eligible, should_acquire_worktree_for_source};
use crate::server::domains::agent::runtime::runtime::{
    PromptBootstrapData, PromptContextArtifacts, build_user_content_override,
    build_user_event_payload, collect_pending_skill_payloads, load_prompt_bootstrap,
    load_prompt_bootstrap_minimal, load_session_update_data, persist_user_message_event,
    prepare_skill_context_from_session, resume_prompt_session,
};

mod agent_build;
mod completion;
mod context;
mod deps;
mod events;
mod execute;
mod hooks;
mod plan;
mod queue;
mod request;
mod spawn;
mod worktree;

pub use deps::{PromptDrainOutcome, PromptEngineCausality, PromptRuntimeDeps};
pub(super) use events::publish_prompt_runtime_stream;
pub(super) use execute::execute_prompt_run;
pub(super) use plan::PromptRunPlan;
pub(crate) use queue::drain_prompt_queue;
pub(super) use queue::enqueue_prompt_queue_drain;
pub use request::PromptRequest;
pub use spawn::spawn_prompt_run;
