//! `SQLite` backend for the event store.
//!
//! Provides connection pooling, schema migrations, and repository implementations
//! for all database operations. The schema is a single consolidated migration
//! (`migrations/v001_schema.sql`) that creates every table and index the agent
//! needs. Constraints (`CHECK`, `UNIQUE`, `FOREIGN KEY`, `COALESCE`-nullable unique
//! indexes) are declared inline on `CREATE TABLE` — no triggers and no FTS virtual
//! tables. Pre-release policy: when the schema needs to change, edit `v001_schema.sql`
//! and delete `~/.tron/system/database/log.db` to start fresh; post-release,
//! additive migrations (`v002_*.sql`, …) get appended to the runner registry.
//!
//! # Architecture
//!
//! - **[`connection`]**: `r2d2` connection pool with WAL mode, foreign keys, and
//!   performance pragmas applied to every connection.
//! - **[`migrations`]**: Version-tracked schema evolution. Migrations are embedded
//!   at compile time and run transactionally. Each applied migration is verified
//!   with `PRAGMA foreign_key_check` before commit.
//! - **[`process_lock`]**: OS-level advisory flock guarding the DB file to prevent
//!   two daemons (e.g. prod + stray `tron dev`) from racing on the same file.
//! - **[`row_types`]**: Raw database row structs for `rusqlite` row mapping.
//! - **[`repositories`]**: Stateless repository structs — each method takes
//!   `&Connection` and executes SQL. No shared mutable state.

pub mod connection;
pub mod contention;
pub mod migrations;
pub mod process_lock;
pub mod repositories;
pub mod row_types;

pub use connection::{
    ConnectionConfig, ConnectionPool, PooledConnection, PragmaState, check_integrity, new_file,
    new_in_memory, verify_pragmas,
};
pub use migrations::{MigrationResult, current_version, latest_version, run_migrations};
pub use process_lock::{DatabaseLock, LockError, acquire_database_lock};
