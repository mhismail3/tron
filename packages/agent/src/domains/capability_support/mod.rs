//! Capability support namespace.
//!
//! Active model execution exposes only the primitive `execute` surface. This
//! module contains support helpers shared by the provider loop and event
//! protocol; it does not register host functions or execute model calls
//! directly.

pub mod implementations;
