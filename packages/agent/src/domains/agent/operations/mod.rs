//! Agent operation implementations.
//!
//! Prompt acceptance, hidden prompt apply, turn-run startup, prompt queue
//! control, lifecycle helpers, agent commands, confirmations, answers, and
//! subagent result delivery live here behind canonical `agent::*` functions.

use crate::domains::agent::commands::AgentCommandService;
use crate::domains::agent::prompt_queue::PromptQueueService;
use crate::domains::agent::runtime::runtime::{
    format_subagent_results, get_pending_subagent_results,
};
use crate::domains::agent::runtime::service::{
    PromptEngineCausality, PromptRequest, drain_prompt_queue, spawn_prompt_run,
};
use crate::domains::session::event_store::EventType;
use crate::engine::policy::ENGINE_INTERNAL_INVOKE_SCOPE;
use crate::shared::events::{BaseEvent, TronEvent};
use crate::shared::server::errors;
use crate::shared::server::validation;

// Operation modules grouped by workflow.

mod prompt;
pub(crate) use prompt::*;
mod commands;
pub(crate) use commands::*;
mod lifecycle;
use lifecycle::*;
mod submissions;
pub(crate) use submissions::*;
mod queue;
pub(crate) use queue::*;
