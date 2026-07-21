//! Worker-first domain boundary.
//!
//! The fixed source tree retains only session/model execution, authenticated
//! product infrastructure, durable event/state custody, and the autonomous
//! worker kernel. Proposal-only modules, capability routing, procedural
//! candidates, metadata schedulers, and the legacy worker lifecycle are not
//! compiled or registered. New higher-level behavior belongs in persistent
//! worker bundles under the profile-global worker store.
//!
//! ## Fixed domains
//!
//! | Domain | Fixed responsibility |
//! |--------|----------------------|
//! | `agent`, `model` | Model turns and provider protocol |
//! | `session`, `message`, `logs` | Durable conversation and event truth |
//! | `auth`, `settings`, `system` | Authenticated product configuration |
//! | `blob` | Client attachment infrastructure |
//! | `filesystem` | Native workspace browsing used by clients |
//! | `worker_kernel` | Worker bundles, runners, dispatch, inbox, and core proposals |
//! | `registration` | Composition validation for this fixed set |
//!
//! # Invariants
//!
//! Model-visible actions are direct typed worker-kernel functions or enabled
//! persistent workers. Local calls are trusted-local observations and do not
//! derive per-call authority grants. Remote transport authentication remains a
//! transport concern. Source changes remain isolated core proposals until a
//! later explicit user message approves application.

pub mod agent;
pub mod auth;
pub mod blob;
pub mod filesystem;
pub mod logs;
pub mod message;
pub mod model;
pub mod registration;
/// Session domain: lifecycle, reads, reconstruction, and context artifact services.
pub mod session;
pub mod settings;
pub mod system;
pub mod worker_kernel;
