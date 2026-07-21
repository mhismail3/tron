//! # tron
//!
//! Unified library crate for the Tron agent.
//!
//! The crate layout mirrors the pure engine architecture:
//!
//! - [`app`] owns binary/server bootstrap, health, metrics, onboarding, and shutdown.
//! - [`transport`] owns authenticated `/engine` protocol framing and worker-webhook ingress.
//! - [`engine`] owns the typed function fabric and durable generic substrates.
//! - [`domains`] owns the trusted-local worker kernel and retained product services.
//! - [`shared`] owns foundation types, protocol DTOs, and cross-cutting helpers.

#![deny(unsafe_code)]
#![allow(clippy::unnecessary_literal_bound)]

pub mod app;
pub mod domains;
pub mod engine;
pub mod shared;
pub mod transport;
