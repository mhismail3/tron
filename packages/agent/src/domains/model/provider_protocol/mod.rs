//! Provider protocol boundary for model-native wire concepts.
//!
//! Provider APIs still speak in their own stream/block vocabularies. This
//! module is the only shared place where Tron keeps provider-native capability
//! invocation argument parsing and provider-specific invocation id remapping.
//! Code outside provider modules should consume canonical capability
//! invocation/history structs, not provider wire shapes.
//!
//! ## Submodules
//!
//! | Module | Purpose |
//! |--------|---------|
//! | `capability_parsing` | Defensive JSON parsing for streamed provider invocation arguments |
//! | `id_remapping` | Provider-specific invocation id format conversion at prompt serialization time |
//!
//! # INVARIANT: provider protocol terms stay at the boundary
//!
//! Provider-native ids and argument fragments are converted before entering the
//! runner, session ledger, registry, audit, or iOS DTO layers.

pub mod capability_parsing;
pub mod id_remapping;

pub use capability_parsing::{
    CapabilityCallContext, is_valid_capability_call_arguments, parse_capability_call_arguments,
};
pub use id_remapping::{IdFormat, build_invocation_id_mapping, remap_invocation_id};
