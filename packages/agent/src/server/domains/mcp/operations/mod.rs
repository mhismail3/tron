//! MCP operation implementations.
//!
//! The MCP worker owns server status, tool discovery, server lifecycle
//! mutation, live catalog refresh, and MCP health/catalog stream publication.
//! Product MCP protocol handling remains in the MCP layer; Tron capability
//! execution enters here as canonical `mcp::*` functions.
