//! Provider protocol boundary for model-native wire concepts.
//!
//! Provider APIs still speak in their own stream/block vocabularies. This
//! module is the only shared place where Tron keeps provider-native capability
//! invocation argument parsing and provider-specific invocation id remapping.
//! Code outside provider modules should consume canonical capability
//! invocation/history structs, not provider wire shapes. Malformed provider
//! argument payloads fail closed here before a canonical capability invocation
//! can be recorded or executed.
//!
//! ## Submodules
//!
//! | Module | Purpose |
//! |--------|---------|
//! | `capability_parsing` | Fail-closed JSON parsing for streamed provider invocation arguments |
//! | `id_remapping` | Provider-specific invocation id format conversion at prompt serialization time |
//!
//! # INVARIANT: provider protocol terms stay at the boundary
//!
//! Provider-native ids and argument fragments are converted before entering the
//! runner, session ledger, registry, audit, or iOS DTO layers. Completed
//! capability invocation arguments must be absent, empty, or a JSON object;
//! malformed and non-object payloads surface as provider stream errors.

pub mod capability_parsing;
pub mod id_remapping;

pub use capability_parsing::{
    CapabilityArgumentParseError, CapabilityCallContext, is_valid_capability_call_arguments,
    parse_capability_call_arguments,
};
pub use id_remapping::{IdFormat, build_invocation_id_mapping, remap_invocation_id};
