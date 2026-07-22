//! Worker-first domain boundary.
//!
//! The fixed source tree owns session/model execution, authenticated product
//! infrastructure, durable event/state custody, and the persistent worker
//! kernel. Higher-level adaptive behavior belongs in persistent worker bundles
//! under the engine-global worker store.
//!
//! ## Fixed domains
//!
//! | Domain | Fixed responsibility |
//! |--------|----------------------|
//! | `agent`, `model` | Model turns and provider protocol |
//! | `session` | Durable conversation and event truth |
//! | `auth`, `settings` | Authenticated product configuration |
//! | `product` | Fixed client-only blob, logs, message, and system operations |
//! | `filesystem` | Native workspace browsing used by clients |
//! | `worker_kernel` | Worker bundles, runners, dispatch, inbox, and core proposals |
//! | `registration` | Composition validation for this fixed set |
//!
//! # Invariants
//!
//! Model-visible actions are direct typed worker-kernel functions or enabled
//! persistent workers. Local calls execute directly with concrete actor
//! identity and causal evidence. Remote transport authentication remains a
//! transport concern. Source changes
//! remain isolated core proposals until a later explicit user message approves
//! application.

pub mod agent;
pub mod auth;
pub mod filesystem;
pub mod model;
pub(crate) mod product;
pub mod registration;
/// Session domain: lifecycle, reads, reconstruction, and context artifact services.
pub mod session;
pub mod settings;
pub mod worker_kernel;
