//! Automatic memory retention policy.
//!
//! Decides whether to fire the retain pipeline at the end of an agent run,
//! based on `memory.autoRetainInterval` from settings and the session's
//! **user-message** history. The threshold unit is a user-visible exchange,
//! not an agent internal turn — a single prompt that spawns ten tool calls
//! counts as one toward the threshold.
//!
//! Three layers, each independently testable:
//! - [`should_auto_retain`] — pure policy decision, no I/O.
//! - [`gather_state`] — sync state read from the event store.
//! - [`maybe_fire`] — async entry point used by the hidden
//!   `memory::auto_retain_fire` engine function.

use crate::server::shared::errors::SESSION_NOT_FOUND;

use super::RetainDeps;

mod decision;
mod fire;
mod state;

#[cfg(test)]
mod tests;

pub use decision::{AutoRetainDecision, AutoRetainInput, should_auto_retain};
pub use fire::maybe_fire;
pub use state::gather_state;
