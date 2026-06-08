//! Session lifecycle services and operation wrappers.

use crate::shared::protocol::events::{BaseEvent, TronEvent};

use crate::domains::session::Deps;

pub(crate) struct CreateSessionRequest {
    pub(crate) working_directory: String,
    pub(crate) model: String,
    pub(crate) title: Option<String>,
}

pub(crate) struct SessionLifecycleService;

mod archive;
mod create;
mod delete;
mod fork;
mod operations;

pub(crate) use operations::{
    session_archive_older_than_value, session_archive_value, session_create_value,
    session_delete_value, session_fork_value, session_unarchive_value,
};

#[cfg(test)]
mod tests;
