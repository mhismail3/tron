//! Tool operation implementations.
//!
//! Built-in tool result delivery, built-in tool catalog registration, and tool
//! invocation handlers live here behind canonical `tool::*` functions.

use super::*;
use crate::engine::{
    AuthorityRequirement, EffectClass, EngineError, FunctionDefinition, FunctionId,
    IdempotencyContract, InProcessFunctionHandler, Provenance, Result as EngineResult, RiskLevel,
    WorkerDefinition, WorkerKind,
};
use crate::server::domains::catalog::{SYSTEM_AUTHORITY_GRANT, SYSTEM_OWNER_ACTOR};
use crate::server::shared::errors::{self, CapabilityError};
use crate::server::shared::params::{require_param, require_string_param};
use crate::tools::capability_runtime;
use crate::tools::traits::{ToolContext, TronTool};
use async_trait::async_trait;
use serde_json::{Value, json};

// Operation modules grouped by workflow.

mod result;
pub(crate) use result::*;
mod catalog;
pub(crate) use catalog::*;
mod execution;
pub(crate) use execution::*;
