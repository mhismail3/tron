//! Prompt-turn runtime helpers.
//!
//! This module keeps the retained prompt-run primitives: bounded session
//! refresh/resume reads and user-message payload persistence.

use std::time::Duration;

use crate::domains::agent::r#loop::orchestrator::event_persister::EventPersister;
use crate::domains::agent::r#loop::orchestrator::session_reconstructor::ReconstructedState;
use crate::domains::session::event_store::{ActivitySummaryLine, MessagePreview};

mod session_update;
mod user_event;

pub use session_update::{load_session_update_data, resume_prompt_session};
pub use user_event::{
    build_user_content_override, build_user_event_payload, persist_user_message_event,
};
