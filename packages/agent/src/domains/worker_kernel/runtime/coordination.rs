//! First-class reusable-agent coordination.
//!
//! The worker database owns identity, assignments, authority, resources, and
//! cross-store outboxes. EventStore owns hidden transcripts and safe-boundary
//! delivery, so no operation spans a transaction in both stores. Concern-owned
//! submodules keep the model protocol (`admission`, `messaging`, `management`),
//! trusted provider context (`context`), and closed validation/topology helpers
//! (`shared`) independently reviewable without creating parallel runtimes.
//! Role discovery includes only active, healthy, explicitly discoverable
//! immutable declarations. Lifecycle checks use exact unpaged ownership and
//! wait state; presentation limits never define quiescence.

use std::collections::BTreeSet;
use std::path::{Component, Path};

use serde_json::{Value, json};

use super::*;
use crate::domains::session::event_store::{
    CoordinationDependencyEdge, CoordinationDependencyEdgeKind, CoordinationTargetKind,
    CoordinationTerminalEvidence, CoordinationWaitDependency, CoordinationWaitMode,
    CoordinationWaitTarget, NewCoordinationWait,
};
use crate::domains::worker_kernel::persistence::{
    AgentAssignmentKind, AgentAssignmentStatus, AgentAssignmentTransition,
    AgentConfigurationUpdate, AgentInstanceKind, AgentInstanceRecord, AgentInstanceState,
    AgentManagementCapability, AgentRoleUpdate, ExecutionNodeRecord, NewAgentAdmission,
    NewAgentAssignment, NewAgentAssignmentMessage, NewAgentManagementGrantBatch,
    NewAgentMessageOutbox, NewRootAgent,
};
use crate::shared::protocol::messages::{AgentMessageAuthority, AgentMessageKind};

const DEFAULT_DIRECTORY_LIMIT: usize = 20;
const MAX_DIRECTORY_LIMIT: usize = 50;
const MAX_TEAM_ENTRIES: usize = 32;

mod admission;
mod context;
mod management;
mod messaging;
mod shared;

pub(super) use shared::*;
