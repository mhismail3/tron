//! Catalog-wide type contracts.

use serde::{Deserialize, Serialize};

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
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
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
#[derive(Clone, Debug, PartialEq, Eq)]
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

    /// Stable operator-facing name.
    #[must_use]
    pub const fn as_str(&self) -> &'static str {
        match self {
            Self::Healthy => "Healthy",
            Self::Degraded => "Degraded",
            Self::Unhealthy => "Unhealthy",
            Self::Unknown => "Unknown",
        }
    }
}
