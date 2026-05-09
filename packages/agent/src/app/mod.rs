//! Application bootstrap and HTTP server shell.
//!
//! This layer wires the engine, domain workers, transports, health, metrics,
//! onboarding, and shutdown. It must not own domain behavior; executable work
//! belongs to `domains::*` workers and engine primitives.

pub mod config;
pub mod disk;
pub mod health;
pub mod metrics;
pub mod onboarding;
pub mod server;
pub mod shutdown;
