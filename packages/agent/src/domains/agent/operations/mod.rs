//! Agent operation implementations.
//!
//! Prompt acceptance, hidden prompt apply, turn-run startup, prompt queue
//! control, and minimal status/abort commands live here behind retained
//! `agent::*` transport functions.

use crate::domains::agent::commands::AgentCommandService;
use crate::domains::agent::runtime::service::{
    PromptEngineCausality, PromptRequest, drain_prompt_queue,
};
use crate::engine::policy::ENGINE_INTERNAL_INVOKE_SCOPE;
use crate::shared::server::errors;

// Operation modules grouped by workflow.

mod prompt;
pub(crate) use prompt::*;
mod commands;
pub(crate) use commands::*;
