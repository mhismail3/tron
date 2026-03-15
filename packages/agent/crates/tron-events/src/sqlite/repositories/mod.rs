//! Repository implementations for `SQLite` database operations.
//!
//! Each repository is a stateless struct whose methods take a `&Connection`
//! parameter. This makes every operation a pure function from
//! (connection, input) → output, trivially testable in isolation.

pub mod blob;
pub mod branch;
pub mod device_token;
pub mod event;
pub mod session;
pub mod workspace;
