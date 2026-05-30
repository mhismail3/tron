//! Module source trust, policy, signature, and revocation operations.
//!
//! Package source decisions, local trust roots, signature verification, policy
//! audits, trust inspection, renewal/rotation, reconciliation, and explicit
//! revocation enforcement all stay resource-backed. This submodule owns those
//! operator trust paths without introducing package, policy, trust, or audit
//! tables.

use super::*;

mod approval;
mod inspection;
mod lifecycle;
mod policy;
mod registration;
mod schemas;
mod support;
mod verification;

pub(in crate::engine::primitives::module) use schemas::{
    approve_source_schema, audit_policy_schema, enforce_revocation_schema,
    expire_trust_decision_schema, inspect_trust_schema, policy_audit_response_schema,
    policy_decide_schema, reconcile_trust_schema, register_source_schema, renew_trust_root_schema,
    revoke_source_approval_schema, rotate_signature_key_schema, verify_signature_schema,
    verify_source_schema,
};
