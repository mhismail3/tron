//! Engine catalog ownership: discovery and the live registry.
//!
//! `registry::LiveCatalog` owns current-process routing maps and the revision
//! cursor. The injected engine ledger is the sole owner of catalog-change
//! history: registration appends before advancing the revision, restart derives
//! the cursor from persisted changes, and watch reads those durable records.
//! The live registry does not retain a second change-log projection.

pub mod discovery;
pub mod registry;
