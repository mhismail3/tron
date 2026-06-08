//! Discovery query types for the live catalog.

use serde::{Deserialize, Serialize};

use crate::engine::kernel::ids::{ActorId, AuthorityGrantId};
use crate::engine::kernel::types::{EffectClass, FunctionHealth, RiskLevel, VisibilityScope};

/// Context of the actor performing discovery or invocation.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ActorContext {
    /// Actor id.
    pub actor_id: ActorId,
    /// Actor kind.
    pub actor_kind: ActorKind,
    /// Authority grant id.
    pub authority_grant_id: AuthorityGrantId,
    /// Granted authority scopes.
    pub authority_scopes: Vec<String>,
    /// Optional session id.
    pub session_id: Option<String>,
    /// Optional workspace id.
    pub workspace_id: Option<String>,
}

impl ActorContext {
    /// Create an actor context.
    #[must_use]
    pub fn new(
        actor_id: ActorId,
        actor_kind: ActorKind,
        authority_grant_id: AuthorityGrantId,
    ) -> Self {
        Self {
            actor_id,
            actor_kind,
            authority_grant_id,
            authority_scopes: Vec::new(),
            session_id: None,
            workspace_id: None,
        }
    }

    /// Add an authority scope.
    #[must_use]
    pub fn with_scope(mut self, scope: impl Into<String>) -> Self {
        self.authority_scopes.push(scope.into());
        self
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

    /// Whether this actor has a scope.
    #[must_use]
    pub fn has_scope(&self, scope: &str) -> bool {
        self.authority_scopes.iter().any(|s| s == scope)
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

/// Function discovery query.
#[derive(Clone, Debug, Default)]
pub struct FunctionQuery {
    /// Actor context.
    pub actor: Option<ActorContext>,
    /// Exact visibility filter.
    pub visibility: Option<VisibilityScope>,
    /// Namespace prefix filter.
    pub namespace_prefix: Option<String>,
    /// Text search over id, description, and tags.
    pub text: Option<String>,
    /// Effect class filter.
    pub effect_class: Option<EffectClass>,
    /// Maximum risk.
    pub max_risk: Option<RiskLevel>,
    /// Health filter.
    pub health: Option<FunctionHealth>,
    /// Include internal entries.
    pub include_internal: bool,
}
