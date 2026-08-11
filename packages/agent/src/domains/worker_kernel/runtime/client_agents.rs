//! Authenticated, session-scoped agent management for native clients.
//!
//! Native clients never reconstruct relationships by joining hidden sessions,
//! deliveries, and worker state. `scope` establishes the authorized complete
//! relationship graph, `reads` owns paged canonical projections, `actions`
//! owns authenticated mutations and exact impact counts, and `shared` owns
//! closed projection/validation helpers. All writes reuse the model-facing
//! runtime paths and return a fresh server-authored inspect document.

use std::collections::{HashMap, HashSet};

use serde_json::{Value, json};

use super::*;
use crate::domains::session::event_store::{AgentMessageDisposition, AgentMessageMetadataRecord};
use crate::domains::worker_kernel::persistence::{
    AgentAssignmentKind, AgentAssignmentRecord, AgentAssignmentStatus, AgentConfigurationUpdate,
    AgentInstanceRecord, AgentInstanceState, AgentManagementCapability, AgentRoleUpdate,
    AgentVisibility, CoordinationTraceStateRecord, NewAgentAssignment, NewAgentAssignmentMessage,
    NewAgentManagementGrantBatch,
};
use crate::shared::protocol::messages::{AgentMessageAuthority, AgentMessageKind};

const MAX_CLIENT_PAGE: usize = 100;
const MAX_CLIENT_AUDIT_ITEMS: usize = 200;

struct ClientAgentScope {
    owner: AgentInstanceRecord,
    agents: HashMap<String, AgentInstanceRecord>,
    related_ids: HashSet<String>,
}

mod actions;
mod reads;
mod scope;
mod shared;

use shared::*;
