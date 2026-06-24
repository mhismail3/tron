//! Runtime and external-worker subsystem tests.
//!
//! Shared runtime-test fixtures that are narrower than global engine fixtures
//! live next to the owning behavior tests, for example trigger dispatch helpers
//! in `trigger_helpers`. External-worker behavior tests stay split by protocol,
//! delivery, and soak concerns so runtime regressions do not create a broad
//! monolithic test bucket.

pub(in crate::engine::tests) use super::fixtures::*;

mod external_worker;
mod external_worker_delivery;
mod external_worker_helpers;
mod external_worker_protocol;
mod external_worker_soak;
mod restart_chaos;
mod trigger_helpers;
mod triggers;
