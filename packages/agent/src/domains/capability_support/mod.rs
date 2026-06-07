//! Capability support namespace.
//!
//! Active model execution is capability-only. This module contains support
//! helpers shared by domain-owned capabilities and provider/event protocol
//! helpers; it does not register a worker or execute model calls directly.

pub mod implementations;
