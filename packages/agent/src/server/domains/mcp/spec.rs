//! Canonical function inventory for the mcp domain worker.

/// Canonical functions owned by this domain worker.
pub(crate) const FUNCTIONS: &[&str] = &[
    "mcp::status",
    "mcp::add_server",
    "mcp::remove_server",
    "mcp::enable_server",
    "mcp::disable_server",
    "mcp::restart_server",
    "mcp::reload",
    "mcp::list_tools",
];
