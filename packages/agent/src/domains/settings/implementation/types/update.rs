//! User-mode updater setting enums.
//!
//! These live with settings because `server.update` is a persisted public
//! contract. The updater consumes these values; lower-level settings code must
//! not depend on the `server` module to deserialize its own schema.

use serde::{Deserialize, Serialize};

/// Release channel the user subscribes to.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum UpdateChannel {
    /// Only releases without a pre-release suffix.
    #[default]
    Stable,
    /// All releases, including pre-releases.
    Beta,
}

impl UpdateChannel {
    /// Wire-format string used in capability responses and persisted state.
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Stable => "stable",
            Self::Beta => "beta",
        }
    }
}

/// Cadence at which the in-process scheduler fires an update check.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum UpdateFrequency {
    /// No automatic checks.
    Manual,
    /// One check at server startup.
    Startup,
    /// One check every hour.
    Hourly,
    /// One check every day.
    #[default]
    Daily,
    /// One check every week.
    Weekly,
}

impl UpdateFrequency {
    /// Wire-format string used in capability responses.
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Manual => "manual",
            Self::Startup => "startup",
            Self::Hourly => "hourly",
            Self::Daily => "daily",
            Self::Weekly => "weekly",
        }
    }

    /// Scheduler interval for a non-manual / non-startup cadence.
    pub fn interval(&self) -> Option<std::time::Duration> {
        use std::time::Duration;
        match self {
            Self::Manual | Self::Startup => None,
            Self::Hourly => Some(Duration::from_secs(60 * 60)),
            Self::Daily => Some(Duration::from_secs(24 * 60 * 60)),
            Self::Weekly => Some(Duration::from_secs(7 * 24 * 60 * 60)),
        }
    }
}

/// What the updater does when it observes a newer release.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum UpdateAction {
    /// Emit an update-available event and leave installation to the user.
    #[default]
    Notify,
}

impl UpdateAction {
    /// Wire-format string used in capability responses.
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Notify => "notify",
        }
    }
}
