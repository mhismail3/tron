//! Model Context Protocol (MCP) integration.
//!
//! Enables Tron workers to discover and call capabilities exposed by external
//! MCP servers. MCP server operations register as live `mcp::*` engine
//! functions and are discovered through the generic capability primitives.
//!
//! ## Architecture
//!
//! ```text
//! capability primitives ←→ live `mcp::*` functions ←→ McpRouter ←→ MCP Servers
//!                                      ↑
//!                                  ToolIndex
//! ```
//!
//! ## Modules
//!
//! - [`types`] — MCP protocol types (JSON-RPC, tool schemas, server config)
//! - [`client`] — Transport and protocol implementation
//! - [`tool_projection`] — MCP result conversion helper
//! - [`server_manager`] — Lifecycle management for MCP servers
//! - [`tool_index`] — Searchable in-memory tool index
//! - [`schemas`] — Pure drift-detection between two tool-definition sets
//! - [`router`] — Central coordinator (`McpServerManager` + `ToolIndex`)
//!
//! # INVARIANT: unknown MCP capabilities are not autonomous writes
//!
//! MCP tools discovered from external servers are classified conservatively
//! when registered into the engine catalog. Obvious read-only names become
//! low-risk `PureRead` capabilities; mutation-like or unknown tools become
//! approval-required external side effects until a stronger server/capability
//! policy says otherwise.

pub mod client;
pub mod router;
pub mod schemas;
pub mod server_manager;
pub mod tool_index;
pub mod tool_projection;
pub mod types;

#[cfg(test)]
mod tests;
