//! JSON-RPC transport alias registration.
//!
//! This module is intentionally small: it projects public JSON-RPC method
//! aliases from the canonical capability catalog into the transport registry.
//! It does not carry executable business handlers.

use crate::server::capabilities::catalog;
use crate::server::rpc::registry::MethodRegistry;

/// Register every public JSON-RPC alias from the canonical capability catalog.
pub fn register_all(registry: &mut MethodRegistry) {
    for method in catalog::json_rpc_alias_methods() {
        registry.register(method);
    }
}
