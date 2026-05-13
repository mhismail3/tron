//! MCP operation implementations.
//!
//! MCP server lifecycle, status, capability catalog refresh, and live MCP function
//! registration are executed here as canonical `mcp::*` operations.

use crate::domains::mcp::capability_index::ParamSummary;
use crate::domains::mcp::capability_projection::mcp_result_to_capability_result;
use crate::domains::mcp::types::McpServerConfig;
use crate::engine::{
    ActorContext, ActorId, ActorKind, AuthorityGrantId, AuthorityRequirement, EffectClass,
    FunctionDefinition, FunctionId, FunctionQuery, IdempotencyContract, InProcessFunctionHandler,
    Provenance, RiskLevel, WorkerId,
};
use async_trait::async_trait;

// Operation modules grouped by workflow.

mod status;
pub(crate) use status::*;
mod server_lifecycle;
pub(crate) use server_lifecycle::*;
mod catalog;
pub(crate) use catalog::*;
mod capability_invocation;
pub(crate) use capability_invocation::*;
