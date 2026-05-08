//! Tool operation implementations.
//!
//! Built-in tool result delivery, built-in tool catalog registration, and tool
//! invocation handlers live here behind canonical `tool::*` functions.

use crate::engine::{
    AuthorityRequirement, EffectClass, EngineError, FunctionDefinition, FunctionId,
    IdempotencyContract, InProcessFunctionHandler, Provenance, Result as EngineResult, RiskLevel,
};
use crate::tools::capability_runtime;
use crate::tools::traits::{ToolContext, TronTool};
use async_trait::async_trait;

// Operation modules grouped by workflow.

mod result;
pub(crate) use result::*;
mod catalog;
pub(crate) use catalog::*;
mod execution;
pub(crate) use execution::*;
