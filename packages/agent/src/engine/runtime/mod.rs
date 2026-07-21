//! Engine runtime ownership for direct trigger dispatch.
//!
//! ## Submodules
//!
//! | Module | Responsibility |
//! |--------|----------------|
//! | `triggers` | Trigger dispatch runtime, cascade bounds, and trigger metadata recording. |
//!
//! ## Entry Points
//!
//! `EngineTriggerRuntime` dispatches registered triggers through the engine
//! host. Persistent worker lifecycle and triggering belong exclusively to the
//! worker kernel.
//!
//! ## Dependency Direction
//!
//! Runtime depends on the engine host, kernel contracts, and durability stores.
//! It does not depend on HTTP handlers, domains, app bootstrap, or
//! provider-specific model clients.
//!
//! ## Invariants
//!
//! - Trigger cascades carry explicit depth/path budgets.
//!
//! ## Test Ownership
//!
//! Runtime behavior tests live under `engine/tests/runtime/triggers.rs`.

pub mod triggers;
