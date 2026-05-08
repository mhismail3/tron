//! Capability contracts owned by the job domain worker.

use crate::engine::Result as EngineResult;
use crate::server::domains::catalog::CapabilitySpec;

/// Canonical capability contracts exposed by this domain worker.
pub(crate) fn capabilities() -> EngineResult<Vec<CapabilitySpec>> {
    crate::server::domains::contract::capability_specs_for_methods(super::spec::FUNCTIONS)
}
