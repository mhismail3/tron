//! Application bootstrap and process lifecycle shell.
//!
//! | Module | Purpose |
//! |--------|---------|
//! | [`cli`] | Terminal argument parsing and auth subcommand dispatch |
//! | [`bootstrap`] | Runtime assembly, service initialization, database open, and server bind |
//! | [`health`] | Health/metrics endpoints and disk checks |
//! | [`lifecycle`] | Onboarding, bearer-token state, and shutdown coordination |
//!
//! App code wires engine, domain workers, transports, health, metrics,
//! onboarding, and shutdown. It must not own domain behavior; executable work
//! belongs to `domains::*` workers and engine primitives.

pub mod bootstrap;
pub mod cli;
pub mod health;
pub mod lifecycle;
