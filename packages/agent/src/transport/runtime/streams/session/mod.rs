use crate::shared::events::TronEvent;
use serde_json::json;

use super::routed::{ProjectedEvent, global, session_scoped, set_opt};

mod agent;
mod lifecycle;
mod worktree;

pub(super) fn convert(event: &TronEvent) -> Option<ProjectedEvent> {
    agent::convert(event)
        .or_else(|| lifecycle::convert(event))
        .or_else(|| worktree::convert(event))
}
