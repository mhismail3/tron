//! MCP operation implementations.
//!
//! MCP server lifecycle, status, tool catalog refresh, and live MCP function
//! registration are executed here as canonical `mcp::*` operations.

use super::*;
use crate::engine::{
    ActorContext, ActorId, ActorKind, AuthorityGrantId, AuthorityRequirement, EffectClass,
    FunctionDefinition, FunctionId, FunctionQuery, IdempotencyContract, InProcessFunctionHandler,
    Provenance, RiskLevel, WorkerId,
};
use crate::mcp::tool_index::ParamSummary;
use crate::mcp::tool_projection::mcp_result_to_tron_result;
use crate::mcp::types::McpServerConfig;
use crate::server::shared::errors::CapabilityError;
use async_trait::async_trait;
use serde_json::{Value, json};

// Operation modules grouped by workflow.

mod status;
pub(crate) use status::*;
mod server_lifecycle;
pub(crate) use server_lifecycle::*;
mod catalog;
pub(crate) use catalog::*;
mod tool_invocation;
pub(crate) use tool_invocation::*;
