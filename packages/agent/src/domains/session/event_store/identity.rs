//! Explicit identities for replay-critical session storage records.
//!
//! Production constructors still use UUIDv7 IDs and wall-clock timestamps.
//! Replay, import, and roundtrip tests can pass these identities explicitly so
//! durable session records do not depend on ambient entropy.

use uuid::Uuid;

/// Deterministic identity for one session event row.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct EventIdentity {
    /// Event row ID.
    pub id: String,
    /// Event timestamp in RFC 3339 format.
    pub timestamp: String,
}

impl EventIdentity {
    /// Build an explicit event identity.
    #[must_use]
    pub fn new(id: impl Into<String>, timestamp: impl Into<String>) -> Self {
        Self {
            id: id.into(),
            timestamp: timestamp.into(),
        }
    }

    /// Generate the production event identity.
    #[must_use]
    pub fn generate_current() -> Self {
        Self {
            id: format!("evt_{}", Uuid::now_v7()),
            timestamp: chrono::Utc::now().to_rfc3339(),
        }
    }
}

/// Deterministic identity for one session row.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SessionIdentity {
    /// Session row ID.
    pub id: String,
    /// Session creation timestamp in RFC 3339 format.
    pub created_at: String,
}

impl SessionIdentity {
    /// Build an explicit session identity.
    #[must_use]
    pub fn new(id: impl Into<String>, created_at: impl Into<String>) -> Self {
        Self {
            id: id.into(),
            created_at: created_at.into(),
        }
    }

    /// Generate the production session identity.
    #[must_use]
    pub fn generate_current() -> Self {
        Self {
            id: format!("sess_{}", Uuid::now_v7()),
            created_at: chrono::Utc::now().to_rfc3339(),
        }
    }
}

/// Deterministic identity for one workspace row.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct WorkspaceIdentity {
    /// Workspace row ID.
    pub id: String,
    /// Workspace creation timestamp in RFC 3339 format.
    pub created_at: String,
}

impl WorkspaceIdentity {
    /// Build an explicit workspace identity.
    #[must_use]
    pub fn new(id: impl Into<String>, created_at: impl Into<String>) -> Self {
        Self {
            id: id.into(),
            created_at: created_at.into(),
        }
    }

    /// Generate the production workspace identity.
    #[must_use]
    pub fn generate_current() -> Self {
        Self {
            id: format!("ws_{}", Uuid::now_v7()),
            created_at: chrono::Utc::now().to_rfc3339(),
        }
    }
}

/// Deterministic identities needed to create a session and its root event.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SessionCreationIdentity {
    /// Workspace identity used if the workspace path does not already exist.
    pub workspace: WorkspaceIdentity,
    /// Session row identity.
    pub session: SessionIdentity,
    /// Root `session.start` event identity.
    pub root_event: EventIdentity,
}

impl SessionCreationIdentity {
    /// Build explicit identities for a new session.
    #[must_use]
    pub fn new(
        workspace: WorkspaceIdentity,
        session: SessionIdentity,
        root_event: EventIdentity,
    ) -> Self {
        Self {
            workspace,
            session,
            root_event,
        }
    }

    /// Generate production identities for a new session.
    #[must_use]
    pub fn generate_current() -> Self {
        Self {
            workspace: WorkspaceIdentity::generate_current(),
            session: SessionIdentity::generate_current(),
            root_event: EventIdentity::generate_current(),
        }
    }
}

/// Deterministic identities needed to fork a session and create its root event.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SessionForkIdentity {
    /// Forked session row identity.
    pub session: SessionIdentity,
    /// Root `session.fork` event identity.
    pub fork_event: EventIdentity,
}

impl SessionForkIdentity {
    /// Build explicit identities for a forked session.
    #[must_use]
    pub fn new(session: SessionIdentity, fork_event: EventIdentity) -> Self {
        Self {
            session,
            fork_event,
        }
    }

    /// Generate production identities for a forked session.
    #[must_use]
    pub fn generate_current() -> Self {
        Self {
            session: SessionIdentity::generate_current(),
            fork_event: EventIdentity::generate_current(),
        }
    }
}
