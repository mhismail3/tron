//! # tron
//!
//! Unified library crate for the Tron agent.
//!
//! The crate layout mirrors the pure engine architecture:
//!
//! - [`app`] owns binary/server bootstrap, health, metrics, onboarding, and shutdown.
//! - [`transport`] owns `/engine` and `/engine/workers` protocol framing.
//! - [`engine`] owns the live capability fabric and primitive workers.
//! - [`domains`] owns every Tron worker, contract, handler, operation, and service.
//! - [`platform`] owns OS/vendor integrations and sidecars.
//! - [`shared`] owns foundation types, protocol DTOs, and cross-cutting helpers.

#![deny(unsafe_code)]
#![allow(clippy::unnecessary_literal_bound)]

pub mod app;
pub mod domains;
pub mod engine;
pub mod platform;
pub mod shared;
pub mod transport;
