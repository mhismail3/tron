//! Discovery query types for the live catalog.

use serde::{Deserialize, Serialize};

use crate::engine::kernel::ids::ActorId;

/// Context of the actor performing discovery or invocation.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ActorContext {
    /// Actor id.
    pub actor_id: ActorId,
    /// Actor kind.
    pub actor_kind: ActorKind,
    /// Optional session id.
    pub session_id: Option<String>,
    /// Optional workspace id.
    pub workspace_id: Option<String>,
}

impl ActorContext {
    /// Create an actor context.
    #[must_use]
    pub fn new(actor_id: ActorId, actor_kind: ActorKind) -> Self {
        Self {
            actor_id,
            actor_kind,
            session_id: None,
            workspace_id: None,
        }
    }

    /// Set the actor session id.
    #[must_use]
    pub fn with_session_id(mut self, session_id: impl Into<String>) -> Self {
        self.session_id = Some(session_id.into());
        self
    }

    /// Set the actor workspace id.
    #[must_use]
    pub fn with_workspace_id(mut self, workspace_id: impl Into<String>) -> Self {
        self.workspace_id = Some(workspace_id.into());
        self
    }
}

/// Kind of actor.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum ActorKind {
    /// Human user.
    User,
    /// Agent actor.
    Agent,
    /// Paired client.
    Client,
    /// Worker actor.
    Worker,
    /// Cron actor.
    Cron,
    /// Queue actor.
    Queue,
    /// System actor.
    System,
    /// Admin actor.
    Admin,
}

impl ActorKind {
    /// Whether the actor is privileged for admin discovery.
    #[must_use]
    pub fn is_admin_like(&self) -> bool {
        matches!(self, Self::Admin | Self::System)
    }
}
