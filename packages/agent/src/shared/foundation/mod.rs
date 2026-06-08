//! Cross-owner foundation helpers.
//!
//! | Module | Purpose |
//! |--------|---------|
//! | [`constants`] | Shared compile-time constants |
//! | [`constitution`] | Tron Home layout recovery and seed report |
//! | [`errors`] | Shared error taxonomy and parsing |
//! | [`ids`] | Branded IDs used across domains and protocol payloads |
//! | [`paths`] | Canonical filesystem paths |
//! | [`profile`] | Profile runtime constants and validation |
//! | [`retry`] | Retry/backoff policy helpers |
//! | [`text`] | Text helpers used by multiple owners |

pub mod constants;
pub mod constitution;
pub mod errors;
pub mod ids;
pub mod paths;
pub mod profile;
pub mod retry;
pub mod text;
