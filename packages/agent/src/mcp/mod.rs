//! Model Context Protocol (MCP) integration.
//!
//! Enables the Tron agent to discover and call tools exposed by external
//! MCP servers. Tools are registered dynamically at startup and appear
//! as regular tools to the LLM.
//!
//! ## Architecture
//!
//! ```text
//! Agent ←→ McpClient ←→ MCP Server (stdio/HTTP) ←→ External Service
//!                          ↑
//!             Config in settings.json
//! ```
//!
//! ## Modules
//!
//! - [`types`] — MCP protocol types (JSON-RPC, tool schemas)
//! - [`client`] — Transport and protocol implementation
//! - [`tool_bridge`] — Adapter from MCP tool to [`TronTool`]
//! - [`server_manager`] — Lifecycle management for MCP servers

pub mod client;
pub mod server_manager;
pub mod tool_bridge;
pub mod types;
