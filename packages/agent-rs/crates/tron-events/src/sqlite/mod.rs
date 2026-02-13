//! `SQLite` backend for the event store.
//!
//! Provides connection pooling, schema migrations, and repository implementations
//! for all database operations. The schema is designed from first principles for
//! the Rust event sourcing engine — a single comprehensive migration creates all
//! tables, indexes, FTS virtual tables, and triggers.
//!
//! # Architecture
//!
//! - **[`connection`]**: `r2d2` connection pool with WAL mode, foreign keys, and
//!   performance pragmas applied to every connection.
//! - **[`migrations`]**: Version-tracked schema evolution. Migrations are embedded
//!   at compile time and run transactionally.
//! - **[`row_types`]**: Raw database row structs for `rusqlite` row mapping.
//! - **[`repositories`]**: Stateless repository structs — each method takes
//!   `&Connection` and executes SQL. No shared mutable state.

pub mod connection;
pub mod migrations;
pub mod repositories;
pub mod row_types;

pub use connection::{
    new_file, new_in_memory, verify_pragmas, ConnectionConfig, ConnectionPool, PooledConnection,
    PragmaState,
};
pub use migrations::{current_version, latest_version, run_migrations};
