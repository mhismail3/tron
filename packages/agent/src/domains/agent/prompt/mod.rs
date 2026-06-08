//! Agent operation implementations.
//!
//! Prompt acceptance, hidden prompt apply, turn-run startup, and minimal
//! status/abort commands live here behind retained `agent::*` transport
//! functions.

use crate::domains::agent::runtime::service::{PromptEngineCausality, PromptRequest};
use crate::engine::kernel::policy::ENGINE_INTERNAL_INVOKE_SCOPE;
use crate::shared::server::errors;

mod commands;
pub(crate) use commands::*;
mod prompt;
pub(crate) use prompt::*;
mod service;
pub(crate) use service::AgentCommandService;
