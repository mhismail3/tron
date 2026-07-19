//! Prompt-turn runtime helpers.
//!
//! This module keeps the retained prompt-run primitives: `SessionManager`
//! owns fail-closed resume/cache reads, `EventStore` owns durable session-update
//! reads, this module owns their wire-event projection, and the runtime owns
//! user-message payload persistence.

use std::time::Duration;

use crate::domains::agent::r#loop::orchestrator::session_reconstructor::ReconstructedState;

mod session_update;
mod user_event;

pub(in crate::domains::agent::runtime) use session_update::{
    load_session_update_event, resume_prompt_session,
};
pub use user_event::{
    build_user_content_override, build_user_event_payload, persist_user_message_event,
};
