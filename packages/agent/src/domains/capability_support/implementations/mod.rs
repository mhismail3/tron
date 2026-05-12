//! Capability support types shared by adjacent runtime services.

#![deny(unsafe_code)]
// Some adjacent service traits return `&str` from `fn name()`; clippy's
// `unnecessary_literal_bound` fires on every impl but the trait signatures
// dictate the return type.
#![allow(clippy::unnecessary_literal_bound)]

pub mod backends;
pub(crate) mod capability_surface;
pub mod errors;
pub mod traits;
pub(crate) mod utils;

pub mod system;
pub mod ui;
