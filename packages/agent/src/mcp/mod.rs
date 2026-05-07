//! Model Context Protocol (MCP) integration.
//!
//! Enables the Tron agent to discover and call tools exposed by external MCP
//! servers. `McpSearch` / `McpCall` remain available as compact
//! browsing/call helpers, while MCP server tools are also registered
//! as live `mcp::*` engine capabilities. Provider-facing tool schemas are
//! resolved from that live catalog at every model-call boundary, so MCP tools
//! added, removed, or marked unhealthy can appear or fail closed without a
//! daemon restart.
//!
//! ## Architecture
//!
//! ```text
//! LLM ←→ live engine catalog / McpSearch / McpCall ←→ McpRouter ←→ MCP Servers
//!                  ↑                              ↑
//!          `mcp::*` functions                ToolIndex
//! ```
//!
//! ## Modules
//!
//! - [`types`] — MCP protocol types (JSON-RPC, tool schemas, server config)
//! - [`client`] — Transport and protocol implementation
//! - [`tool_bridge`] — Engine/tool result conversion helper
//! - [`server_manager`] — Lifecycle management for MCP servers
//! - [`tool_index`] — Searchable in-memory tool index
//! - [`schemas`] — Pure drift-detection between two tool-definition sets
//! - [`router`] — Central coordinator (`McpServerManager` + `ToolIndex`)
//! - [`search_tool`] — `McpSearch` `TronTool` implementation
//! - [`call_tool`] — `McpCall` `TronTool` implementation
//!
//! # INVARIANT: unknown MCP tools are not autonomous writes
//!
//! MCP tools discovered from external servers are classified conservatively
//! when registered into the engine catalog. Obvious read-only names become
//! low-risk `PureRead` capabilities; mutation-like or unknown tools become
//! approval-required external side effects until a stronger server/tool policy
//! says otherwise.

pub mod call_tool;
pub mod client;
pub mod router;
pub mod schemas;
pub mod search_tool;
pub mod server_manager;
pub mod tool_bridge;
pub mod tool_index;
pub mod types;

#[cfg(test)]
mod tests;
