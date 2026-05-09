//! Tool operation implementations.
//!
//! Built-in tool result delivery, built-in tool catalog registration, and tool
//! invocation handlers live here behind canonical `tool::*` functions.

use crate::domains::tools::implementations::capability_runtime;
use crate::domains::tools::implementations::traits::{ToolContext, TronTool};
use crate::engine::{
    AuthorityRequirement, EffectClass, EngineError, FunctionDefinition, FunctionId,
    IdempotencyContract, InProcessFunctionHandler, Provenance, Result as EngineResult, RiskLevel,
};
use async_trait::async_trait;

// Operation modules grouped by workflow.

mod result;
pub(crate) use result::*;
mod catalog;
pub(crate) use catalog::*;
mod execution;
pub(crate) use execution::*;
