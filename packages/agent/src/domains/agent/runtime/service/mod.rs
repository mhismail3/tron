//! Prompt run orchestration services.
//!
//! `execute` owns the linear run-turn lifecycle, while sibling modules own the
//! request DTO, dependency bundle, run plan, spawning, stream event publication,
//! lightweight session title generation, and the major run-turn phases. The
//! service also owns the outer structured logging lifecycle for accepted prompt
//! runs so logs, session events, trace records, and agent-result resources share
//! common run/session/trace identifiers.

use std::sync::atomic::AtomicI64;

use crate::domains::agent::r#loop::orchestrator::agent_factory::{AgentFactory, CreateAgentOpts};
use crate::domains::agent::r#loop::orchestrator::agent_runner::run_agent;
use crate::domains::agent::r#loop::orchestrator::core::StartedRun;
use crate::domains::agent::r#loop::types::{AgentConfig, RunContext};

use crate::engine::{CausalContext, FunctionId, InvocationId};
use crate::shared::server::context::AgentDeps;

use super::cleanup::{PromptRunCleanup, ShutdownCancelForwarder};
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
mod request;
mod spawn;
mod title_generation;

pub use deps::{PromptEngineCausality, PromptRuntimeDeps};
pub(super) use events::publish_prompt_runtime_stream;
pub(super) use execute::execute_prompt_run;
pub(super) use plan::PromptRunPlan;
pub use request::PromptRequest;
pub use spawn::spawn_prompt_run;
use title_generation::{SessionTitleGenerationRequest, spawn_session_title_generation};
