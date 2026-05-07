//! JSON-RPC engine method registration.
//!
//! This module is intentionally small: it projects the five public `engine.*`
//! transport methods from the canonical capability catalog into the transport
//! registry. It does not carry executable business behavior.

use crate::server::capabilities::catalog;
use crate::server::transport::json_rpc::registry::JsonRpcTransportRegistry;

/// Register every public JSON-RPC engine method from the canonical catalog.
pub fn register_all(registry: &mut JsonRpcTransportRegistry) {
    for method in catalog::public_json_rpc_methods() {
        registry.register(method);
    }
}
