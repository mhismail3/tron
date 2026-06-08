//! Worker catalog type contracts.

use serde::{Deserialize, Serialize};

use super::{Provenance, VisibilityScope, WorkerRevision};
use crate::engine::kernel::ids::{ActorId, AuthorityGrantId, WorkerId};

/// Runtime kind of a registered worker.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum WorkerKind {
    /// In-process Rust worker.
    InProcess,
    /// Future external worker.
    External,
    /// Future sandbox worker.
    Sandbox,
    /// Agent worker.
    Agent,
    /// Client participant.
    Client,
    /// System worker.
    System,
    /// Queue worker.
    Queue,
    /// Stream worker.
    Stream,
    /// Cron worker.
    Cron,
    /// State worker.
    State,
    /// MCP capability worker.
    Mcp,
}

/// Worker lifecycle state.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum WorkerLifecycleState {
    /// Worker is starting.
    Starting,
    /// Worker is healthy and routable.
    Ready,
    /// Worker is available but degraded.
    Degraded,
    /// Worker is draining.
    Draining,
    /// Worker is stopped.
    Stopped,
}

/// Worker catalog definition.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct WorkerDefinition {
    /// Worker id.
    pub id: WorkerId,
    /// Worker revision.
    pub revision: WorkerRevision,
    /// Worker kind.
    pub kind: WorkerKind,
    /// Lifecycle state.
    pub lifecycle: WorkerLifecycleState,
    /// Actor that owns the worker.
    pub owner_actor: ActorId,
    /// Authority grant used by the worker.
    pub authority_grant: AuthorityGrantId,
    /// Claimed namespaces.
    pub namespace_claims: Vec<String>,
    /// Visibility.
    pub visibility: VisibilityScope,
    /// Provenance.
    pub provenance: Provenance,
}

impl WorkerDefinition {
    /// Create a worker definition.
    #[must_use]
    pub fn new(
        id: WorkerId,
        kind: WorkerKind,
        owner_actor: ActorId,
        authority_grant: AuthorityGrantId,
    ) -> Self {
        let provenance = Provenance::new(owner_actor.clone(), "worker");
        Self {
            id,
            revision: WorkerRevision(1),
            kind,
            lifecycle: WorkerLifecycleState::Ready,
            owner_actor,
            authority_grant,
            namespace_claims: Vec::new(),
            visibility: VisibilityScope::Internal,
            provenance,
        }
    }

    /// Add a namespace claim.
    #[must_use]
    pub fn with_namespace_claim(mut self, namespace: impl Into<String>) -> Self {
        self.namespace_claims.push(namespace.into());
        self
    }
}
