//! Session-scoped event projection for the `/engine` stream transport.
//!
//! The stream runtime keeps transport concerns thin: domain-specific event
//! payloads are converted into bounded session projections here, while durable
//! event truth stays in the session/event-store and engine stream substrate.
//! This module only routes to concern-owned converters.

use crate::shared::events::TronEvent;
use serde_json::json;

use super::routed::{ProjectedEvent, global, session_scoped, set_opt};

mod agent;
mod lifecycle;

pub(super) fn convert(event: &TronEvent) -> Option<ProjectedEvent> {
    agent::convert(event).or_else(|| lifecycle::convert(event))
}
