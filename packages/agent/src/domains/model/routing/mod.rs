//! Model routing, registry, and canonical model operation helpers.
//!
//! - `attachments`: effective provider/engine attachment policy projection.
//! - `catalog`: known-model lookup and session model switching.
//! - `models`: provider-neutral model types and registry helpers.
//! - `operations`: canonical `model::*` function implementations.
//!
//! INVARIANT: `model.list` and prompt attachment validation use the same
//! attachment policy owner; clients transform inputs but do not define limits.

pub(crate) mod attachments;
pub mod catalog;
pub mod models;
mod operations;

pub(crate) use operations::*;
