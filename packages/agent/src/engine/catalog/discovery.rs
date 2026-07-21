//! Runtime actor identities used by catalog admission and audit.
//!
//! The four variants correspond to actual production callers. Session and
//! workspace belong to causal evidence, not actor identity or function scope.

use serde::{Deserialize, Serialize};

use crate::engine::kernel::ids::ActorId;

/// Context of the actor performing discovery or invocation.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ActorContext {
    /// Actor id.
    pub actor_id: ActorId,
    /// Actor kind.
    pub actor_kind: ActorKind,
}

impl ActorContext {
    /// Create an actor context.
    #[must_use]
    pub fn new(actor_id: ActorId, actor_kind: ActorKind) -> Self {
        Self {
            actor_id,
            actor_kind,
        }
    }
}

/// Kind of actor.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum ActorKind {
    /// Agent actor.
    Agent,
    /// Paired client.
    Client,
    /// Worker actor.
    Worker,
    /// System actor.
    System,
}
