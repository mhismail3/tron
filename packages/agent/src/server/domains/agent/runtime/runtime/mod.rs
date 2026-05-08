//! Prompt-turn runtime helpers.
//!
//! This module is domain-owned support for the hidden `agent::run_turn` path.
//! It is split by responsibility: bootstrap gathers context artifacts and
//! pending results, `skills` prepares skill XML and side-effect events,
//! `session_update` performs bounded session refresh reads, and `user_event`
//! owns user-message payload persistence.

use std::collections::HashSet;
use std::fmt::Write;
use std::sync::Arc;
use std::time::Duration;

use crate::events::types::payloads::skill::{SkillsClearedMode, SkillsClearedPayload};
use crate::events::{ActivitySummaryLine, EventStore, EventType, MessagePreview};
use crate::runtime::orchestrator::event_persister::EventPersister;
use crate::runtime::orchestrator::session_manager::SessionManager;
use crate::runtime::orchestrator::session_reconstructor::ReconstructedState;
use crate::skills::registry::SkillRegistry;
use crate::skills::types::SkillMetadata;
use parking_lot::RwLock;
use serde_json::Value;

use crate::server::domains::session::context::{
    ContextArtifactsService, collect_dynamic_rule_paths,
};
use crate::server::shared::context::run_blocking_task;
use crate::server::shared::errors::CapabilityError;
mod bootstrap;
mod pending;
mod session_update;
mod skills;
mod user_event;

pub use bootstrap::{
    PromptBootstrapData, PromptContextArtifacts, load_prompt_bootstrap,
    load_prompt_bootstrap_minimal,
};
pub use pending::{format_subagent_results, get_pending_subagent_results};
pub use session_update::{load_session_update_data, resume_prompt_session};
pub use skills::{
    SkillContextResult, collect_pending_skill_payloads, prepare_skill_context_from_session,
};
pub use user_event::{
    build_user_content_override, build_user_event_payload, persist_user_message_event,
};
