//! Engine test suite mirrored by production subsystem.
//!
//! Keep this root declaration-only. Shared fixtures live in `fixtures`, while
//! behavior tests live under the subsystem they verify.

mod fixtures;

mod authority;
mod catalog;
mod durability;
mod invocation;
mod kernel;
mod runtime;
