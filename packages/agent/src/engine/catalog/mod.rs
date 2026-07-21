//! Engine catalog ownership: discovery and the live registry.
//!
//! `registry::LiveCatalog` owns current-process routing maps and the revision
//! cursor. The injected engine ledger is the sole owner of catalog-change and
//! invocation history: registration appends before advancing the revision,
//! invocation completion returns a ledger error when persistence fails, and
//! restart derives the cursor from persisted changes. Function definitions are
//! self-sufficient; there is no parallel catalog-worker registry or namespace-
//! claim preflight. Registration requires an executable handler, so discovery
//! can never advertise a definition that the current process cannot route. The
//! live registry does not retain duplicate history.
//!
//! Discovery actor context is provenance plus visibility scope, not an
//! authorization token or permission object.

pub mod discovery;
pub mod registry;
