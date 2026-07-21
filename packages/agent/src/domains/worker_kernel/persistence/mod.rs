//! Worker-kernel persistence boundary.
//!
//! Filesystem worker bundles and active pointers are canonical. The SQLite
//! backend owns rebuildable routing indexes plus durable operational ledgers.
//! Database implementation types stay private to this module. Callers use
//! [`WorkerStore`]; current worker history and caller-owned durable events
//! remain as evidence.
//!
//! ## Ownership
//!
//! - `filesystem` owns the one canonical atomic-JSON and immutable-tree hash
//!   implementation used by publication and reconstruction.
//! - `rebuild` projects canonical bundles into disposable SQLite indexes.
//! - `store` owns canonical publication plus durable invocation, inbox,
//!   trigger, health, and audit ledgers. Its concern modules and scenario tests
//!   live beside that single state owner.

mod filesystem;
mod rebuild;
mod store;

pub(super) use store::WorkerStore;
