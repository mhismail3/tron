//! Model Context Protocol (MCP) integration.
//!
//! Enables the Tron agent to discover and call tools exposed by external
//! MCP servers. Instead of registering each MCP tool individually (which
//! would consume ~500 tokens per tool in the LLM context), tools are exposed
//! via two meta-tools: `McpSearch` and `McpCall`.
//!
//! ## Architecture
//!
//! ```text
//! LLM ←→ McpSearch / McpCall ←→ McpRouter ←→ McpServerManager ←→ MCP Servers
//!                                   ↑
//!                              ToolIndex (keyword search)
//! ```
//!
//! ## Modules
//!
//! - [`types`] — MCP protocol types (JSON-RPC, tool schemas, server config)
//! - [`client`] — Transport and protocol implementation
//! - [`tool_bridge`] — Legacy adapter + result conversion helper
//! - [`server_manager`] — Lifecycle management for MCP servers
//! - [`tool_index`] — Searchable in-memory tool index
//! - [`router`] — Central coordinator (McpServerManager + ToolIndex)
//! - [`search_tool`] — `McpSearch` TronTool implementation
//! - [`call_tool`] — `McpCall` TronTool implementation

pub mod call_tool;
pub mod client;
pub mod router;
pub mod search_tool;
pub mod server_manager;
pub mod tool_bridge;
pub mod tool_index;
pub mod types;

#[cfg(test)]
mod tests;
