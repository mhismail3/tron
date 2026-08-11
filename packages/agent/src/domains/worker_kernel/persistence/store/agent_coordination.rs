//! Durable reusable-agent identity, work, topology, authority, and resources.
//!
//! `agent_instances` owns stable addresses and transcript-session linkage;
//! `agent_assignments` owns immutable admitted work; `execution_nodes` is the
//! one mixed worker/agent causal graph. Cross-store effects leave through the
//! transactional coordination outbox, so no caller holds a `workers.sqlite`
//! transaction while mutating EventStore.
//!
//! The implementation is split by durable concern:
//!
//! - [`admission`] creates root, reusable, and direct-worker agent identities.
//! - [`directory`] and [`scheduling`] own bounded reads and dispatch selection.
//! - [`assignment_admission`] and [`assignment_state`] own work lifecycle.
//! - [`lifecycle`] owns quiescent identity mutations and promotion.
//! - [`outbox`] owns cross-database import custody and poison compensation.
//! - [`management`] owns explicit subtree authority grants.
//! - [`claims`] owns scoped-write and whole-workspace process leases.
//! - [`schema`], [`queries`], and the support modules centralize canonical SQL,
//!   decoding, validation, and transition invariants.
//!
//! Private submodules extend the same [`WorkerStore`]; they are organization,
//! not repository wrappers or additional state owners.

use std::io;
use std::path::{Component, Path};

use rusqlite::{OptionalExtension, Transaction, TransactionBehavior, params};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use crate::shared::protocol::messages::{AgentMessageAuthority, AgentMessageKind};

use super::{WorkerStore, validate_runtime_identifier};

mod admission;
mod assignment_admission;
mod assignment_state;
mod assignment_support;
mod claim_support;
mod claims;
mod directory;
mod lifecycle;
mod management;
mod outbox;
mod queries;
mod scheduling;
mod schema;
mod support;
mod types;
mod worker_nodes;

use assignment_support::*;
use claim_support::*;
use queries::*;
use support::*;
pub(crate) use types::*;

pub(super) use assignment_support::{
    interrupt_direct_worker_assignment_in_tx, terminalize_direct_worker_assignment_in_tx,
};
#[allow(unused_imports)]
pub(crate) use worker_nodes::execution_id_for_worker_invocation;
pub(super) use worker_nodes::insert_worker_execution_node;

pub(super) fn install_schema_v19(connection: &rusqlite::Connection) -> Result<(), String> {
    schema::install_schema_v19(connection)
}

pub(super) fn install_schema_v21(connection: &rusqlite::Connection) -> Result<(), String> {
    schema::install_schema_v21(connection)
}
