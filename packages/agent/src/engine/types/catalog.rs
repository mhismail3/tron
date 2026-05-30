use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

use super::{CatalogRevision, VisibilityScope};
use crate::engine::ids::WorkerId;

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
    /// Worker registered.
    WorkerRegistered,
    /// Worker updated.
    WorkerUpdated,
    /// Worker unregistered.
    WorkerUnregistered,
    /// Function registered.
    FunctionRegistered,
    /// Function updated.
    FunctionUpdated,
    /// Function unregistered.
    FunctionUnregistered,
    /// Trigger type registered.
    TriggerTypeRegistered,
    /// Trigger type updated.
    TriggerTypeUpdated,
    /// Trigger type unregistered.
    TriggerTypeUnregistered,
    /// Trigger registered.
    TriggerRegistered,
    /// Trigger updated.
    TriggerUpdated,
    /// Trigger unregistered.
    TriggerUnregistered,
    /// Visibility changed.
    VisibilityChanged,
    /// Health changed.
    HealthChanged,
}
