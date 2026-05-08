//! Agent operation implementations.
//!
//! Prompt acceptance, hidden prompt apply, turn-run startup, prompt queue
//! control, agent commands, confirmations, answers, and subagent result delivery
//! live here behind canonical `agent::*` functions.

use crate::core::events::{BaseEvent, TronEvent};
use crate::engine::policy::ENGINE_INTERNAL_INVOKE_SCOPE;
use crate::engine::queue::publish_queue_lifecycle_event;
use crate::engine::{EngineQueueDrainer, EnqueueInvocation, FunctionId};
use crate::events::EventType;
use crate::server::domains::agent::commands::AgentCommandService;
use crate::server::domains::agent::prompt_queue::PromptQueueService;
use crate::server::domains::agent::runtime::runtime::{
    format_subagent_results, get_pending_subagent_results,
};
use crate::server::domains::agent::runtime::service::{
    PromptEngineCausality, PromptRequest, drain_prompt_queue, spawn_prompt_run,
};
use crate::server::shared::errors;
use crate::server::shared::validation;

// Operation modules grouped by workflow.

mod prompt;
pub(crate) use prompt::*;
mod commands;
pub(crate) use commands::*;
mod submissions;
pub(crate) use submissions::*;
mod queue;
pub(crate) use queue::*;
