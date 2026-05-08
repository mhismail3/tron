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
//! - [`maybe_fire`] — async entry point called from `agent_prompt_service`.

use tracing::{debug, warn};

use crate::events::EventStore;
use crate::server::shared::context::run_blocking_task;
use crate::server::shared::error_mapping::map_event_store_error;
use crate::server::shared::errors::{CapabilityError, SESSION_NOT_FOUND};

use super::RetainDeps;

mod decision;
mod fire;
mod state;

#[cfg(test)]
mod tests;

pub use decision::{AutoRetainDecision, AutoRetainInput, should_auto_retain};
pub use fire::maybe_fire;
pub use state::gather_state;
