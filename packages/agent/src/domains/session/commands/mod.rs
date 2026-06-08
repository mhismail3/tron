//! Shared command-side services for session capabilities.

use crate::shared::protocol::events::{BaseEvent, TronEvent};

use crate::domains::session::Deps;

pub(crate) struct CreateSessionRequest {
    pub(crate) working_directory: String,
    pub(crate) model: String,
    pub(crate) title: Option<String>,
}

pub(crate) struct SessionCommandService;

mod archive;
mod create;
mod delete;
mod fork;

#[cfg(test)]
mod tests;
