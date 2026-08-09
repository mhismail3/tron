//! Model routing, registry, and canonical model operation helpers.
//!
//! - `attachments`: effective provider/engine attachment policy projection.
//! - `catalog`: known-model lookup and durable session model/reasoning selection.
//! - `models`: provider-neutral model types and registry helpers.
//! - `operations`: canonical `model::*` function implementations.
//!
//! INVARIANT: `model.list` and prompt attachment validation use the same
//! attachment policy owner; clients transform inputs but do not define limits.
//! Session configuration writes validate against that same catalog and append
//! reconstruction-visible events; clients do not maintain a parallel setting.

pub(crate) mod attachments;
pub mod catalog;
pub mod models;
mod operations;

pub(crate) use operations::*;
