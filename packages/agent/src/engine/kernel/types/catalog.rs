//! Catalog-wide type contracts.

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

use crate::engine::kernel::ids::{ActorId, WorkerId};

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
revision_type!(TriggerRevision);
revision_type!(WorkerRevision);

/// Visibility scope for catalog entries.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum VisibilityScope {
    /// Engine-internal entry.
    Internal,
    /// Visible to a single session.
    Session,
    /// Visible to a workspace.
    Workspace,
    /// System-wide visibility.
    System,
    /// Client-visible entry.
    Client,
    /// Worker-visible entry.
    Worker,
    /// Agent-visible entry.
    Agent,
    /// Admin-only entry.
    Admin,
}

impl VisibilityScope {
    /// Static display string.
    #[must_use]
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Internal => "internal",
            Self::Session => "session",
            Self::Workspace => "workspace",
            Self::System => "system",
            Self::Client => "client",
            Self::Worker => "worker",
            Self::Agent => "agent",
            Self::Admin => "admin",
        }
    }

    /// Whether this scope may be shown to an autonomous agent.
    #[must_use]
    pub fn is_agent_visible(&self) -> bool {
        matches!(
            self,
            Self::Session | Self::Workspace | Self::System | Self::Agent
        )
    }
}

/// Catalog subject type.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum CatalogSubjectKind {
    /// Worker catalog entry.
    Worker,
    /// Function catalog entry.
    Function,
    /// Trigger type catalog entry.
    TriggerType,
    /// Trigger catalog entry.
    Trigger,
}

impl CatalogSubjectKind {
    /// Static display string.
    #[must_use]
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Worker => "worker",
            Self::Function => "function",
            Self::TriggerType => "trigger_type",
            Self::Trigger => "trigger",
        }
    }
}

/// Coarse class for catalog-change subscriptions.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum CatalogChangeClass {
    /// Worker or capability availability changed.
    Availability,
    /// Function contract changed.
    Contract,
    /// Trigger or trigger-type topology changed.
    Trigger,
    /// Visibility/promotion changed.
    Visibility,
    /// Health changed.
    Health,
}

impl CatalogChangeClass {
    /// Static display string.
    #[must_use]
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Availability => "availability",
            Self::Contract => "contract",
            Self::Trigger => "trigger",
            Self::Visibility => "visibility",
            Self::Health => "health",
        }
    }
}

/// Catalog change event.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct CatalogChange {
    /// Change id.
    pub id: String,
    /// Revision before the change.
    pub before: CatalogRevision,
    /// Revision after the change.
    pub after: CatalogRevision,
    /// Change kind.
    pub kind: CatalogChangeKind,
    /// Subject id.
    pub subject_id: String,
    /// Subject kind.
    pub subject_kind: CatalogSubjectKind,
    /// Coarse change class.
    pub class: CatalogChangeClass,
    /// Subject visibility at the time of the change.
    pub visibility: VisibilityScope,
    /// Subject session scope at the time of the change.
    pub session_id: Option<String>,
    /// Subject workspace scope at the time of the change.
    pub workspace_id: Option<String>,
    /// Owner worker, when applicable.
    pub owner_worker: Option<WorkerId>,
    /// Timestamp.
    pub timestamp: DateTime<Utc>,
}

/// Kind of catalog change.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum CatalogChangeKind {
    /// Worker was registered.
    WorkerRegistered,
    /// Worker metadata changed.
    WorkerUpdated,
    /// Worker was removed.
    WorkerUnregistered,
    /// Function was registered.
    FunctionRegistered,
    /// Function contract or metadata changed.
    FunctionUpdated,
    /// Function was removed.
    FunctionUnregistered,
    /// Trigger type was registered.
    TriggerTypeRegistered,
    /// Trigger type contract or metadata changed.
    TriggerTypeUpdated,
    /// Trigger type was removed.
    TriggerTypeUnregistered,
    /// Trigger was registered.
    TriggerRegistered,
    /// Trigger config or metadata changed.
    TriggerUpdated,
    /// Trigger was removed.
    TriggerUnregistered,
    /// Catalog entry visibility changed.
    VisibilityChanged,
    /// Catalog entry health changed.
    HealthChanged,
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
