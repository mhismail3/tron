//! Concern-owned tests for session command behavior.
//!
//! Keep this root declaration-only; shared setup lives in `support`, and
//! archive/delete concerns stay split from batch retention behavior.

mod support;

mod archive_delete;
mod archive_older_than;
