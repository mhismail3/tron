//! Catalog-wide type contracts.

use serde::{Deserialize, Serialize};

use crate::engine::kernel::ids::ActorId;

macro_rules! revision_type {
    ($name:ident) => {
        #[doc = concat!("Monotonic revision counter for ", stringify!($name), " values.")]
        #[derive(
            Clone, Copy, Debug, Default, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize,
        )]
        #[serde(transparent)]
        pub struct $name(pub u64);

        impl $name {
            /// Return the next revision.
            #[must_use]
            pub fn next(self) -> Self {
                Self(self.0 + 1)
            }
        }
    };
}

revision_type!(CatalogRevision);
revision_type!(FunctionRevision);

/// Admission boundary for callable engine functions.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum FunctionVisibility {
    /// Callable by authenticated clients, agents, workers, and the engine.
    Public,
    /// Callable only by the engine's System actor.
    Internal,
}

/// Delivery boundary for durable engine stream events.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum StreamVisibility {
    /// Visible only to the named session.
    Session,
    /// Visible to every authenticated subscriber.
    System,
}

impl StreamVisibility {
    /// Static display string.
    #[must_use]
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Session => "session",
            Self::System => "system",
        }
    }
}

/// Health state for routing and discovery.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum FunctionHealth {
    /// Healthy and routable.
    Healthy,
    /// Routable, but callers should prefer healthy alternatives.
    Degraded,
    /// Not routable.
    Unhealthy,
    /// Unknown health.
    Unknown,
}

impl FunctionHealth {
    /// Whether normal invocation may route to the function.
    #[must_use]
    pub fn is_routable(&self) -> bool {
        matches!(self, Self::Healthy | Self::Degraded)
    }
}

/// Provenance metadata for generated and registered artifacts.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Provenance {
    /// Actor that created the artifact.
    pub created_by: ActorId,
    /// Source description.
    pub source: String,
    /// Optional session scope.
    pub session_id: Option<String>,
    /// Optional workspace scope.
    pub workspace_id: Option<String>,
}

impl Provenance {
    /// Create provenance for an actor-authored artifact.
    #[must_use]
    pub fn new(created_by: ActorId, source: impl Into<String>) -> Self {
        Self {
            created_by,
            source: source.into(),
            session_id: None,
            workspace_id: None,
        }
    }

    /// System provenance for built-ins and tests.
    #[must_use]
    pub fn system() -> Self {
        Self::new(
            ActorId::new("system").expect("valid static actor id"),
            "system",
        )
    }

    /// Attach a session scope.
    #[must_use]
    pub fn with_session_id(mut self, session_id: impl Into<String>) -> Self {
        self.session_id = Some(session_id.into());
        self
    }

    /// Attach a workspace scope.
    #[must_use]
    pub fn with_workspace_id(mut self, workspace_id: impl Into<String>) -> Self {
        self.workspace_id = Some(workspace_id.into());
        self
    }
}
