//! Engine catalog ownership: discovery and the live registry.
//!
//! `registry::LiveCatalog` owns current-process routing maps and the revision
//! cursor. The injected engine ledger is the sole owner of catalog-change and
//! invocation history: registration appends before advancing the revision,
//! invocation completion returns a ledger error when persistence fails, restart
//! derives the cursor from persisted changes, and session replay/catalog watch
//! read durable records. The live registry does not retain duplicate history
//! projections.
//!
//! Discovery actor context is provenance plus visibility scope, not an
//! authorization token or permission object.

pub mod discovery;
pub mod registry;
