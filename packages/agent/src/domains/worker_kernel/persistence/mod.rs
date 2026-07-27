//! Worker-kernel persistence boundary.
//!
//! Filesystem worker bundles and active pointers are canonical. The SQLite
//! backend owns rebuildable routing indexes plus durable operational ledgers.
//! Database implementation types stay private to this module. Callers use
//! [`WorkerStore`]. `snapshot` owns verified compressed profile backup and
//! offline restoration before an on-disk worker schema changes.
//!
//! ## Ownership
//!
//! - `filesystem` owns the one canonical atomic-JSON and immutable-tree hash
//!   implementation used by publication and reconstruction.
//! - `rebuild` projects canonical bundles into disposable SQLite indexes.
//! - `snapshot` creates, verifies, and restores owner-only profile archives.
//! - `store` owns canonical publication plus durable invocation, attempt,
//!   generic run-stage evidence, inbox, trigger, health, and audit ledgers.
//!   Run-stage rows are append-only observations attached to the invocation
//!   state machine, not a second job or execution owner. Nested worker calls
//!   retain a parent/per-tool occurrence slot so restart reconstruction replays
//!   one existing child even if a provider regenerates its transient call id
//!   or valid arguments. Its concern modules and scenario tests live beside
//!   that single state owner. Current Attention is a derived view of unresolved
//!   error evidence; informational outcomes remain immutable inbox history.

mod filesystem;
mod rebuild;
mod snapshot;
mod store;

pub(in crate::domains::worker_kernel) use store::{
    NotificationDispatchOutcome, NotificationRefreshDispatch, NotificationTargetDispatch,
    SessionOrganizationDispatch, WorkerStore,
};

pub(crate) use snapshot::{
    ProfileSnapshot, create_profile_snapshot, ensure_worker_schema_snapshot,
    list_profile_snapshots, restore_profile_snapshot, verify_profile_snapshot,
};
