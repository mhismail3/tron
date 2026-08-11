//! `SQLite` backend for the event store.
//!
//! Provides connection pooling, current-schema installation, and repository
//! implementations for sessions, events, blobs, and logs. Databases start from
//! consolidated `schema/current.sql`. Constraints
//! (`CHECK`, `UNIQUE`, `FOREIGN KEY`, `COALESCE`-nullable unique indexes) are
//! declared inline on `CREATE TABLE` -- no triggers and no FTS virtual tables.
//!
//! # Architecture
//!
//! - **[`connection`]**: `r2d2` connection pool with WAL mode, foreign keys, and
//!   performance pragmas applied to every connection.
//! - **[`schema`]**: The compile-time current schema, installed transactionally
//!   and verified with `PRAGMA foreign_key_check` before commit.
//! - **[`process_lock`]**: OS-level advisory flock guarding the DB file to prevent
//!   two daemons (e.g. prod + stray `tron dev`) from racing on the same file.
//! - **[`row_types`]**: Raw database row structs for `rusqlite` row mapping.
//! - **[`repositories`]**: Stateless repository structs — each method takes
//!   `&Connection` and executes SQL. No shared mutable state.
//!
//! Worker-owned agent sessions use the same durable event model and are marked
//! with one reserved system tag. Default session-list projections exclude that
//! tag so user conversation lists remain clean; exact-ID reads remain the audit
//! path and do not depend on a second session store. Core schedules share this
//! database so cursor advancement and occurrence admission remain one
//! transaction across restart; RFC expansion stays schedule-domain-owned. The
//! event schema indexes
//! `(session_id, type, sequence)` so latest typed projections remain bounded as
//! sessions grow.

pub mod connection;
pub mod contention;
pub mod process_lock;
pub mod repositories;
pub mod row_types;
pub mod schema;

pub use connection::{
    ConnectionConfig, ConnectionPool, PooledConnection, PragmaState, check_integrity, new_file,
    new_in_memory, verify_pragmas,
};
pub use process_lock::{DatabaseLock, LockError, acquire_database_lock};
pub use schema::ensure_schema;
